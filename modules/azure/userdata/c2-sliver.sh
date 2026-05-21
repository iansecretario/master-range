#cloud-config
# =============================================================================
# Sliver C2 teamserver bootstrap.   https://sliver.sh
# =============================================================================
# Layout (uniform with the other 3 C2 frameworks in this range):
#
#   :31337  multiplayer gRPC operator endpoint (Kali-only, NSG-enforced)
#   :8443   HTTPS implant listener — Azure Front Door origin
#   :8444   HTTPS implant listener — CloudFront origin
#   :8445   HTTPS implant listener — Cloudflare workers.dev origin
#   :8446   HTTPS implant listener — Fastly origin
#   :8447   HTTPS implant listener — "other" origin
#
# Sliver's `https` listener serves on a port; the auth header is enforced
# at the redirector (nginx) layer — sliver doesn't natively gate on a
# custom HTTP header, but the redirector won't proxy a beacon to sliver
# unless the per-CDN X-Api-* header is present and matches.
#
# Operator config (.cfg) files are written to /opt/sliver-cfg/ with the
# teamserver's PUBLIC fronts cleared out (operator imports it on Kali
# and connects via the per-student private IP through NSG). The
# `summary` terraform output surfaces the path; copy down via SCP from
# Guacamole's Kali RDP, then `sliver-client import operator.cfg`.
# =============================================================================
package_update: true
packages:
  - curl
  - openssl
  - openssh-server
  - jq
  - ca-certificates

# =============================================================================
# bootcmd: plant ranger + ssh key in the EARLIEST cloud-init phase.
# =============================================================================
# Why bootcmd instead of relying on `users:` alone:
#   - `users:` runs in cloud-init's cloud-config phase (~1-2 min after
#     boot). On this Debian/cloud-init combo we've seen non-deterministic
#     failures where the user gets created but ssh_authorized_keys is
#     never planted (sliver + mythic hit this on repeat fresh deploys;
#     adaptix + brc4 generally don't — same template, different luck).
#   - `runcmd` runs in cloud-final phase, which can be >5 min on the
#     C2 boxes because their heavy Go/Docker install runs first. By then
#     ansible-from-guac has already tried + failed its SSH-reachable
#     probe (180s timeout in the common role's wait_for_connection).
#   - `bootcmd` runs in cloud-init's INIT phase (~10-15 sec after boot,
#     before sshd accepts its first connection). Planting the key here
#     means SSH auth IS RIGHT from the very first probe — no race.
#
# bootcmd runs on EVERY boot (including reboots), so this also self-heals
# a VM whose authorized_keys got wiped post-deploy. Idempotent:
# grep-then-append leaves any other keys (including those `users:`
# successfully planted later) untouched.
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

