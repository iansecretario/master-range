#cloud-config
package_update: true
package_upgrade: false
packages:
  - docker.io
  - docker-compose-v2
  - python3
  - python3-pip
  - jq
  - curl
  - certbot
  # Guacamole doubles as the Ansible controller for `./range repair`.
  # rsync is used by the operator's machine to push the playbook +
  # rendered inventory here; ansible-core is what actually drives the
  # teamservers / redirectors over their private IPs (intra-VNet).
  - ansible-core
  - rsync

# Authorize the operator SSH key on the guacadmin user so Ansible can
# reach this VM the same way it reaches the C2 boxes (key auth, no
# password juggling). guacadmin already gets NOPASSWD sudo from the
# azurerm_linux_virtual_machine resource's default sudoer config.
users:
  - name: guacadmin
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: false
    shell: /bin/bash
    ssh_authorized_keys:
      - ${ssh_pubkey}

write_files:
  - path: /opt/guac/docker-compose.yml
    permissions: "0644"
    content: |
      services:
        postgres:
          image: postgres:15-alpine
          restart: unless-stopped
          environment:
            POSTGRES_DB: guacamole_db
            POSTGRES_USER: guacamole_user
            POSTGRES_PASSWORD: guac_db_pw_change_me
          volumes:
            - pgdata:/var/lib/postgresql/data
            - ./initdb.sql:/docker-entrypoint-initdb.d/initdb.sql:ro

        guacd:
          image: guacamole/guacd:1.5.5
          restart: unless-stopped

        guacamole:
          image: guacamole/guacamole:1.5.5
          restart: unless-stopped
          depends_on: [guacd, postgres]
          environment:
            GUACD_HOSTNAME: guacd
            POSTGRES_HOSTNAME: postgres
            POSTGRES_DATABASE: guacamole_db
            POSTGRES_USER: guacamole_user
            POSTGRES_PASSWORD: guac_db_pw_change_me
          ports:
            - "8080:8080"

        nginx:
          image: nginx:alpine
          restart: unless-stopped
          depends_on: [guacamole]
          ports:
            - "80:80"
            - "443:443"
          volumes:
            - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
            - ./tls:/etc/nginx/tls:ro
            # Mount Let's Encrypt live dir so nginx sees rotated certs
            # without needing a container restart on renewal.
            - /etc/letsencrypt:/etc/letsencrypt:ro
            # ACME HTTP-01 webroot — certbot writes challenges here, nginx
            # serves them at /.well-known/acme-challenge/*
            - /var/www/acme:/var/www/acme:ro

      volumes:
        pgdata:

  - path: /opt/guac/nginx.conf
    permissions: "0644"
    content: |
      # WebSocket upgrade map. Required for Guacamole's HTML5 tunnel:
      # the browser sends `Connection: Upgrade` for the WS handshake,
      # but for non-WS requests it sends `Connection: keep-alive`.
      # Echoing $http_connection directly back to upstream (the old
      # config did this) leaks "keep-alive" into the WS handshake and
      # makes Guacamole's Tomcat reject the upgrade; the client falls
      # back to HTTP-polling tunnel, which then times out at 60s and
      # surfaces as a generic ERROR page after ~1 min of idle. The
      # `map` below sets Connection: "upgrade" only when the request
      # had Upgrade: websocket, else "close".
      map $http_upgrade $connection_upgrade {
          default upgrade;
          ''      close;
      }

      # Port 80: serve ACME challenges + redirect everything else to HTTPS.
      server {
        listen 80;
        server_name _;
        # certbot --webroot writes challenge files here; LE fetches over :80
        location /.well-known/acme-challenge/ {
          root /var/www/acme;
          default_type "text/plain";
        }
        location / {
          return 301 https://$host$request_uri;
        }
      }

      server {
        listen 443 ssl;
        http2 on;
        server_name _;
        ssl_certificate     /etc/nginx/tls/cert.pem;
        ssl_certificate_key /etc/nginx/tls/key.pem;
        ssl_protocols       TLSv1.2 TLSv1.3;
        client_max_body_size 1g;
        location / {
          proxy_pass http://guacamole:8080/guacamole/;
          proxy_buffering off;
          proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
          proxy_set_header X-Forwarded-Proto $scheme;
          proxy_set_header Host $host;
          proxy_http_version 1.1;
          # WS upgrade: route to the connection_upgrade map (see above).
          proxy_set_header Upgrade $http_upgrade;
          proxy_set_header Connection $connection_upgrade;
          # Long-lived RDP/SSH sessions ride the same TCP socket as the
          # WS upgrade. Default proxy_read_timeout is 60s, which kills
          # any session that's quiet for a minute (e.g. operator alt-
          # tabs away). Bump to 24h to align with Guacamole's own
          # session-management.
          proxy_read_timeout 86400s;
          proxy_send_timeout 86400s;
          access_log off;
        }
      }

  - path: /opt/guac/letsencrypt-bootstrap.sh
    permissions: "0755"
    content: |
      #!/usr/bin/env bash
      # First-boot Let's Encrypt setup. Runs in webroot mode against the
      # nginx container that's already serving port 80 + the ACME webroot
      # volume. Symlinks LE's fullchain.pem/privkey.pem into the TLS
      # directory nginx is configured to read, then reloads nginx.
      #
      # NOT using `set -e`: a couple of probe commands below intentionally
      # return non-zero (curl -sf against /acme-challenge/test gets a
      # 404 — the GOOD signal that nginx routing is correct). With -e
      # the script would abort there and never reach certbot. We rely
      # on explicit `|| { ... exit 0; }` guards instead.
      set -uo pipefail
      FQDN="${guac_fqdn}"
      EMAIL_RAW="${guac_acme_email}"
      # Wildcard plumbing — set when services.guacamole.dns_zone_name
      # is configured. Empty values disable wildcard mode and fall
      # back to per-FQDN HTTP-01 issuance.
      WILDCARD_ZONE="${guac_wildcard_zone}"
      WILDCARD_ZONE_RG="${guac_wildcard_zone_rg}"
      WILDCARD_ZONE_SUB="${guac_wildcard_zone_sub}"
      # Key Vault for cert caching. cloud-init pulls existing valid
      # cert from here first (skipping LE issuance entirely), and
      # pushes new certs after every issue/renew so future deploys
      # can reuse them.
      KV_NAME="${guac_kv_name}"
      LOG=/var/log/guacamole-letsencrypt.log
      exec >>"$LOG" 2>&1
      echo "[$(date)] LE bootstrap for $FQDN (KV=$KV_NAME)"

      # Helper: install Azure CLI if missing (needed for KV ops).
      ensure_az() {
        command -v az >/dev/null && return
        echo "  installing azure-cli..."
        curl -sL https://aka.ms/InstallAzureCLIDeb | bash >> "$LOG" 2>&1
      }

      # Helper: log into Azure using the VM's managed identity. The
      # bootstrap script and the renewal service both call this.
      az_login_msi() {
        # Wait for IMDS — managed identity takes ~30s on first boot.
        for i in $(seq 1 20); do
          curl -sf -H "Metadata:true" -m 3 \
            "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://management.azure.com/" \
            > /dev/null 2>&1 && break
          sleep 3
        done
        az login --identity --allow-no-subscriptions >> "$LOG" 2>&1 || \
          { echo "az login --identity failed; cert caching will be skipped"; return 1; }
      }

      # Helper: copy cert files to /etc/letsencrypt/live/<zone>/ and
      # symlink into /opt/guac/tls/. Used by both KV-restore and the
      # post-issuance hook.
      install_cert() {
        local crt="$$1" key="$$2" zone="$$3"
        local dst=/etc/letsencrypt/live/$zone
        mkdir -p "$dst"
        cp -f "$crt" "$dst/fullchain.pem"
        cp -f "$key" "$dst/privkey.pem"
        chmod 644 "$dst/fullchain.pem"
        chmod 600 "$dst/privkey.pem"
        ln -sf "$dst/fullchain.pem" /opt/guac/tls/cert.pem
        ln -sf "$dst/privkey.pem"   /opt/guac/tls/key.pem
      }

      # Helper: push cert + key to Key Vault. Two secrets:
      # wildcard-cert (PEM fullchain) and wildcard-key (PEM key).
      # Each upload is a NEW version; old versions retained for rollback.
      push_to_kv() {
        local crt="$$1" key="$$2"
        [ -z "$KV_NAME" ] && return 0
        echo "  pushing cert + key to Key Vault $KV_NAME..."
        az keyvault secret set --vault-name "$KV_NAME" \
          --name wildcard-cert --file "$crt" --encoding utf-8 \
          --content-type "application/x-pem-file" >> "$LOG" 2>&1 \
          && echo "    wildcard-cert OK" \
          || echo "    wildcard-cert FAILED"
        az keyvault secret set --vault-name "$KV_NAME" \
          --name wildcard-key --file "$key" --encoding utf-8 \
          --content-type "application/x-pem-file" >> "$LOG" 2>&1 \
          && echo "    wildcard-key OK" \
          || echo "    wildcard-key FAILED"
      }

      # Helper: try to restore cert from KV. Sets RESTORED=1 on success.
      # Skips if KV unset, az login failed, or secrets missing.
      try_restore_from_kv() {
        RESTORED=0
        [ -z "$KV_NAME" ] && return 0
        ensure_az
        az_login_msi || return 0
        local tmp=$(mktemp -d)
        if az keyvault secret show --vault-name "$KV_NAME" --name wildcard-cert \
             --query value -o tsv > "$tmp/cert.pem" 2>>"$LOG" && [ -s "$tmp/cert.pem" ]; then
          if az keyvault secret show --vault-name "$KV_NAME" --name wildcard-key \
               --query value -o tsv > "$tmp/key.pem" 2>>"$LOG" && [ -s "$tmp/key.pem" ]; then
            # Validate the cert: parse expiry, refuse if <30 days valid.
            local exp days
            exp=$(openssl x509 -in "$tmp/cert.pem" -noout -enddate 2>/dev/null | cut -d= -f2)
            if [ -n "$exp" ]; then
              days=$(( ( $(date -d "$exp" +%s) - $(date +%s) ) / 86400 ))
              echo "  KV cert expires in $days days"
              if [ "$days" -gt 30 ]; then
                local zone=$(openssl x509 -in "$tmp/cert.pem" -noout -subject 2>/dev/null | sed -n 's/.*CN *= *//p' | cut -d, -f1)
                [ -z "$zone" ] && zone="$WILDCARD_ZONE"
                install_cert "$tmp/cert.pem" "$tmp/key.pem" "$zone"
                RESTORED=1
                echo "  restored cert from KV (CN=$zone)"
              else
                echo "  KV cert expires too soon, will reissue via lego"
              fi
            fi
          fi
        fi
        rm -rf "$tmp"
      }

      [ -z "$FQDN" ] && { echo "guac_fqdn empty — keeping self-signed cert"; exit 0; }

      # Let's Encrypt rejects emails on RFC2606-reserved domains
      # (example.com / .test / .invalid / localhost) at account-
      # registration time:
      #   "contact email has forbidden domain example.com"
      # When the operator left the placeholder default in place, fall
      # back to admin@<FQDN> (Azure's cloudapp.azure.com is a real
      # registered TLD that LE accepts even without an MX record).
      EMAIL_DOMAIN="$${EMAIL_RAW##*@}"
      case "$(echo "$EMAIL_DOMAIN" | tr '[:upper:]' '[:lower:]')" in
        example.com|example.org|example.net|test|invalid|localhost|"")
          EMAIL="admin@$FQDN"
          echo "  email $EMAIL_RAW is reserved/empty — falling back to $EMAIL"
          ;;
        *)
          EMAIL="$EMAIL_RAW"
          ;;
      esac

      mkdir -p /var/www/acme

      # Wait for DNS to resolve $FQDN to a public IP (the A record is
      # created by terraform but propagation through public resolvers
      # can take 2-10 min after first apply).
      for i in $(seq 1 60); do
        ip=$(getent ahosts "$FQDN" | awk '{print $1; exit}' || true)
        [ -n "$ip" ] && { echo "$FQDN resolves to $ip"; break; }
        echo "  waiting for DNS ($i/60)..."; sleep 15
      done
      if [ -z "$${ip:-}" ]; then
        echo "DNS for $FQDN did not resolve after 15 min — keeping self-signed"
        exit 0
      fi

      # Pick the issuance strategy.
      #   - WILDCARD_ZONE set → DNS-01 wildcard via `lego` (Go-based
      #     ACME client, Azure DNS plugin built in, MSI-aware). Cert
      #     covers `<zone>` + `*.<zone>`, so every Guacamole +
      #     Mythic + Adaptix + etc. under that zone is covered by one
      #     cert. We tried `certbot-dns-azure` first but it has
      #     unresolvable dep conflicts on Debian 12 (cryptography>=42
      #     dropped X509Extension; azure-mgmt-dns SDK signature drift).
      #     lego is a single static binary, no Python.
      #   - WILDCARD_ZONE empty → fall back to HTTP-01 per-FQDN
      #     (legacy path; covers a single hostname).
      if [ -n "$WILDCARD_ZONE" ]; then
        echo "[$(date)] wildcard mode for *.$WILDCARD_ZONE"

        # First, try to restore an existing cert from Key Vault. If
        # successful, skip lego entirely — saves 30-60s of issuance
        # time AND avoids burning an LE issuance against the rate
        # limit. The restore helper validates the cert has >30 days
        # of validity before accepting it.
        try_restore_from_kv
        if [ "$RESTORED" = "1" ]; then
          LIVE_DIR=/etc/letsencrypt/live/$WILDCARD_ZONE
          (cd /opt/guac && docker compose restart nginx) >> "$LOG" 2>&1 || true
          echo "[$(date)] LE bootstrap done (KV-restored); cert active at https://$FQDN"
          exit 0
        fi

        # No usable cert in KV — issue fresh via lego.
        echo "  no usable KV cert; issuing fresh via lego"

        # Install lego if absent. Pinned to v4.18.0 — newer than the
        # cosmetic-only changes wouldn't help.
        if ! [ -x /opt/guac/lego ]; then
          ARCH=$(uname -m); LEGO_ARCH=amd64
          [ "$ARCH" = "aarch64" ] && LEGO_ARCH=arm64
          TMP=$(mktemp -d); cd "$TMP"
          curl -sL -o lego.tgz \
            "https://github.com/go-acme/lego/releases/download/v4.18.0/lego_v4.18.0_linux_$${LEGO_ARCH}.tar.gz"
          tar -xzf lego.tgz lego
          mv lego /opt/guac/lego
          chmod +x /opt/guac/lego
          cd / && rm -rf "$TMP"
        fi

        # lego's Azure DNS plugin reads config via env vars. MSI flow:
        # set AZURE_AUTH_METHOD=msi and lego auto-detects via IMDS.
        export AZURE_SUBSCRIPTION_ID="$WILDCARD_ZONE_SUB"
        export AZURE_RESOURCE_GROUP="$WILDCARD_ZONE_RG"
        export AZURE_ZONE_NAME="$WILDCARD_ZONE"
        export AZURE_AUTH_METHOD=msi

        # Wait for Azure IMDS — managed identity takes ~30s to be
        # consumable after VM creation. Probe the metadata endpoint.
        for i in $(seq 1 20); do
          curl -sf -H "Metadata:true" -m 3 \
            "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://management.azure.com/" \
            > /dev/null 2>&1 && break
          sleep 3
        done

        mkdir -p /opt/guac/lego-data
        if /opt/guac/lego \
          --accept-tos \
          --email "$EMAIL" \
          --dns azuredns \
          --domains "$WILDCARD_ZONE" \
          --domains "*.$WILDCARD_ZONE" \
          --path /opt/guac/lego-data \
          --key-type rsa2048 \
          run; then

          # nginx-guac mounts /etc/letsencrypt:/etc/letsencrypt:ro but
          # NOT /opt/guac/lego-data, so we mirror lego's output into the
          # already-mounted LE tree. Keeps the nginx config unchanged.
          LIVE_DIR=/etc/letsencrypt/live/$WILDCARD_ZONE
          mkdir -p "$LIVE_DIR"
          cp -f /opt/guac/lego-data/certificates/$WILDCARD_ZONE.crt "$LIVE_DIR/fullchain.pem"
          cp -f /opt/guac/lego-data/certificates/$WILDCARD_ZONE.key "$LIVE_DIR/privkey.pem"
          chmod 644 "$LIVE_DIR/fullchain.pem"
          chmod 600 "$LIVE_DIR/privkey.pem"

          # Push freshly-issued cert to Key Vault so future deploys can
          # reuse it (LE rate-limit safe). az was set up by the earlier
          # try_restore_from_kv call; if it failed, push_to_kv no-ops.
          push_to_kv "$LIVE_DIR/fullchain.pem" "$LIVE_DIR/privkey.pem"
        else
          # lego DNS-01 failed (most commonly: MSI lacks the magical
          # combination of Resource Graph Reader + DNS Zone Contributor
          # + whatever else Azure is silently enforcing on the zone).
          # Fall back to HTTP-01 against the specific FQDN — that gives
          # us a valid LE cert covering the live hostname even when the
          # wildcard pipeline is blocked. Caveat: this cert only covers
          # `$FQDN`, not `*.$WILDCARD_ZONE`, so sibling subdomains
          # (mythic-redir etc.) need their own issuance later.
          echo "lego DNS-01 wildcard failed — falling back to HTTP-01 for $FQDN"
          for i in $(seq 1 30); do
            ss -tnlp 2>/dev/null | grep -q ':80 ' && break
            sleep 5
          done
          certbot certonly --webroot -w /var/www/acme \
            --non-interactive --agree-tos \
            --email "$EMAIL" \
            -d "$FQDN" \
            --rsa-key-size 2048 \
            --keep-until-expiring \
            || { echo "HTTP-01 fallback also failed — keeping self-signed"; exit 0; }
          LIVE_DIR=/etc/letsencrypt/live/$FQDN
          push_to_kv "$LIVE_DIR/fullchain.pem" "$LIVE_DIR/privkey.pem"
        fi
      else
        # ---- Legacy HTTP-01 per-FQDN issuance ----
        # Wait for nginx container to be serving port 80 (so webroot
        # works). ss is the authoritative signal that the listener is
        # bound; the curl is just a hint to wake DNS up. Neither
        # result aborts the script.
        for i in $(seq 1 30); do
          curl -sf -o /dev/null "http://127.0.0.1/.well-known/acme-challenge/test" 2>/dev/null || true
          ss -tnlp 2>/dev/null | grep -q ':80 ' && break
          sleep 5
        done

        certbot certonly --webroot -w /var/www/acme \
          --non-interactive --agree-tos \
          --email "$EMAIL" \
          -d "$FQDN" \
          --rsa-key-size 2048 \
          --keep-until-expiring \
          || { echo "certbot HTTP-01 failed — keeping self-signed (ansible repair pass will retry)"; exit 0; }

        LIVE_DIR=/etc/letsencrypt/live/$FQDN
      fi

      # Swap nginx's TLS dir to the LE cert (symlinks survive rotation).
      ln -sf "$LIVE_DIR/fullchain.pem" /opt/guac/tls/cert.pem
      ln -sf "$LIVE_DIR/privkey.pem"   /opt/guac/tls/key.pem
      (cd /opt/guac && docker compose restart nginx) || true
      echo "[$(date)] LE bootstrap done; cert active at https://$FQDN (cert covers $LIVE_DIR)"

  - path: /etc/systemd/system/guacamole-cert-renew.service
    permissions: "0644"
    content: |
      [Unit]
      Description=Renew Guacamole Let's Encrypt cert
      After=docker.service
      Requires=docker.service

      [Service]
      Type=oneshot
      # Renew via whichever client originally issued the cert:
      #   - lego (DNS-01 wildcard) if /opt/guac/lego exists. lego's
      #     `renew --days 30` only re-issues when <30 days remain;
      #     otherwise it's a no-op. After successful renew, mirror
      #     into the nginx-mounted LE path, push to Key Vault, and
      #     bounce nginx.
      #   - certbot (HTTP-01 per-FQDN) otherwise — legacy path.
      ExecStart=/usr/local/sbin/guac-cert-renew.sh

  - path: /usr/local/sbin/guac-cert-renew.sh
    permissions: "0755"
    content: |
      #!/usr/bin/env bash
      # Daily renewal job — fired by guacamole-cert-renew.timer.
      # lego's `renew --days 30` is idempotent; only re-issues when
      # the cert has <30 days remaining. On success: mirror new cert
      # into /etc/letsencrypt/live/<zone>/, push to Key Vault for
      # next-deploy reuse, bounce nginx-guac.
      set -uo pipefail
      LOG=/var/log/guacamole-letsencrypt.log
      exec >>"$LOG" 2>&1

      KV_NAME="${guac_kv_name}"

      if [ -x /opt/guac/lego ] && [ -d /opt/guac/lego-data ]; then
        export AZURE_AUTH_METHOD=msi
        export AZURE_SUBSCRIPTION_ID="${guac_wildcard_zone_sub}"
        export AZURE_RESOURCE_GROUP="${guac_wildcard_zone_rg}"
        export AZURE_ZONE_NAME="${guac_wildcard_zone}"
        ZONE=$(ls /opt/guac/lego-data/certificates/*.crt 2>/dev/null | head -1 | xargs -I{} basename {} .crt)
        [ -z "$ZONE" ] && { echo "[$(date)] renew: no lego-issued cert found, skipping"; exit 0; }
        # Pull issuance email from lego's account JSON if available;
        # fall back to a placeholder so --accept-tos doesn't choke.
        EMAIL=$(grep -hoE '"[^"]+@[^"]+"' /opt/guac/lego-data/accounts/*/*/account.json 2>/dev/null | head -1 | tr -d '"')
        [ -z "$EMAIL" ] && EMAIL=admin@$ZONE
        BEFORE=$(sha256sum /opt/guac/lego-data/certificates/$ZONE.crt 2>/dev/null | awk '{print $$1}')
        /opt/guac/lego --accept-tos --email "$EMAIL" \
          --dns azuredns --domains "$ZONE" --domains "*.$ZONE" \
          --path /opt/guac/lego-data --key-type rsa2048 \
          renew --days 30 >> "$LOG" 2>&1 || \
          { echo "[$(date)] renew: lego failed"; exit 1; }
        AFTER=$(sha256sum /opt/guac/lego-data/certificates/$ZONE.crt 2>/dev/null | awk '{print $$1}')
        if [ "$BEFORE" != "$AFTER" ]; then
          echo "[$(date)] renew: cert refreshed; mirroring + pushing to KV"
          cp -f /opt/guac/lego-data/certificates/$ZONE.crt /etc/letsencrypt/live/$ZONE/fullchain.pem
          cp -f /opt/guac/lego-data/certificates/$ZONE.key /etc/letsencrypt/live/$ZONE/privkey.pem
          if [ -n "$KV_NAME" ] && command -v az >/dev/null; then
            az login --identity --allow-no-subscriptions >> "$LOG" 2>&1 || true
            az keyvault secret set --vault-name "$KV_NAME" --name wildcard-cert \
              --file /etc/letsencrypt/live/$ZONE/fullchain.pem --encoding utf-8 \
              --content-type application/x-pem-file >> "$LOG" 2>&1 || true
            az keyvault secret set --vault-name "$KV_NAME" --name wildcard-key \
              --file /etc/letsencrypt/live/$ZONE/privkey.pem --encoding utf-8 \
              --content-type application/x-pem-file >> "$LOG" 2>&1 || true
          fi
          /usr/bin/docker compose -f /opt/guac/docker-compose.yml restart nginx
        else
          echo "[$(date)] renew: cert still valid >30d, nothing to do"
        fi
      else
        # Legacy HTTP-01 fallback.
        /usr/bin/certbot renew --quiet --webroot -w /var/www/acme \
          --deploy-hook "/usr/bin/docker compose -f /opt/guac/docker-compose.yml restart nginx"
      fi

  - path: /etc/systemd/system/guacamole-cert-renew.timer
    permissions: "0644"
    content: |
      [Unit]
      Description=Run guacamole-cert-renew daily

      [Timer]
      OnCalendar=daily
      RandomizedDelaySec=2h
      Persistent=true

      [Install]
      WantedBy=timers.target

  - path: /opt/guac/manifest.b64
    permissions: "0600"
    content: ${manifest_b64}

  - path: /opt/guac/register.py
    permissions: "0755"
    # ----------------------------------------------------------------
    # SYNC NOTE: this inline copy of register.py is the FIRST-BOOT
    # bootstrap only. After first boot, every `./range repair` run
    # OVERWRITES /opt/guac/register.py from the canonical version at:
    #   modules/azure/ansible/roles/guacamole/files/register.py
    # When you edit the registration logic (RDP/VNC params, REST API
    # calls, connection-group structure, etc.) update BOTH files —
    # otherwise a fresh deploy first-boots with the old logic until
    # the operator runs `./range repair`, which can confuse anyone
    # debugging the live Guac DB between deploy and first repair.
    # ----------------------------------------------------------------
    content: |
      #!/usr/bin/env python3
      """
      register.py — consumes /opt/guac/manifest.json and calls the
      Guacamole REST API to create:
        - one connection group per student
        - one connection per machine, prefilled with creds
        - one user per student, granted READ on only their group
      Idempotent: re-running won't create duplicates (looks up by name).
      """
      import json, sys, time, urllib.parse, urllib.request, urllib.error

      BASE = "http://localhost:8080/guacamole"

      def req(method, path, token=None, payload=None):
          url = f"{BASE}{path}"
          if token:
              url += ("&" if "?" in url else "?") + "token=" + token
          data = json.dumps(payload).encode() if payload is not None else None
          headers = {"Content-Type": "application/json"} if data else {}
          r = urllib.request.Request(url, data=data, method=method, headers=headers)
          try:
              with urllib.request.urlopen(r, timeout=15) as resp:
                  body = resp.read().decode() or "{}"
                  return resp.status, json.loads(body) if body.strip().startswith(("{", "[")) else body
          except urllib.error.HTTPError as e:
              return e.code, e.read().decode()

      def login(user, pw, max_tries=10):
          # form-encoded
          url = f"{BASE}/api/tokens"
          data = urllib.parse.urlencode({"username": user, "password": pw}).encode()
          for _ in range(max_tries):
              try:
                  r = urllib.request.Request(url, data=data, method="POST")
                  with urllib.request.urlopen(r, timeout=10) as resp:
                      return json.loads(resp.read().decode())["authToken"]
              except (urllib.error.URLError, urllib.error.HTTPError):
                  time.sleep(5)
          return None

      def main():
          m = json.load(open("/opt/guac/manifest.json"))
          admin_user = m["admin"]["username"]
          admin_pw   = m["admin"]["password"]

          # Wait for the API to be reachable at all (long retry).
          for _ in range(60):
              try:
                  urllib.request.urlopen(f"{BASE}/", timeout=5).read()
                  break
              except Exception:
                  time.sleep(5)

          # Try configured admin password first (re-runs are idempotent).
          token = login(admin_user, admin_pw, max_tries=3)
          if token is None:
              # First run path: rotate from default guacadmin/guacadmin.
              token = login("guacadmin", "guacadmin", max_tries=12)
              if token is None:
                  raise SystemExit("guacamole api never came up with default creds")
              # Rotate the default password to the configured one.
              req("PUT",
                  "/api/session/data/postgresql/users/guacadmin/password",
                  token=token,
                  payload={"oldPassword": "guacadmin",
                           "newPassword": admin_pw})
              token = login(admin_user, admin_pw, max_tries=12)
              if token is None:
                  raise SystemExit("guacadmin password rotation failed")

          # Create per-student connection groups.
          # Map student_id -> group identifier returned by API.
          group_ids = {}
          # Existing groups
          status, existing = req("GET", "/api/session/data/postgresql/connectionGroups",
                                 token=token)
          name_to_id = {v["name"]: k for k, v in (existing or {}).items()} \
                       if isinstance(existing, dict) else {}

          students = sorted({c["student_id"] for c in m["connections"] if c["student_id"]})
          if not students:
              students = [""]   # single-student mode
          for sid in students:
              gname = sid if sid else "range"
              if gname in name_to_id:
                  group_ids[sid] = name_to_id[gname]
                  continue
              status, body = req("POST", "/api/session/data/postgresql/connectionGroups",
                                 token=token,
                                 payload={
                                   "parentIdentifier": "ROOT",
                                   "name": gname,
                                   "type": "ORGANIZATIONAL",
                                   "attributes": {}
                                 })
              if isinstance(body, dict) and "identifier" in body:
                  group_ids[sid] = body["identifier"]

          # Create connections.
          status, existing_conns = req("GET",
                                       "/api/session/data/postgresql/connections",
                                       token=token)
          conn_name_to_id = {v["name"]: k for k, v in (existing_conns or {}).items()} \
                            if isinstance(existing_conns, dict) else {}
          created_conns = []
          for c in m["connections"]:
              params = {
                "hostname": c["hostname"],
                "port":     str(c["port"]),
                "username": c["username"],
                "password": c["password"],
              }
              # VNC connections need ONLY hostname/port/password — no
              # username, no security-mode params. Guacamole's VNC plugin
              # accepts username (harmless) but some VNC servers reject it.
              # TigerVNC ignores it cleanly so we leave the field in.
              # The password matches the VNC password we set in the kali
              # ansible role (vncpasswd -f → ~/.config/tigervnc/passwd).
              if c["protocol"] == "vnc":
                  params["color-depth"]    = "24"
                  params["autoretry"]      = "3"
                  # force-lossless: ship updates as PNG, not JPEG.
                  # JPEG compression smears anti-aliased glyph edges,
                  # making terminal/editor text look "blurry" at any
                  # framebuffer size that isn't exactly the operator's
                  # viewport. PNG is lossless — text edges stay crisp
                  # at the cost of ~30-40% more bytes per dirty region.
                  # Worth it for a Kali desktop where 80% of pixel
                  # changes are text-heavy.
                  params["force-lossless"] = "true"
                  # cursor=remote: render the server's actual cursor
                  # rather than overlaying a generic client cursor.
                  # XFCE's cursor has subpixel hinting that survives
                  # network transit cleanly; the default local cursor
                  # in Guacamole sometimes desyncs from the framebuffer
                  # during quick window switches.
                  params["cursor"]         = "remote"
                  # Per-connection overrides — services.tf can pass
                  # additional VNC params (e.g. width/height hints)
                  # through manifest entry's optional `_extra_vnc_params`
                  # subobject without forking this register.py.
                  for _k, _v in (c.get("_extra_vnc_params") or {}).items():
                      params[_k] = _v
              # Optional SFTP file-transfer overlay. Guacamole's VNC
              # protocol has no native file transfer; this enables a
              # sidebar that uploads/downloads via SSH to the same host
              # (or any other host the operator points to). Triggered
              # by an `sftp` subobject on the manifest connection entry —
              # see services.tf where Kali entries get one filled in.
              # Works for vnc + ssh + rdp protocols alike.
              if c.get("sftp") and c["sftp"].get("enabled"):
                  s = c["sftp"]
                  params["enable-sftp"]         = "true"
                  params["sftp-hostname"]       = s.get("hostname", c["hostname"])
                  params["sftp-port"]           = str(s.get("port", 22))
                  params["sftp-username"]       = s.get("username", "")
                  params["sftp-password"]       = s.get("password", "")
                  params["sftp-root-directory"] = s.get("root-directory", "/")
                  params["sftp-directory"]      = s.get("directory", "")
                  # Explicit upload/download flips. libguac-client-vnc
                  # defaults both to false (i.e. allowed), but setting
                  # them explicitly here guarantees an operator can:
                  #   - drag a file from their local OS onto the
                  #     Guacamole canvas → uploads via SFTP to
                  #     sftp-directory (i.e. ~/Downloads on Kali);
                  #   - open the Guacamole side panel (Ctrl+Alt+Shift)
                  #     → Devices section → file browser → download
                  #     anything under sftp-root-directory back to
                  #     their local machine.
                  # If a manifest entry explicitly sets disable-upload
                  # or disable-download to True, we honor that (some
                  # student-facing connections might want read-only).
                  params["sftp-disable-upload"]   = "true" if s.get("disable-upload", False)   else "false"
                  params["sftp-disable-download"] = "true" if s.get("disable-download", False) else "false"
              if c["protocol"] == "rdp":
                  # Security mode depends on the RDP server family:
                  #   Windows RDP  -> NLA (CredSSP)  -- the modern default
                  #   Linux xrdp   -> "any"          -- xrdp can't do NLA;
                  #                                    NLA causes
                  #                                    "libxrdp_force_read:
                  #                                    header read error"
                  #                                    in the xrdp log.
                  # We detect Linux RDP via os field (kali / any non-windows-*).
                  is_linux_rdp = not (c.get("os","") or "").startswith("windows")

                  # Drive-redirection split:
                  #   - Windows RDP   → ENABLED with a real drive-path so
                  #                     operators can drag files in/out of
                  #                     the RDP session. Mounts as a network
                  #                     drive named "Guacamole" inside the
                  #                     Windows session.
                  #   - Linux xrdp    → DISABLED. xrdp's chansrv has a bug
                  #                     where an empty drive-path triggers
                  #                     `Unable to create directory ""`,
                  #                     leaves the RDPDR channel half-up,
                  #                     and the server fires
                  #                     DisconnectProviderUltimatum 1-2s
                  #                     after a successful XFCE login.
                  #                     Linux RDP hosts get the SFTP
                  #                     overlay above instead (same UX —
                  #                     drop a file on the canvas →
                  #                     uploads via SSH).
                  #
                  # drive-path lives on the guacd container's filesystem;
                  # /tmp/guacd-drives/<connection_name>/ is a per-connection
                  # staging area Guacamole creates and the operator never
                  # sees directly (the FILES are streamed to/from the
                  # Windows session, not stored permanently on guacd).
                  rdp_params = {
                    "security":      "any" if is_linux_rdp else "nla",
                    "ignore-cert":   "true",
                    # resize-method DELIBERATELY NOT SET.
                    # Previously "display-update": every browser resize
                    # asked the Windows server to renegotiate the desktop
                    # resolution mid-session, which (a) caused the
                    # wallpaper to re-stretch every time the operator
                    # adjusted the tab and (b) added visible flicker.
                    # Omitting the parameter pins the server desktop at
                    # whatever resolution Guacamole's web client sent at
                    # connect time (the browser viewport size) — stable
                    # for the lifetime of the connection. If the operator
                    # resizes the browser later, the Guac canvas
                    # CSS-scales to fit, the server desktop never moves.
                    # No more wallpaper-rendering churn.
                    "enable-drive":       "false" if is_linux_rdp else "true",
                    "create-drive-path":  "false" if is_linux_rdp else "true",
                    "drive-path":         "" if is_linux_rdp else f"/tmp/guacd-drives/{c['name'].replace(' ', '_').replace('(', '').replace(')', '')}",
                    "drive-name":         "" if is_linux_rdp else "Guacamole",
                    "server-layout":            "en-us-qwerty",
                    # color-depth 32 = true color + alpha. Default RDP is
                    # 16-bit ("high color"), which makes the CWR
                    # wallpaper look banded/dithered (gradients turn
                    # blocky). 32-bit is the modern Windows-RDP default
                    # and what every native client (mstsc, FreeRDP) uses
                    # — no measurable bandwidth penalty after RDP's
                    # RemoteFX compression kicks in.
                    "color-depth":              "32",
                    # disable-wallpaper / disable-theming DELIBERATELY
                    # NOT SET (were "true").
                    # Those two flags ask the RDP server to send a solid
                    # color background AND suppress Aero/Fluent theme
                    # rendering as a bandwidth optimization — but they
                    # completely override the HKLM Policies\System
                    # Wallpaper that the windows-base ansible role sets.
                    # Result: operator RDPs in via Guac and sees a black
                    # void instead of the CWR branding, regardless of
                    # how clean the policy is on the server side. With
                    # both flags removed, RDP honors the Wallpaper
                    # policy normally; bandwidth cost on a 1080p canvas
                    # is ~50-100 KB on the first frame and zero
                    # thereafter (RDP only re-streams the desktop on
                    # damage).
                    "disable-full-window-drag": "true",
                    "disable-menu-animations":  "true",
                  }
                  # For domain-joined connections the username arrives as
                  # "NETBIOS\\user" — split and use the `domain` param.
                  if "\\" in c["username"]:
                      dom, user = c["username"].split("\\", 1)
                      rdp_params["domain"]   = dom
                      rdp_params["username"] = user
                      params["username"]     = user
                      params["domain"]       = dom
                  params.update(rdp_params)
              payload = {
                "parentIdentifier": group_ids.get(c["student_id"], "ROOT"),
                "name": c["name"],
                "protocol": c["protocol"],
                "parameters": params,
                "attributes": {"max-connections": "10"}
              }

              # UPSERT: if a connection with this name already exists,
              # PUT to update its parameters (refreshes stale passwords
              # from earlier runs). Otherwise POST to create. Previously
              # we skipped existing connections, which meant rotating
              # the auto-generated random_password.* values broke every
              # registered connection until the operator re-registered
              # manually.
              if c["name"] in conn_name_to_id:
                  existing_id = conn_name_to_id[c["name"]]
                  status, body = req(
                      "PUT",
                      f"/api/session/data/postgresql/connections/{existing_id}",
                      token=token, payload=payload)
                  if status in (200, 204):
                      created_conns.append((c, existing_id))
                      print(f"[update] {c['name']}")
                  else:
                      print(f"[!] update {c['name']} returned {status}: {body}")
                      created_conns.append((c, existing_id))
                  continue

              status, body = req("POST",
                                 "/api/session/data/postgresql/connections",
                                 token=token, payload=payload)
              if isinstance(body, dict) and "identifier" in body:
                  created_conns.append((c, body["identifier"]))

          # Pre-compute the shared-infra group identifier (if any).
          # Connections with student_id="shared-infra" — ELK, Ghostwriter,
          # SteppingStones, RedELK, the kali-2 ephemeral workspace pool —
          # are broadcast to EVERY per-student operator. Rationale:
          # redteam ranges are collaborative; the per-student boundary
          # exists so operators don't trample each other's domain creds,
          # but the shared services (logging, reporting, workspaces) are
          # everyone's. In single-student mode (no `students` block) the
          # admin sees everything anyway and this is a no-op.
          shared_infra_gid = group_ids.get("shared-infra")
          shared_infra_conn_ids = [
              cid for c, cid in created_conns
              if c.get("student_id") == "shared-infra"
          ]

          # Create per-student users. Each user can READ their own group only.
          for su in m.get("students", []):
              # Create user (PUT password if exists)
              req("POST", "/api/session/data/postgresql/users", token=token,
                  payload={"username": su["username"],
                           "password": su["password"], "attributes": {}})
              # Grant READ on the student's connection group.
              gid = group_ids.get(su["student_id"])
              if not gid:
                  continue
              req("PATCH",
                  f"/api/session/data/postgresql/users/{su['username']}/permissions",
                  token=token,
                  payload=[{
                      "op": "add",
                      "path": f"/connectionGroupPermissions/{gid}",
                      "value": "READ"
                  }])
              # Also grant READ on each connection in that group.
              for c, cid in created_conns:
                  if c["student_id"] != su["student_id"]:
                      continue
                  req("PATCH",
                      f"/api/session/data/postgresql/users/{su['username']}/permissions",
                      token=token,
                      payload=[{
                          "op": "add",
                          "path": f"/connectionPermissions/{cid}",
                          "value": "READ"
                      }])

              # Broadcast: also grant READ on the shared-infra group and
              # every connection inside it (ELK, Ghostwriter, RedELK,
              # SteppingStones, kali-2 ephemeral workspace pool). See
              # rationale on shared_infra_gid above.
              if shared_infra_gid:
                  req("PATCH",
                      f"/api/session/data/postgresql/users/{su['username']}/permissions",
                      token=token,
                      payload=[{
                          "op": "add",
                          "path": f"/connectionGroupPermissions/{shared_infra_gid}",
                          "value": "READ"
                      }])
              for shared_cid in shared_infra_conn_ids:
                  req("PATCH",
                      f"/api/session/data/postgresql/users/{su['username']}/permissions",
                      token=token,
                      payload=[{
                          "op": "add",
                          "path": f"/connectionPermissions/{shared_cid}",
                          "value": "READ"
                      }])

          print("registration complete")

      if __name__ == "__main__":
          main()

