#cloud-config
# =============================================================================
# AdaptixC2 teamserver bootstrap.
# =============================================================================
# Layout (per-student teamserver):
#
#   :9000   commander/operator endpoint (Kali-only, NSG-enforced)
#
#   ---- BeaconHTTP listeners (CDN-fronted, external) ----
#   :8443   azure       — Azure Front Door origin
#   :8444   cloudfront  — CloudFront origin
#   :8445   workers     — Cloudflare workers.dev origin
#   :8446   fastly      — Fastly origin
#   :8447   other       — operator-managed origin
#
#   ---- Extra-protocol listeners (per-student singletons) ----
#   :53    dns_BeaconDNS   — DNS/DoH tunneling      (external)
#   pipe   smb_BeaconSMB   — named-pipe peering     (internal, no port)
#   :4444  tcp_BeaconTCP   — staged TCP peering     (internal, metadata only)
#   :8448  gopher_GopherTCP — TCP/mTLS gopher agent (external)
#
# All listeners are pre-created via the Web API after the teamserver
# boots, so the operator gets a fully-stocked stack with zero GUI clicks.
# Per-listener `type` lives in /opt/adaptix/listeners.json (templated
# from modules/azure/listeners.tf:adaptix_listeners) and is read by
# configure_listeners.py at boot.
#
# Reference for API + config schema:
#   https://github.com/Adaptix-Framework/AdaptixC2/blob/main/AdaptixServer/extenders/beacon_listener_http/pl_transport.go
#   https://adaptix-framework.gitbook.io/adaptix-framework/development/teamserver-interface/web-api
# =============================================================================
package_update: true
packages:
  - git
  - build-essential
  - curl
  - wget
  - openssl
  - openssh-server
  - jq
  - python3
  - python3-requests
  - gnupg      # needed by `gpg --dearmor` when adding the Elastic apt key
  # cmake is required by AdaptixClient's build target. We don't NEED
  # the client on the server box, but `make all` chains client BEFORE
  # extenders — without cmake, make exits at the client step and never
  # gets to extender plugin compilation. Cheap to install (~50MB).
  - cmake
  # NOTE: NOT installing apt's golang-go — Debian 12 ships Go 1.19, but
  # AdaptixC2's make target requires Go 1.21+. We install Go from the
  # official tarball in runcmd below.

# bootcmd: plant ranger + ssh key in the EARLIEST cloud-init phase.
# Runs ~10-15 sec after boot (cloud-init INIT phase), BEFORE sshd
# accepts its first connection — closes the race where cloud-init's
# users: module (cloud-config phase, ~1-2 min later) fails to plant
# ssh_authorized_keys on this Debian/cloud-init combo. Idempotent +
# self-heals on every boot. See c2-sliver.sh for the full rationale.
bootcmd:
  - |
    USER='${linux_user}'
    PUBKEY='${ssh_pubkey}'
    if [ -n "$PUBKEY" ]; then
      id "$USER" >/dev/null 2>&1 || useradd -m -s /bin/bash "$USER"
      mkdir -p /home/"$USER"/.ssh
      touch /home/"$USER"/.ssh/authorized_keys
      grep -qF "$PUBKEY" /home/"$USER"/.ssh/authorized_keys \
        || echo "$PUBKEY" >> /home/"$USER"/.ssh/authorized_keys
      chown -R "$USER":"$USER" /home/"$USER"/.ssh
      chmod 700 /home/"$USER"/.ssh
      chmod 600 /home/"$USER"/.ssh/authorized_keys
    fi

users:
  - name: ${linux_user}
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: false
    shell: /bin/bash
    plain_text_passwd: ${linux_pass}
    ssh_authorized_keys:
      - ${ssh_pubkey}

ssh_pwauth: true