# Operator user + SSH key via cloud-init's `users:` directive — the
# SAME mechanism the other three C2 userdata files use (c2-server.sh,
# c2-mythic.sh, c2-brc4.sh). c2-sliver.sh previously had NO `users:`
# block and instead hand-rolled the key into authorized_keys from a
# `runcmd` echo — the odd one out, and fragile (depends on runcmd
# ordering, the runcmd module actually firing, and ~/.ssh perms). That
# raced badly enough that the sliver box repeatedly came up with an
# EMPTY ranger authorized_keys, so ansible-from-guac couldn't SSH in
# ("Permission denied (publickey,password)"). cloud-init's `users:`
# stage creates the user, ~/.ssh, and authorized_keys atomically and
# early — before write_files / runcmd — so SSH auth is reliable.
# (The bootcmd above is the REAL safety net; `users:` provides the
# proper plain_text_passwd + sudoers entry, which bootcmd doesn't.)
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
  - path: /opt/sliver-bootstrap/cdn_headers.json
    permissions: "0644"
    content: |
      ${cdn_headers_json}

  - path: /etc/systemd/system/sliver.service
    permissions: "0644"
    content: |
      [Unit]
      Description=Sliver C2 teamserver
      After=network.target

      [Service]
      Type=simple
      User=root
      ExecStart=/root/sliver-server daemon --lhost 0.0.0.0 --lport 31337
      Restart=on-failure
      RestartSec=5
      LimitNOFILE=65536

      [Install]
      WantedBy=multi-user.target

  - path: /opt/sliver-bootstrap/configure.sh
    permissions: "0755"
    content: |
      #!/usr/bin/env bash
      # Wait for sliver-server daemon to come up, then create operator
      # config + 5 HTTPS listeners (one per CDN, on 8443-8447).
      set -euo pipefail
      LOG=/var/log/sliver-bootstrap.log
      exec >>"$LOG" 2>&1

      echo "[$(date)] waiting for sliver daemon on :31337..."
      for i in $(seq 1 60); do
        if ss -tnlp 2>/dev/null | grep -q ':31337 '; then
          echo "[$(date)] daemon up"; break
        fi
        sleep 2
      done

      mkdir -p /opt/sliver-cfg
      chmod 700 /opt/sliver-cfg

      # Create operator config. sliver-server writes to ~/.sliver-server/configs
      # by default; --save targets a custom path.
      echo "[$(date)] creating operator config..."
      /root/sliver-server operator \
        --name operator \
        --lhost 10.${student_index}.1.11 \
        --lport 31337 \
        --save /opt/sliver-cfg/operator.cfg
      chmod 600 /opt/sliver-cfg/operator.cfg

      # Pre-create the 5 HTTPS listeners with --persistent so they
      # auto-start on every daemon boot. sliver-server's command shape
      # has varied across versions: recent ones prefer `console`
      # subcommand, older ones spawn the console with no subcommand.
      # We try both and verify port state.
      LISTENER_CMDS='https --lport 8443 --persistent
https --lport 8444 --persistent
https --lport 8445 --persistent
https --lport 8446 --persistent
https --lport 8447 --persistent
jobs
exit'

      # Each method wrapped in `timeout 60` — sliver-server console
      # can hang indefinitely waiting for terminal capabilities when
      # stdin is a pipe (no tty available in cloud-init context).
      echo "[$(date)] method A: sliver-server console"
      echo "$LISTENER_CMDS" | timeout 60 /root/sliver-server console 2>&1 | tee -a "$LOG" | tail -40 || true
      sleep 5
      listener_count=$(ss -lntp 2>/dev/null | grep -cE ':844[3-7][[:space:]]')

      if [ "$listener_count" -lt 5 ]; then
          echo "[$(date)] method B: bare sliver-server"
          echo "$LISTENER_CMDS" | timeout 60 /root/sliver-server 2>&1 | tee -a "$LOG" | tail -40 || true
          sleep 5
          listener_count=$(ss -lntp 2>/dev/null | grep -cE ':844[3-7][[:space:]]')
      fi

      echo "[$(date)] listener ports active: $listener_count/5"
      if [ "$listener_count" -lt 5 ]; then
          echo "[!] some listeners did NOT bind — './range repair' will retry"
      fi

      echo "[$(date)] sliver bootstrap complete"
      touch /var/lib/cloud/instance/sliver-configured