runcmd:
  # Self-signed TLS for the nginx fronting Guacamole
  - mkdir -p /opt/guac/tls
  - openssl req -x509 -newkey rsa:2048 -nodes -days 825
      -keyout /opt/guac/tls/key.pem
      -out /opt/guac/tls/cert.pem
      -subj "/CN=guacamole"

  # Pull the official Guacamole DB schema bundle and emit initdb.sql
  - |
    docker run --rm guacamole/guacamole:1.5.5 \
      /opt/guacamole/bin/initdb.sh --postgresql > /opt/guac/initdb.sql

  # Decode the manifest written above (cloud-init can't include base64
  # inline cleanly, so we wrote it as base64 then decode here)
  - base64 -d /opt/guac/manifest.b64 > /opt/guac/manifest.json
  - chmod 600 /opt/guac/manifest.json

  # Bring up the stack
  - cd /opt/guac && docker compose up -d

  # Wait for Guacamole API and run registration
  - |
    for i in $(seq 1 60); do
      curl -sf http://localhost:8080/guacamole/ >/dev/null && break
      sleep 5
    done
  - python3 /opt/guac/register.py >> /var/log/guac-register.log 2>&1 || true

  # Bootstrap Let's Encrypt cert (no-op when guac_fqdn is empty — i.e.
  # AFD/DNS not configured for this scenario, falls back to self-signed).
  # Run in background so cloud-init doesn't block ~5-10 min waiting for
  # DNS propagation + cert issuance.
  - bash /opt/guac/letsencrypt-bootstrap.sh &

  # Enable auto-renewal timer (no-op if we don't have a cert yet — the
  # timer will become useful as soon as letsencrypt-bootstrap.sh finishes).
  - systemctl daemon-reload
  - systemctl enable --now guacamole-cert-renew.timer