write_files:
  # ---- Teamserver profile (YAML — NOT JSON) ----------------------------
  # adaptixserver -profile profile.yaml expects YAML. The default upstream
  # profile.yaml lists every shipped extender; we keep just the HTTP
  # listener since that's all we configure programmatically.
  - path: /opt/adaptix/profile.yaml
    permissions: "0640"
    content: |
      Teamserver:
        interface: "0.0.0.0"
        port: 9000
        endpoint: "/endpoint"
        password: "${teamserver_password}"
        only_password: false
        operators:
          ${operator_user}: "${teamserver_password}"
        cert: "/opt/adaptix/server.rsa.crt"
        key:  "/opt/adaptix/server.rsa.key"
        extenders:
          - "/opt/adaptix/AdaptixC2/AdaptixServer/extenders/beacon_listener_http/config.yaml"
          - "/opt/adaptix/AdaptixC2/AdaptixServer/extenders/beacon_listener_smb/config.yaml"
          - "/opt/adaptix/AdaptixC2/AdaptixServer/extenders/beacon_listener_tcp/config.yaml"
          - "/opt/adaptix/AdaptixC2/AdaptixServer/extenders/beacon_listener_dns/config.yaml"
          - "/opt/adaptix/AdaptixC2/AdaptixServer/extenders/gopher_listener_tcp/config.yaml"
          - "/opt/adaptix/AdaptixC2/AdaptixServer/extenders/beacon_agent/config.yaml"
          - "/opt/adaptix/AdaptixC2/AdaptixServer/extenders/gopher_agent/config.yaml"
        access_token_live_hours:  12
        refresh_token_live_hours: 168

      HttpServer:
        error:
          status: 404
          headers:
            Content-Type: "text/html; charset=UTF-8"
          page: "/opt/adaptix/error.html"
        http:
          max_header_bytes: 8192
          read_timeout_sec: 0
        tls:
          min_version: "TLS1.2"
          max_version: "TLS1.3"

  - path: /opt/adaptix/error.html
    permissions: "0644"
    content: |
      <!doctype html><title>404</title><h1>Not Found</h1>

  # ---- Per-(student, listener-kind) listener config table --------------
  # JSON; the post-boot helper reads this and POSTs each entry to
  # /listener/create. Current roster (per student):
  #   5 BeaconHTTP listeners (one per CDN, ports 8443-8447, external)
  #   1 BeaconDNS  listener (port 53, external)
  #   1 BeaconSMB  listener (named pipe, internal)
  #   1 BeaconTCP  listener (port 4444 metadata, internal)
  #   1 GopherTCP  listener (port 8448, external)
  # Each entry has {name, type, config} — type drives the API call's
  # `type` field; config is the listener-kind-specific JSON body.
  - path: /opt/adaptix/listeners.json
    permissions: "0640"
    content: |
      ${listeners_json}

  # ---- Post-boot helper: pre-create all listeners ----------------------
  - path: /opt/adaptix/configure_listeners.py
    permissions: "0750"
    content: |
      #!/usr/bin/env python3
      """Wait for AdaptixC2 teamserver, log in, register all per-student
      listeners declared in /opt/adaptix/listeners.json.

      Each entry's `type` field drives the /listener/create `type`
      parameter (BeaconHTTP / BeaconDNS / BeaconSMB / BeaconTCP /
      GopherTCP). Idempotent: skips listeners whose name already
      exists. Logs to /var/log/adaptix-listeners.log."""
      import json, os, sys, time, urllib3, requests

      urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

      BASE     = "https://127.0.0.1:9000/endpoint"
      USER     = os.environ["ADAPTIX_USER"]
      PASS     = os.environ["ADAPTIX_PASS"]
      LISTENERS = json.load(open("/opt/adaptix/listeners.json"))

      def wait_for_login(deadline_s=600):
          start = time.time()
          while time.time() - start < deadline_s:
              try:
                  r = requests.post(f"{BASE}/login",
                                    json={"username": USER, "password": PASS},
                                    verify=False, timeout=5)
                  if r.status_code == 200:
                      return r.json()["access_token"]
              except requests.RequestException:
                  pass
              time.sleep(5)
          sys.exit(f"teamserver /login never responded within {deadline_s}s")

      def existing_names(token):
          r = requests.get(f"{BASE}/listener/list",
                           headers={"Authorization": f"Bearer {token}"},
                           verify=False, timeout=10)
          r.raise_for_status()
          return {row.get("l_name") for row in (r.json() or [])}

      def create(token, name, type_, config):
          # config goes over the wire as a JSON-encoded string per the
          # documented Web API contract.
          body = {"name": name, "type": type_, "config": json.dumps(config)}
          r = requests.post(f"{BASE}/listener/create",
                            headers={"Authorization": f"Bearer {token}",
                                     "Content-Type": "application/json"},
                            data=json.dumps(body), verify=False, timeout=15)
          ok = r.status_code == 200 and (r.json() or {}).get("ok")
          print(f"[{'+' if ok else '!'}] {name}: HTTP {r.status_code} {r.text[:200]}")
          return ok

      def main():
          token = wait_for_login()
          print(f"[+] logged in")
          have = existing_names(token)
          for entry in LISTENERS:
              if entry["name"] in have:
                  print(f"[=] {entry['name']} already exists, skipping")
                  continue
              # Each entry carries its own `type` (BeaconHTTP /
              # BeaconDNS / BeaconSMB / BeaconTCP / GopherTCP).
              # Falling back to BeaconHTTP for old/legacy entries that
              # don't have the field, so an in-place upgrade from the
              # pre-mixed-types listeners.json doesn't fail at boot.
              create(token, entry["name"],
                     entry.get("type", "BeaconHTTP"), entry["config"])

      if __name__ == "__main__":
          main()

  - path: /etc/systemd/system/adaptix.service
    permissions: "0644"
    content: |
      [Unit]
      Description=AdaptixC2 Teamserver
      After=network-online.target
      Wants=network-online.target

      [Service]
      Type=simple
      WorkingDirectory=/opt/adaptix/AdaptixC2
      ExecStart=/opt/adaptix/AdaptixC2/dist/adaptixserver -profile /opt/adaptix/profile.yaml
      Restart=on-failure
      RestartSec=5
      StandardOutput=append:/var/log/adaptix.log
      StandardError=append:/var/log/adaptix.log
      # ---- Go build env for runtime-spawned `go build` calls --------------
      # The gopher_agent extender shells out to `go build` per implant
      # generation. Under systemd the daemon's env doesn't include HOME /
      # GOPATH / GOMODCACHE / PATH by default, so go errors out with:
      #   "go: module cache not found: neither GOMODCACHE nor GOPATH is set"
      # Setting them here makes the per-build subprocess inherit the same
      # cache the initial build was compiled against (warm) and prevents
      # the toolchain from auto-downloading a different Go to $HOME/sdk/.
      Environment=HOME=/root
      Environment=GOPATH=/root/go
      Environment=GOMODCACHE=/root/go/pkg/mod
      Environment=GOCACHE=/root/.cache/go-build
      Environment=GOTOOLCHAIN=local
      Environment=PATH=/usr/local/go/bin:/usr/local/bin:/usr/bin:/bin

      [Install]
      WantedBy=multi-user.target

  - path: /etc/systemd/system/adaptix-listeners.service
    permissions: "0644"
    content: |
      [Unit]
      Description=AdaptixC2 listener pre-config (one-shot)
      After=adaptix.service
      Requires=adaptix.service

      [Service]
      Type=oneshot
      RemainAfterExit=true
      Environment=ADAPTIX_USER=${operator_user}
      Environment=ADAPTIX_PASS=${teamserver_password}
      ExecStart=/usr/bin/python3 /opt/adaptix/configure_listeners.py
      StandardOutput=append:/var/log/adaptix-listeners.log
      StandardError=append:/var/log/adaptix-listeners.log

      [Install]
      WantedBy=multi-user.target

  # ---- Filebeat → RedELK shipper -------------------------------------
  # Used only when ${redelk_ip} is non-empty (RedELK exists in the
  # scenario's shared_infrastructure). Plain-text Logstash :5044 — swap
  # in TLS certs from RedELK's initial-setup.sh post-deploy.
  - path: /etc/filebeat/filebeat.yml.tmpl
    permissions: "0640"
    content: |
      filebeat.inputs:
        - type: log
          enabled: true
          paths:
            - /var/log/adaptix.log
            - /var/log/adaptix-build.log
            - /var/log/adaptix-listeners.log
          fields:
            infra: c2
            infralog: c2log
            c2_program: adaptix
            c2_server: adaptix-${student_id}
          fields_under_root: true
          tags: ["c2", "adaptix"]
      output.logstash:
        hosts: ["__REDELK_IP__:5044"]
        ssl.enabled: false