runcmd:
  # ---- 0. Belt-and-suspenders: ensure ranger has the operator SSH key.
  #         cloud-init's `users:` block above SHOULD plant
  #         ssh_authorized_keys, but in redteam-lab (May 2026) we saw
  #         non-deterministic cloud-init failures where users_groups
  #         created the ranger user successfully but DIDN'T persist
  #         the keys (sliver + mythic were affected on the same deploy;
  #         adaptix and brc4 were not — same template, different luck).
  #
  #         IMPORTANT: this is APPEND-ONLY (grep-then-append). The OLD
  #         hand-rolled chpasswd + echo-into-authorized_keys runcmd
  #         lines that lived here previously were removed because they
  #         OVERWROTE the file with empty content when they raced
  #         users_groups. This version never overwrites — it only adds
  #         the key if missing, leaves any other keys (including those
  #         users_groups did successfully plant) untouched, and is a
  #         no-op on every subsequent boot.
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

  # ---- 1. Install sliver-server (linux/amd64 release binary).
  # Resolve the actual server-binary asset URL via the GitHub release
  # API — BishopFox occasionally renames assets between releases, so
  # hardcoding the "/latest/download/sliver-server_linux" path breaks
  # whenever they ship a new naming scheme. We pull the latest release
  # JSON and pick the first asset matching server[-_]linux.
  - |
    LOG=/var/log/sliver-install.log
    exec >>"$LOG" 2>&1
    set -x
    mkdir -p /opt/sliver-bootstrap

    # NOTE: `$$|` is a templatefile escape for a literal `$|` (regex
    # end-of-line anchor + alternation). Without the `$$`, terraform
    # parses the bare `$` as the start of a `$${...}` placeholder and
    # fails the call with "function returned an inconsistent result".
    URL=$(curl -fsSL --retry 3 https://api.github.com/repos/BishopFox/sliver/releases/latest \
           | grep -oE '"browser_download_url"[^"]+"[^"]+"' \
           | grep -oE 'https[^"]+' \
           | grep -E '/sliver[-_]server[-_]linux($$|[-_]amd64)' \
           | grep -v '\.asc\|\.sig\|\.sha' \
           | head -n1)
    if [ -z "$URL" ]; then
      URL="https://github.com/BishopFox/sliver/releases/download/v1.5.42/sliver-server_linux"
      echo "[!] couldn't resolve via API; falling back to v1.5.42"
    fi
    echo "[$(date)] downloading: $URL"

    if ! curl -fsSL --retry 5 --retry-delay 10 --max-time 600 "$URL" -o /root/sliver-server; then
        echo "ERROR: sliver-server download failed; sliver will not start"
        exit 0   # don't fail cloud-init — let other services come up
    fi
    if [ ! -s /root/sliver-server ]; then
        echo "ERROR: sliver-server binary is 0-byte; aborting"
        rm -f /root/sliver-server
        exit 0
    fi
    chmod +x /root/sliver-server
    /root/sliver-server unpack --force || echo "WARN: unpack returned non-zero (some assets may be missing)"
    file /root/sliver-server
    echo "[$(date)] sliver-server installed: $(ls -la /root/sliver-server)"

  # ---- 2. Boot the daemon under systemd (only if binary exists).
  - |
    if [ -x /root/sliver-server ]; then
        systemctl daemon-reload
        systemctl enable --now sliver.service
        echo "[$(date)] sliver.service enabled" >> /var/log/sliver-install.log
    else
        echo "[$(date)] skipping sliver.service start (no binary)" >> /var/log/sliver-install.log
    fi

  # ---- 3. Configure operator + listeners (after daemon is up).
  - |
    if [ -x /root/sliver-server ]; then
        bash /opt/sliver-bootstrap/configure.sh &
    fi

  # ---- 4. RedELK Filebeat shipper (sliver's audit log + access log).
  # Empty redelk_ip => RedELK isn't in this scenario, skip.
  - |
    if [ -n "${redelk_ip}" ]; then
      curl -fsSL --retry 3 https://artifacts.elastic.co/downloads/beats/filebeat/filebeat-8.13.4-amd64.deb -o /tmp/filebeat.deb || true
      dpkg -i /tmp/filebeat.deb || apt-get -f install -y || true
      cat >/etc/filebeat/filebeat.yml <<FB
    filebeat.inputs:
      - type: filestream
        id: sliver-audit
        paths:
          - /root/.sliver/logs/*.log
        fields:
          source_type: sliver-audit
          student: "${student_id}"
        fields_under_root: true
    output.logstash:
      hosts: ["${redelk_ip}:5044"]
    FB
      systemctl enable --now filebeat || true
    fi
