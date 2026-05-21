#cloud-config
# =============================================================================
# Mythic C2 teamserver bootstrap.
# =============================================================================
# Layout (uniform across all three C2 frameworks):
#
#   :7443   Mythic web UI / GraphQL API (operator/commander port — Kali-only).
#           Note: Mythic's upstream-default port. Adaptix and BRC4 use :9000;
#           Mythic stays on :7443 because mythic-cli's docker-compose has
#           several hardcoded references to 7443 that don't all template
#           through the .env override cleanly.
#   :8443   httpx HTTPS listener instance — Azure Front Door origin
#   :8444   httpx HTTPS listener instance — CloudFront origin
#   :8445   httpx HTTPS listener instance — workers.dev origin
#   :8446   httpx HTTPS listener instance — Fastly origin
#   :8447   httpx HTTPS listener instance — "other" origin
#
# Mythic spawns N httpx listener instances from the `instances` array in
# the httpx C2 profile's config.json. We override that file with five
# entries (ports 8443–8447, ssl=true, bind 0.0.0.0) before starting the
# httpx container. Per-CDN routing/auth is handled at the redirector
# (nginx maps X-Api-<header>:<UUID> → upstream port).
#
# Reference:
#   https://github.com/MythicC2Profiles/httpx
#   https://r4ulcl.com/posts/getting-started-with-mythic-c2/
# =============================================================================
package_update: true
packages:
  - git
  - curl
  - wget
  - openssh-server
  - ca-certificates
  - jq
  - make
  - python3
  - python3-pip
  - gnupg      # needed by `gpg --dearmor` when adding the Elastic apt key

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
  - path: /opt/mythic-env
    permissions: "0640"
    content: |
      MYTHIC_ADMIN_USER=mythic_admin
      MYTHIC_ADMIN_PASSWORD=${mythic_admin_password}
      # Mythic stays on its upstream-default 7443 (Adaptix and BRC4 use
      # 9000 for the commander port — Mythic is the asymmetric one).
      # NSG enforces Kali-only inbound on :7443 for this VM.
      MYTHIC_SERVER_PORT=7443
      DOCUMENTATION_PORT=8090
      JUPYTER_PORT=8888
      RABBITMQ_PORT=5672
      MYTHIC_SERVER_BIND_LOCALHOST_ONLY=false
      ALLOWED_IP_BLOCKS=0.0.0.0/0
      DEFAULT_OPERATION_NAME=Operation_${student_id}

  # ---- httpx multi-instance config -------------------------------------
  # Five HTTPS listener instances, ports 8443..8447, all bind 0.0.0.0,
  # all share the same self-signed cert. The redirector terminates real
  # TLS for clients; this cert is only seen by nginx during the
  # back-channel proxy_pass.
  - path: /opt/mythic-httpx-config.json
    permissions: "0644"
    content: |
      {
        "instances": [
          {"port": 8443, "bind_ip": "0.0.0.0", "use_ssl": true,
           "key_path": "privkey.pem", "cert_path": "fullchain.pem",
           "debug": false, "payloads": {}},
          {"port": 8444, "bind_ip": "0.0.0.0", "use_ssl": true,
           "key_path": "privkey.pem", "cert_path": "fullchain.pem",
           "debug": false, "payloads": {}},
          {"port": 8445, "bind_ip": "0.0.0.0", "use_ssl": true,
           "key_path": "privkey.pem", "cert_path": "fullchain.pem",
           "debug": false, "payloads": {}},
          {"port": 8446, "bind_ip": "0.0.0.0", "use_ssl": true,
           "key_path": "privkey.pem", "cert_path": "fullchain.pem",
           "debug": false, "payloads": {}},
          {"port": 8447, "bind_ip": "0.0.0.0", "use_ssl": true,
           "key_path": "privkey.pem", "cert_path": "fullchain.pem",
           "debug": false, "payloads": {}}
        ]
      }

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
            - /var/log/mythic-build.log
        - type: container
          enabled: true
          paths:
            - /var/lib/docker/containers/*/*.log
          fields:
            mythic_container: true
      processors:
        - add_fields:
            target: ""
            fields:
              infra: c2
              infralog: c2log
              c2_program: mythic
              c2_server: mythic-${student_id}
      tags: ["c2", "mythic"]
      output.logstash:
        hosts: ["__REDELK_IP__:5044"]
        ssl.enabled: false

  # ---- Post-install bootstrap script -----------------------------------
  - path: /opt/mythic-bootstrap.sh
    permissions: "0750"
    content: |
      #!/usr/bin/env bash
      set -uo pipefail
      LOG=/var/log/mythic-build.log
      exec > >(tee -a "$LOG") 2>&1
      echo "[*] Mythic bootstrap starting at $(date -u +%FT%TZ)"

      # Make sure the upstream Go (installed in runcmd above) is on PATH
      # — `make mythic-cli` invokes `go build` and Debian's apt golang
      # would shadow our 1.22 install otherwise.
      export PATH=/usr/local/go/bin:/usr/local/bin:/usr/bin:/bin
      go version || { echo "ERROR: go missing from PATH"; exit 1; }

      cd /opt/mythic

      # Build mythic-cli first.
      make 2>&1 || true

      # Override .env values from /opt/mythic-env
      while IFS='=' read -r key value; do
          [[ -z "$key" || "$key" =~ ^# ]] && continue
          ./mythic-cli config "$key" "$value" || true
      done < /opt/mythic-env

      # Agents + C2 profiles. Set mirrors base42's teamserver_role_mythic.
      ./mythic-cli install github https://github.com/MythicC2Profiles/http        || true
      ./mythic-cli install github https://github.com/MythicC2Profiles/httpx       || true
      ./mythic-cli install github https://github.com/MythicC2Profiles/dynamichttp || true
      ./mythic-cli install github https://github.com/MythicC2Profiles/basic_logger || true
      ./mythic-cli install github https://github.com/MythicAgents/Apollo          || true
      ./mythic-cli install github https://github.com/MythicAgents/Athena          || true
      ./mythic-cli install github https://github.com/MythicAgents/poseidon        || true

      # Override the httpx config with our 5-instance version, then drop
      # a self-signed cert into the container's c2_code directory.
      HTTPX_DIR=/opt/mythic/InstalledServices/httpx/c2_code
      if [[ ! -d "$HTTPX_DIR" ]]; then
          # Fallback layouts seen in older Mythic versions
          HTTPX_DIR=$(find /opt/mythic -type d -path '*/httpx/c2_code' 2>/dev/null | head -n1)
      fi
      if [[ -d "$HTTPX_DIR" ]]; then
          cp /opt/mythic-httpx-config.json "$HTTPX_DIR/config.json"
          openssl req -x509 -newkey rsa:2048 -nodes -days 825 \
              -keyout "$HTTPX_DIR/privkey.pem" \
              -out    "$HTTPX_DIR/fullchain.pem" \
              -subj   "/CN=mythic-${student_id}"
          chmod 600 "$HTTPX_DIR/privkey.pem"
          echo "[+] httpx config + cert installed at $HTTPX_DIR"

          # Expose httpx ports 8443-8447 to the host via a docker-compose
          # OVERRIDE file (docker-compose.override.yml is auto-merged by
          # docker compose when alongside the base file). This is cleaner
          # than regex-editing the upstream compose: the override is
          # additive, survives `mythic-cli install httpx` re-runs, and
          # doesn't depend on the upstream file's indentation.
          HTTPX_COMPOSE=$(find /opt/mythic -maxdepth 5 -type f -name docker-compose.yml -path '*httpx*' 2>/dev/null | head -n1)
          if [[ -n "$HTTPX_COMPOSE" ]]; then
              HTTPX_DIR_COMPOSE=$(dirname "$HTTPX_COMPOSE")
              # Discover the service name from the upstream compose. The
              # canonical Mythic httpx profile names the service `httpx`,
              # but defensive parsing keeps us working if upstream renames.
              SVC=$(python3 -c "
import sys, re
src = open('$HTTPX_COMPOSE').read()
# Find first 'services:' block, then the first key under it.
m = re.search(r'^services:\s*\n((?:  [a-zA-Z0-9_-]+:.*\n(?:    .*\n)*)+)', src, re.M)
if m:
    inner = m.group(1)
    n = re.search(r'^  ([a-zA-Z0-9_-]+):', inner, re.M)
    if n:
        print(n.group(1))
" 2>/dev/null)
              SVC=$${SVC:-httpx}
              OVERRIDE="$HTTPX_DIR_COMPOSE/docker-compose.override.yml"
              cat > "$OVERRIDE" <<OVR
# Auto-generated by terra-range cloud-init. Exposes the httpx 5-instance
# listener ports (8443-8447) on the host so the per-student redirector
# nginx can proxy beacon traffic upstream.
services:
  $SVC:
    ports:
      - "8443:8443"
      - "8444:8444"
      - "8445:8445"
      - "8446:8446"
      - "8447:8447"
OVR
              echo "[+] wrote docker-compose.override.yml for service '$SVC'"
          else
              echo "[!] No httpx docker-compose.yml found — listener ports may not be exposed"
          fi
      else
          echo "[!] httpx c2_code dir not found — multi-listener config skipped"
      fi

      # Boot Mythic core (Hasura, postgres, rabbitmq, mythic_server).
      ./mythic-cli start || true

      # Start the httpx C2 profile container — reads config.json and
      # opens all 5 listener ports.
      ./mythic-cli c2 start httpx || true

      echo "[+] Mythic bootstrap complete at $(date -u +%FT%TZ)"

runcmd:
  # ---- 0. Belt-and-suspenders: ensure ranger has the operator SSH key.
  #         cloud-init's `users:` block above SHOULD plant
  #         ssh_authorized_keys for this user, but we've seen
  #         non-deterministic cloud-init failures where users_groups
  #         creates the user without the keys taking effect (mythic was
  #         one of the affected VMs on redteam-lab in May 2026).
  #
  #         APPEND-ONLY. Uses grep-then-append so an already-correct
  #         authorized_keys is left untouched (no race with
  #         users_groups overwriting it back). Idempotent on every boot.
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
  - hostnamectl set-hostname mythic-${student_id}
  - sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
  - systemctl restart ssh

  # Docker (Mythic requires Docker + Compose v2)
  - curl -fsSL https://get.docker.com | sh
  - usermod -aG docker ${linux_user}

  # Install Go 1.22 from upstream tarball — mythic-cli is a Go binary
  # whose go.mod requires 1.21+; Debian 12's apt golang-go is 1.19.
  - |
    GO_VER=1.22.7
    if ! /usr/local/go/bin/go version 2>/dev/null | grep -q "go$${GO_VER}"; then
      curl -fsSL "https://go.dev/dl/go$${GO_VER}.linux-amd64.tar.gz" -o /tmp/go.tgz
      rm -rf /usr/local/go && tar -C /usr/local -xzf /tmp/go.tgz
      ln -sf /usr/local/go/bin/go    /usr/local/bin/go
      ln -sf /usr/local/go/bin/gofmt /usr/local/bin/gofmt
      rm -f /tmp/go.tgz
    fi

  # Clone Mythic
  - git clone --depth 1 https://github.com/its-a-feature/Mythic.git /opt/mythic
  - chown -R ${linux_user}:${linux_user} /opt/mythic

  - PATH=/usr/local/go/bin:/usr/local/bin:/usr/bin:/bin bash /opt/mythic-bootstrap.sh

  # Filebeat → RedELK (skip when RedELK is absent from the scenario).
  # Run as root so it can read /var/lib/docker/containers/*/*.log and
  # any mode-0600 logs Mythic services produce.
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
      echo "[+] Filebeat (as root) shipping Mythic logs to RedELK at ${redelk_ip}:5044"
    else
      echo "[i] RedELK not in scenario; Filebeat skipped"
    fi

  - |
    cat >/etc/motd <<EOM
    ============================================================
      Mythic C2 — Operator Teamserver (student ${student_id})
      Web UI / API    : https://<this-host>:7443/
      User            : mythic_admin
      Password        : (operator-issued, see terraform output)
      HTTPS listeners : :8443 azure / :8444 cloudfront
                        :8445 workers / :8446 fastly / :8447 other
      Repo            : /opt/mythic
      Logs            : /var/log/mythic-build.log
      Manage          : cd /opt/mythic && ./mythic-cli {start|stop|status|logs}
                        ./mythic-cli c2 {start|stop|config} httpx
    ============================================================
    EOM