runcmd:
  # ---- 0. Belt-and-suspenders: ensure ranger has the operator SSH key.
  #         cloud-init's `users:` block above SHOULD plant
  #         ssh_authorized_keys for this user, but we've seen
  #         non-deterministic cloud-init failures where users_groups
  #         creates the user without the keys taking effect (sliver +
  #         mythic specifically on redteam-lab in May 2026; adaptix
  #         unaffected by the same template — same render, different
  #         luck). Adding the same defense here for symmetry.
  #
  #         APPEND-ONLY (grep-then-append). The OLD chpasswd +
  #         echo-into-authorized_keys lines were removed previously
  #         because they OVERWROTE the file with empty content when
  #         they raced users_groups — this version never overwrites,
  #         no-op once the key is in place.
  - |
    RANGER='${linux_user}'
    PUBKEY='${ssh_pubkey}'
    if [ -n "$PUBKEY" ]; then
      id "$RANGER" >/dev/null 2>&1 || useradd -m -s /bin/bash "$RANGER"
      mkdir -p /home/"$RANGER"/.ssh
      touch    /home/"$RANGER"/.ssh/authorized_keys
      grep -qF "$PUBKEY" /home/"$RANGER"/.ssh/authorized_keys \
        || echo "$PUBKEY" >> /home/"$RANGER"/.ssh/authorized_keys
      chown -R "$RANGER":"$RANGER" /home/"$RANGER"/.ssh
      chmod 0700 /home/"$RANGER"/.ssh
      chmod 0600 /home/"$RANGER"/.ssh/authorized_keys
    fi
  - hostnamectl set-hostname c2-${student_id}
  - sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
  - systemctl restart ssh

  # Self-signed TLS for the teamserver (commander :9000 + the 5 listener
  # ports all reuse this cert; redirector terminates real TLS for clients).
  - openssl req -x509 -newkey rsa:2048 -nodes -days 825
      -keyout /opt/adaptix/server.rsa.key
      -out /opt/adaptix/server.rsa.crt
      -subj "/CN=adaptix-${student_id}"
  - chmod 600 /opt/adaptix/server.rsa.key

  # Install Go 1.22 from upstream tarball. Debian 12's apt golang is 1.19
  # which is too old for AdaptixC2's go.mod (requires 1.21+).
  - |
    # 1.25.4 required: Adaptix Makefile sets GOEXPERIMENT=jsonv2 which
    # only exists on Go 1.25+ (earlier versions exit with
    # 'go: unknown GOEXPERIMENT jsonv2').
    GO_VER=1.25.4
    if ! /usr/local/go/bin/go version 2>/dev/null | grep -q "go$${GO_VER}"; then
      curl -fsSL "https://go.dev/dl/go$${GO_VER}.linux-amd64.tar.gz" -o /tmp/go.tgz
      rm -rf /usr/local/go && tar -C /usr/local -xzf /tmp/go.tgz
      ln -sf /usr/local/go/bin/go    /usr/local/bin/go
      ln -sf /usr/local/go/bin/gofmt /usr/local/bin/gofmt
      rm -f /tmp/go.tgz
    fi
    go version > /var/log/adaptix-build.log

  # Build AdaptixC2 from source.
  # Reference: https://github.com/Adaptix-Framework/AdaptixC2
  - cd /opt/adaptix && git clone --depth 1 https://github.com/Adaptix-Framework/AdaptixC2.git
  # Build server + extender plugins together. `server-ext` is the upstream
  # canonical target that produces dist/adaptixserver AND the .so listener
  # plugins referenced from profile.yaml. Without the .so files, the
  # teamserver starts but rejects every listener.
  #
  # Use block-scalar form so we can `export PATH` first (cloud-init runs
  # each runcmd item in a fresh shell, so the `export` only applies to
  # the make call within the same item). The earlier form
  #   `PATH=... (make ...)`
  # is bash-invalid: PATH=value before a SUBSHELL '(' doesn't propagate
  # the assignment — make would use the system /usr/bin/go (1.19) and
  # silently fail the module compile.
  - |
    set -x
    cd /opt/adaptix/AdaptixC2
    /usr/local/go/bin/go version >> /var/log/adaptix-build.log 2>&1

    # Build server + plugins with PINNED Go. Critical env vars:
    #   PATH      - /usr/local/go/bin first
    #   HOME      - /root (Go uses HOME/go for module cache by default)
    #   GOPATH    - explicit
    #   GOMODCACHE- explicit
    #   GOCACHE   - explicit
    #   GOTOOLCHAIN=local - critical. Go 1.21+ honors the `toolchain`
    #     directive in go.mod and SILENTLY downloads a newer Go (e.g.
    #     go1.25.4) to $HOME/sdk/, then builds with it instead of our
    #     pinned /usr/local/go (1.22.7). Force local-only.
    # Without HOME, go errors: "module cache not found: neither
    # GOMODCACHE nor GOPATH is set".
    export PATH=/usr/local/go/bin:/usr/local/bin:$PATH
    export HOME=/root
    export GOPATH=/root/go
    export GOMODCACHE=/root/go/pkg/mod
    export GOCACHE=/root/.cache/go-build
    export GOTOOLCHAIN=local

    {
      # Server: let upstream `make server` handle the cd-into-AdaptixServer
      # dance. Fall back to direct go build from AdaptixServer/ if make fails.
      make server || (cd AdaptixServer && /usr/local/go/bin/go build -o ../dist/adaptixserver .)

      # Build each extender as a Go plugin. Filename must match the
      # extender's config.yaml `extender_file:` field (convention swaps
      # dirname parts: beacon_listener_http/ -> listener_beacon_http.so).
      for d in AdaptixServer/extenders/*/; do
        base=$(basename "$d")
        expected_so=$(grep -E '^extender_file:' "$d/config.yaml" 2>/dev/null \
                        | sed -E 's/^extender_file:[[:space:]]*"([^"]+)".*/\1/' \
                        | head -n1)
        [ -z "$expected_so" ] && expected_so="$base.so"
        if [ ! -f "$d/$expected_so" ]; then
          (cd "$d" && /usr/local/go/bin/go build -buildmode=plugin -o "$expected_so" .)
        fi
      done
    } >> /var/log/adaptix-build.log 2>&1
    ls -la /opt/adaptix/AdaptixC2/dist/                  >> /var/log/adaptix-build.log 2>&1
    ls -la /opt/adaptix/AdaptixC2/AdaptixServer/extenders/*/*.so >> /var/log/adaptix-build.log 2>&1
    true

  # Sanity-check the binary BEFORE enabling systemd. Without this guard a
  # failed build leaves systemd looping forever on a missing executable
  # and masks the build-log error.
  - |
    if [ -x /opt/adaptix/AdaptixC2/dist/adaptixserver ]; then
      systemctl daemon-reload
      systemctl enable --now adaptix
      systemctl enable --now adaptix-listeners
      echo "AdaptixC2 + listener pre-config enabled" >> /var/log/adaptix-build.log
    else
      echo "ERROR: adaptixserver binary not built. See /var/log/adaptix-build.log" >> /var/log/adaptix-build.log
      echo "ERROR: adaptixserver binary not built — check upstream build instructions and rebuild manually." >&2
    fi

  # Filebeat → RedELK (skip when RedELK is absent from the scenario).
  # Forced to run as root via systemd drop-in so it can read every log
  # path even when systemd journals/files end up mode 0600.
  - |
    if [ -n "${redelk_ip}" ]; then
      curl -fsSL https://artifacts.elastic.co/GPG-KEY-elasticsearch | gpg --dearmor -o /usr/share/keyrings/elastic.gpg
      echo "deb [signed-by=/usr/share/keyrings/elastic.gpg] https://artifacts.elastic.co/packages/8.x/apt stable main" > /etc/apt/sources.list.d/elastic-8.x.list
      apt-get update -y && apt-get install -y filebeat
      sed "s|__REDELK_IP__|${redelk_ip}|g" /etc/filebeat/filebeat.yml.tmpl > /etc/filebeat/filebeat.yml
      chmod 0640 /etc/filebeat/filebeat.yml

      mkdir -p /etc/systemd/system/filebeat.service.d
      printf '[Service]\nUser=root\nGroup=root\n' > /etc/systemd/system/filebeat.service.d/override.conf
      systemctl daemon-reload

      systemctl enable --now filebeat
      echo "[+] Filebeat (as root) shipping AdaptixC2 logs to RedELK at ${redelk_ip}:5044"
    else
      echo "[i] RedELK not in scenario; Filebeat skipped"
    fi

  - |
    cat >/etc/motd <<EOM
    ============================================================
      AdaptixC2 — Operator Teamserver (student ${student_id})
      Commander port  : :9000 (Kali only via NSG)
      HTTPS listeners : :8443 azure / :8444 cloudfront
                        :8445 workers / :8446 fastly / :8447 other
      DNS listener    : :53  dns_BeaconDNS    (external)
      Gopher listener : :8448 gopher_GopherTCP (external)
      Internal        : smb_BeaconSMB pipe + tcp_BeaconTCP (metadata)
      Profile         : /opt/adaptix/profile.yaml
      Listener config : /opt/adaptix/listeners.json
      Logs            : /var/log/adaptix.log
      Listener log    : /var/log/adaptix-listeners.log
      Manage          : systemctl status adaptix adaptix-listeners
    ============================================================
    EOM
