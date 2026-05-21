#cloud-config
# =============================================================================
# Brute Ratel C4 (BRC4) teamserver bootstrap — PER-STUDENT.
# =============================================================================
# License-gated. WITHOUT operator-supplied License ID + Activation Key
# + Email + Blob URL, the bootstrap aborts cleanly so the rest of the
# range still deploys.
#
# Scenarios that include c2-brc4 MUST set students.count: 1 (the
# generator enforces this). BRC4 license caps the range at one
# teamserver activation.
#
# Pattern lifted from base42/teamserver_role_brc4:
#   /opt/bruteratel/brute-ratel-linx64
#   profile JSON drops at  profiles/c2.profile  AND  autosave.profile
#   activation via stdin (KEY\nMAIL\n)
#   systemd:  brute-ratel-linx64 -ratel -r autosave.profile
#
# Layout (uniform across all three C2 frameworks):
#   :9000   commander/operator port (Kali-only via NSG)
#   :8443   HTTPS listener "azure_HTTPS"      (Azure Front Door origin)
#   :8444   HTTPS listener "cloudfront_HTTPS" (CloudFront origin)
#   :8445   HTTPS listener "workers_HTTPS"    (workers.dev origin)
#   :8446   HTTPS listener "fastly_HTTPS"     (Fastly origin)
#   :8447   HTTPS listener "other_HTTPS"      (operator-managed origin)
#   :18080  commander binary serve (Kali only via iptables, 10-min window)
# =============================================================================
package_update: true
packages:
  - curl
  - wget
  - openssh-server
  - ca-certificates
  - jq
  - python3
  - net-tools
  - iptables
  - iptables-persistent
  - unzip
  - file       # used by Phase-1 archive-format detection
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
  - path: /opt/brc4/license.json
    permissions: "0600"
    owner: root:root
    content: |
      {
        "license_id":     "${brc4_license_id}",
        "activation_key": "${brc4_activation_key}",
        "email":          "${brc4_email}",
        "blob_url":       "${brc4_blob_url}"
      }

  - path: /opt/brc4/c2.profile
    permissions: "0640"
    owner: root:root
    content: |
      ${brc4_profile_json}

  - path: /opt/brc4/bootstrap.sh
    permissions: "0700"
    owner: root:root
    content: |
      #!/usr/bin/env bash
      set -uo pipefail
      LOG=/var/log/brc4-bootstrap.log
      exec > >(tee -a "$LOG") 2>&1

      echo "[*] BRC4 bootstrap starting at $(date -u +%FT%TZ)"

      LIC_FILE=/opt/brc4/license.json
      LIC_ID=$(jq -r '.license_id'     "$LIC_FILE")
      LIC_KEY=$(jq -r '.activation_key' "$LIC_FILE")
      LIC_EMAIL=$(jq -r '.email'        "$LIC_FILE")
      BLOB_URL=$(jq -r '.blob_url'      "$LIC_FILE")

      if [[ -z "$LIC_ID" || "$LIC_ID" == "null" || -z "$LIC_KEY" || "$LIC_KEY" == "null" ]]; then
          echo "[!] No BRC4 license credentials provided. Skipping BRC4 install."
          rm -f "$LIC_FILE"
          exit 0
      fi
      if [[ -z "$BLOB_URL" || "$BLOB_URL" == "null" ]]; then
          echo "[X] BRC4 blob_url is required (no online download supported)."
          shred -u "$LIC_FILE" 2>/dev/null || rm -f "$LIC_FILE"
          exit 1
      fi

      # Phase 1: download + extract.
      echo "[*] Downloading BRC4 archive..."
      ARCHIVE=/tmp/brc4-archive
      if ! curl -sS -fL --max-time 600 -o "$ARCHIVE" "$BLOB_URL"; then
          echo "[X] Blob download failed (network? expired SAS?)"
          shred -u "$LIC_FILE" 2>/dev/null || rm -f "$LIC_FILE"
          exit 1
      fi

      cd /opt
      if file "$ARCHIVE" | grep -qi 'gzip'; then
          tar -xzf "$ARCHIVE"
      elif file "$ARCHIVE" | grep -qi 'tar archive'; then
          tar -xf "$ARCHIVE"
      elif file "$ARCHIVE" | grep -qi 'zip'; then
          unzip -q "$ARCHIVE" -d /opt/
      else
          echo "[X] Unknown archive format: $(file "$ARCHIVE")"
          shred -u "$LIC_FILE" 2>/dev/null || rm -f "$LIC_FILE"
          exit 1
      fi

      if [[ ! -d /opt/bruteratel ]]; then
          BR_DIR=$(find /opt -maxdepth 2 -type d -name '*ratel*' 2>/dev/null | head -n1)
          [[ -n "$BR_DIR" ]] && ln -s "$BR_DIR" /opt/bruteratel
      fi

      if [[ ! -x /opt/bruteratel/brute-ratel-linx64 ]]; then
          echo "[X] /opt/bruteratel/brute-ratel-linx64 not found after extract"
          ls -laR /opt/bruteratel 2>/dev/null | head -n 50
          shred -u "$LIC_FILE" 2>/dev/null || rm -f "$LIC_FILE"
          exit 1
      fi

      # Phase 2: self-signed back-channel cert.
      cd /opt/bruteratel
      openssl req -x509 -newkey rsa:4096 -keyout key.pem -out cert.pem \
          -sha256 -days 3650 -nodes \
          -subj "/CN=brc4-${student_id}"

      # Phase 3: activate teamserver via stdin.
      # Prompt order in current BRC4 builds is EMAIL first, then KEY.
      # If your version differs, swap the two %s args below.
      echo "[*] Activating BRC4..."
      printf '%s\n%s\n' "$LIC_EMAIL" "$LIC_KEY" \
          | timeout 120 /opt/bruteratel/brute-ratel-linx64 \
          2>&1 | tee -a /var/log/brc4-activate.log || true

      # Phase 4: drop c2.profile at both expected locations.
      mkdir -p /opt/bruteratel/profiles
      cp /opt/brc4/c2.profile /opt/bruteratel/profiles/c2.profile
      cp /opt/brc4/c2.profile /opt/bruteratel/autosave.profile
      chmod 0600 /opt/bruteratel/profiles/c2.profile /opt/bruteratel/autosave.profile

      # Phase 5a: serve commander binary to Kali (10-min, Kali-only).
      # Kali is Linux, so prefer the Linux-specific commander binary.
      # Recent BRC4 archives ship it as `commander-linux.sh` (a wrapper
      # that invokes the underlying Qt binary). Fall back to other
      # plausible Linux names, then to broader `*commander*`/`*client*`
      # globs as a last resort.
      KALI_IP="10.${student_index}.1.20"
      CMD_BIN=$(
          for pat in \
              'commander-linux.sh' \
              'commander-linux*' \
              'commander-linx*' \
              'Commander-x64' \
              '*commander*linux*' \
              '*linux*commander*' \
              '*commander*' \
              '*client*'; do
              hit=$(find /opt/bruteratel -maxdepth 3 -type f -iname "$pat" 2>/dev/null | head -n1)
              if [[ -n "$hit" ]]; then
                  echo "$hit"
                  break
              fi
          done
      )
      if [[ -n "$CMD_BIN" ]]; then
          chmod +x "$CMD_BIN"
          install -m 0644 "$CMD_BIN" /opt/bruteratel/commander.bin
          ( cd /opt/bruteratel && sha256sum commander.bin > commander.sha256 )

          iptables -A INPUT -p tcp --dport 18080 -s "$KALI_IP/32" -j ACCEPT
          iptables -A INPUT -p tcp --dport 18080                  -j DROP
          iptables-save > /etc/iptables/rules.v4 2>/dev/null || true

          MY_IP=$(ip -4 addr show scope global \
              | awk '/inet/ {print $2}' | cut -d/ -f1 | head -n1)
          (
              cd /opt/bruteratel
              timeout 600 python3 -m http.server -b "$MY_IP" 18080 \
                  --directory /opt/bruteratel >> /var/log/brc4-serve.log 2>&1
              shred -u /opt/bruteratel/commander.bin    2>/dev/null || rm -f /opt/bruteratel/commander.bin
              shred -u /opt/bruteratel/commander.sha256 2>/dev/null || rm -f /opt/bruteratel/commander.sha256
              echo "[+] Commander serve window closed at $(date -u +%FT%TZ)" >> /var/log/brc4-serve.log
          ) &
          disown
          echo "[+] Commander on http://$MY_IP:18080/commander.bin (Kali-only, 10-min)"
      else
          echo "[!] No commander/client binary found; skipping serve."
      fi

      # Phase 5b: systemd unit + enable.
      # NOTE: avoiding heredoc-inside-bash-script-inside-cloud-init.
      # The heredoc closer SVC ends up at col 2 after YAML strips the
      # content base indent, which means bash never terminates the
      # heredoc and the rest of the script gets eaten -> "unexpected
      # end of file" cascades. printf-with-newlines sidesteps this.
      {
          printf '%s\n' '[Unit]'
          printf '%s\n' 'Description=Brute Ratel C4 Teamserver'
          printf '%s\n' 'After=network-online.target'
          printf '%s\n' 'Wants=network-online.target'
          printf '\n'
          printf '%s\n' '[Service]'
          printf '%s\n' 'WorkingDirectory=/opt/bruteratel/'
          printf '%s\n' 'Type=simple'
          printf '%s\n' 'User=root'
          printf '%s\n' 'ExecStart=/opt/bruteratel/brute-ratel-linx64 -ratel -r /opt/bruteratel/autosave.profile'
          printf '%s\n' 'Restart=always'
          printf '%s\n' 'RestartSec=5'
          printf '%s\n' 'StartLimitIntervalSec=0'
          printf '%s\n' 'StandardOutput=append:/var/log/brc4.log'
          printf '%s\n' 'StandardError=append:/var/log/brc4.log'
          printf '\n'
          printf '%s\n' '[Install]'
          printf '%s\n' 'WantedBy=multi-user.target'
      } > /etc/systemd/system/brc4.service

      systemctl daemon-reload
      systemctl enable --now brc4.service

      # Phase 6: credential cleanup. Cloud-init logs, the cloud-init
      # instance directory, AND brc4-activate.log (which captures stdin
      # echoes the BRC4 binary may have made during activation) get
      # scrubbed of license strings before Filebeat starts harvesting.
      shred -u "$LIC_FILE" 2>/dev/null || rm -f "$LIC_FILE"
      for pattern in "$LIC_ID" "$LIC_KEY" "$LIC_EMAIL"; do
          [[ -z "$pattern" || "$pattern" == "null" ]] && continue
          esc=$(printf '%s\n' "$pattern" | sed 's/[][\.*^$(){}?+|/]/\\&/g')
          for f in /var/log/cloud-init.log /var/log/cloud-init-output.log /var/log/brc4-activate.log; do
              [[ -f "$f" ]] && sed -i "s/$esc/[REDACTED]/g" "$f" 2>/dev/null || true
          done
          for d in /var/lib/cloud/instances/*/; do
              for f in user-data.txt cloud-config.txt; do
                  [[ -f "$d$f" ]] && sed -i "s/$esc/[REDACTED]/g" "$d$f" 2>/dev/null || true
              done
          done
      done
      journalctl --rotate 2>/dev/null || true
      journalctl --vacuum-time=1s 2>/dev/null || true

      rm -f "$ARCHIVE"
      echo "[+] BRC4 bootstrap complete at $(date -u +%FT%TZ)"

  # ---- Filebeat → RedELK shipper (per-student tag) ---------------------
  # Only used when ${redelk_ip} is non-empty (RedELK is in the scenario's
  # shared_infrastructure). Plain-text Logstash :5044 — operator can swap
  # in TLS certs from RedELK's initial-setup.sh post-deploy.
  #
  # BRC4 writes its own application logs (operator activity, beacons,
  # listener events) to /opt/bruteratel/logs/, NOT /var/log. We harvest
  # those plus the bootstrap/activation transcripts so RedELK gets both
  # the C2 operator log and the deployment audit trail.
  - path: /etc/filebeat/filebeat.yml.tmpl
    permissions: "0640"
    content: |
      filebeat.inputs:
        # BRC4 writes its own logs to /opt/bruteratel/logs/ after
        # activation. Per upstream doc the four log categories are:
        #
        #   1. Watchlist  (logs/watchlist.log)               — main
        #                 server / Commander event log
        #   2. Upload/Download (logs/{upload,download,sockets}.log)
        #                 — file-transfer + sockets/pivot events
        #   3. Badger     (logs/MM-DD-YYYY/b-N.log)          — per-badger
        #                 session, rotated daily at 00:00
        #   4. DeAuth/Web (logs/MM-DD-YYYY/{web,deauth}.log) — listener
        #                 + unauthenticated checkins
        #
        # Two structural shapes:
        #   INTERACTIVE = watchlist + per-badger.  Each operator
        #     command produces:
        #       <ts> IST [input] admin => <command>
        #       <ts> IST [sent N bytes]
        #       <multi-line response body>
        #     Multiline anchored on `[input]` merges all lines until
        #     the next `[input]` into one event, which Logstash groks
        #     into `input` and `output` fields.
        #   EVENT = upload/download/sockets/web/deauth.  Status events
        #     with no command/response pairing — multiline anchored on
        #     the timestamp prefix gives one event per logged action.
        #
        # Four inputs total. Defensive 2000-line cap on each so a
        # runaway response can't block the spooler.

        # ---- INTERACTIVE: watchlist (top-level) --------------------
        - type: log
          enabled: true
          paths:
            - /opt/bruteratel/logs/watchlist.log
          multiline.type: pattern
          multiline.pattern: '^\d{4}/\d{2}/\d{2}\s\d{2}:\d{2}:\d{2}\s+\S+\s+\[input\]'
          multiline.negate: true
          multiline.match: after
          multiline.timeout: 5s
          multiline.max_lines: 5000
          fields:
            infra: c2
            infralog: c2log
            c2_program: brc4
            c2_server: brc4-${student_id}
            brc4_log_category: state
            brc4_log_type: watchlist
          fields_under_root: true
          tags: ["c2", "brc4", "brc4-state", "brc4-interactive"]

        # ---- INTERACTIVE: per-badger session (b-N.log) --------------
        - type: log
          enabled: true
          paths:
            - /opt/bruteratel/logs/*/b-*.log
          multiline.type: pattern
          multiline.pattern: '^\d{4}/\d{2}/\d{2}\s\d{2}:\d{2}:\d{2}\s+\S+\s+\[input\]'
          multiline.negate: true
          multiline.match: after
          multiline.timeout: 5s
          multiline.max_lines: 5000
          fields:
            infra: c2
            infralog: c2log
            c2_program: brc4
            c2_server: brc4-${student_id}
            brc4_log_category: session
          fields_under_root: true
          tags: ["c2", "brc4", "brc4-session", "brc4-interactive"]
          processors:
            - dissect:
                tokenizer: "/opt/bruteratel/logs/%{brc4_log_date}/%{brc4_log_basename}.log"
                field: "log.file.path"
                target_prefix: ""
                ignore_failure: true

        # ---- EVENT: upload / download / sockets (top-level) ---------
        - type: log
          enabled: true
          paths:
            - /opt/bruteratel/logs/upload.log
            - /opt/bruteratel/logs/download.log
            - /opt/bruteratel/logs/sockets.log
          multiline.type: pattern
          multiline.pattern: '^\d{4}/\d{2}/\d{2}\s\d{2}:\d{2}:\d{2}'
          multiline.negate: true
          multiline.match: after
          multiline.timeout: 5s
          multiline.max_lines: 5000
          fields:
            infra: c2
            infralog: c2log
            c2_program: brc4
            c2_server: brc4-${student_id}
            brc4_log_category: state
          fields_under_root: true
          tags: ["c2", "brc4", "brc4-state"]
          processors:
            - dissect:
                tokenizer: "/opt/bruteratel/logs/%{brc4_log_type}.log"
                field: "log.file.path"
                target_prefix: ""
                ignore_failure: true

        # ---- EVENT: per-day web + deauth listener logs --------------
        - type: log
          enabled: true
          paths:
            - /opt/bruteratel/logs/*/web.log
            - /opt/bruteratel/logs/*/deauth.log
          multiline.type: pattern
          multiline.pattern: '^\d{4}/\d{2}/\d{2}\s\d{2}:\d{2}:\d{2}'
          multiline.negate: true
          multiline.match: after
          multiline.timeout: 5s
          multiline.max_lines: 5000
          fields:
            infra: c2
            infralog: c2log
            c2_program: brc4
            c2_server: brc4-${student_id}
            brc4_log_category: session
          fields_under_root: true
          tags: ["c2", "brc4", "brc4-session"]
          processors:
            - dissect:
                tokenizer: "/opt/bruteratel/logs/%{brc4_log_date}/%{brc4_log_basename}.log"
                field: "log.file.path"
                target_prefix: ""
                ignore_failure: true
        # Bootstrap / activation / runtime stdout — useful for
        # range-side debugging. Tagged separately so RedELK doesn't
        # confuse them with operator activity.
        # /var/log/brc4.log = systemd-captured stdout/stderr of the
        # brute-ratel-linx64 process itself (crash dumps, panics, etc.)
        - type: log
          enabled: true
          paths:
            - /var/log/brc4.log
            - /var/log/brc4-bootstrap.log
            - /var/log/brc4-activate.log
            - /var/log/brc4-serve.log
          fields:
            infra: c2
            infralog: c2bootstrap
            c2_program: brc4
            c2_server: brc4-${student_id}
          fields_under_root: true
          tags: ["c2", "brc4", "bootstrap"]
      output.logstash:
        hosts: ["__REDELK_IP__:5044"]
        ssl.enabled: false

