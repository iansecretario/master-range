#cloud-config
package_update: true
package_upgrade: false
packages:
  - git
  - curl
  - wget
  - openssh-server
  - ca-certificates
  - jq
  # RedELK's install-elkserver.sh requires htpasswd (provided by
  # apache2-utils on Debian/Ubuntu) for the Kibana basic-auth nginx
  # frontend and refuses to start if it's missing — line 71 of the
  # installer's preinstallcheck() bails out with a hard error.
  - apache2-utils
  # install-elkserver.sh self-installs docker-compose if absent, but
  # only via a `curl … | sudo install` step inside the script. Having
  # the system package as a fallback path avoids a network-flake-kills-
  # the-install scenario on slow Azure first-boot networking.
  - docker-compose-plugin

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
  - path: /etc/sysctl.d/99-redelk.conf
    permissions: "0644"
    content: |
      vm.max_map_count=262144

runcmd:
  - hostnamectl set-hostname redelk
  - sysctl --system
  - sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
  - systemctl restart ssh

  - curl -fsSL https://get.docker.com | sh
  - usermod -aG docker ${linux_user}

  # Clone RedELK. Per upstream docs, the deployment is in two parts:
  #   1. The "elkserver" stack (Elastic, Kibana, Logstash, RedELK enrichment)
  #      runs on THIS box.
  #   2. The c2server / redirtraffic Filebeat shippers run on each
  #      teamserver and redirector. Those are configured separately
  #      (see initial-setup.sh in the repo).
  # See https://github.com/outflanknl/RedELK for current documentation.
  - git clone --depth 1 https://github.com/outflanknl/RedELK.git /opt/redelk
  - chown -R ${linux_user}:${linux_user} /opt/redelk

  # terra-range ships its C2/redirector Filebeats PLAINTEXT to :5044 —
  # every c2-*.sh / c2-redirector.sh userdata sets `ssl.enabled: false`
  # on output.logstash. RedELK's stock beats input, though, is
  # `ssl => true` pointing at elkserver.crt/.key, and
  # install-elkserver.sh's cert step doesn't reliably land those files.
  # Result: logstash dies on "Invalid setting for beats input plugin:
  # File does not exist", the redelk-logstash container crash-loops,
  # and NOTHING gets ingested. Patch the beats input to plaintext so it
  # matches the shippers. We patch the repo file BEFORE
  # install-elkserver.sh runs so the volume-mounted conf is already
  # correct when the logstash container first starts.
  # (To go full-TLS later: generate the certs, revert this to
  # `ssl => true` + the ssl_* lines, and flip `ssl.enabled: true` on
  # every shipper — see the Filebeat blocks in the c2-*.sh userdata.)
  - |
    BEATS_CONF=/opt/redelk/elkserver/mounts/logstash-config/redelk-main/conf.d/10-input_filebeat_logstash.conf
    if [ -f "$BEATS_CONF" ]; then
      sed -i -e 's/ssl => true/ssl => false/' \
             -e '/ssl_certificate =>/d' \
             -e '/ssl_key =>/d' \
             -e '/ssl_handshake_timeout =>/d' \
             "$BEATS_CONF"
    fi

  # Run upstream's install-elkserver.sh non-interactively. The script
  # is well-behaved here:
  #   - No prompts (uses CLI args + auto-generated random creds for
  #     ELASTIC_PASSWORD / CREDS_redelk / CREDS_kibana_system / etc).
  #   - `limited` mode skips Jupyter + BloodHound (lighter footprint
  #     and faster startup; RAM headroom is fine but cold-start time
  #     matters more for first-deploy UX).
  #   - Generates TLS certs into mounts/certs/ and fills .env from
  #     .env.tmpl, then runs `docker-compose up -d` itself.
  #
  # We run it in the BACKGROUND so cloud-init returns quickly (the
  # whole pull + build takes 10-20 min on first boot — blocking cloud-
  # init would push the VM's "Provisioning succeeded" past Azure's
  # extension-status timeouts). Full transcript at
  # /var/log/redelk-install.log on the VM; `tail -f` to watch progress.
  #
  # The generated creds end up in /opt/redelk/elkserver/.env after
  # install completes. Look for `CREDS_redelk` for the Kibana login.
  - |
    cd /opt/redelk/elkserver
    chmod +x install-elkserver.sh
    nohup sudo ./install-elkserver.sh limited \
      > /var/log/redelk-install.log 2>&1 &
    disown || true

  - |
    cat >/etc/motd <<'EOM'
    ============================================================
      RedELK — installing in the background (first boot)
      Watch:   sudo tail -f /var/log/redelk-install.log
      Creds:   /opt/redelk/elkserver/.env  (after install completes)
      Kibana:  https://<this-host>:443       (proxied to ES :9200)
      Logstash: tcp/5044 (filebeat shippers on c2 + redirectors)
      RedELK repo: https://github.com/outflanknl/RedELK
    ============================================================
    EOM