runcmd:
  # ---- 0. Belt-and-suspenders: ensure ranger has the operator SSH key.
  #         cloud-init's `users:` block above SHOULD plant
  #         ssh_authorized_keys for this user, but we've seen
  #         non-deterministic cloud-init failures where users_groups
  #         creates the user without the keys taking effect on other
  #         C2 VMs (sliver + mythic in May 2026). Adding the same
  #         defense here for symmetry — BRC4 hasn't shown the bug yet
  #         but uses the identical userdata pattern, so it could.
  #
  #         APPEND-ONLY (grep-then-append). Doesn't overwrite existing
  #         entries, doesn't race users_groups, no-op once the key is
  #         in place.
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
  - hostnamectl set-hostname brc4-${student_id}
  - sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
  - systemctl restart ssh
  - bash /opt/brc4/bootstrap.sh

  # Filebeat → RedELK (skip when RedELK is absent from the scenario).
  # Filebeat is forced to run as root via a systemd drop-in so it can
  # read /opt/bruteratel/logs/ — BRC4 creates those as root and may
  # leave them mode 0600.
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
      echo "[+] Filebeat (as root) shipping BRC4 logs to RedELK at ${redelk_ip}:5044"
    else
      echo "[i] RedELK not in scenario; Filebeat skipped"
    fi

  - |
    cat >/etc/motd <<EOM
    ============================================================
      Brute Ratel C4 — Operator Teamserver (student ${student_id})
      Commander port  : :9000 (Kali only via NSG)
      HTTPS listeners : :8443 azure / :8444 cloudfront
                        :8445 workers / :8446 fastly / :8447 other
      Profile         : /opt/bruteratel/autosave.profile
      Logs            : /var/log/brc4.log
      RedELK shipper  : systemctl status filebeat
      See BRC4-NOTES.md for license + tuning details.
    ============================================================
    EOM
