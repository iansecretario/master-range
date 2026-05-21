#cloud-config
package_update: true
package_upgrade: false
packages:
  - git
  - curl
  - wget
  - openssh-server
  - ca-certificates
  - python3
  - python3-pip
  - jq

users:
  - name: ${linux_user}
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: false
    shell: /bin/bash
    plain_text_passwd: ${linux_pass}
    ssh_authorized_keys:
      - ${ssh_pubkey}

ssh_pwauth: true

runcmd:
  - hostnamectl set-hostname ghostwriter
  - sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
  - systemctl restart ssh

  # Docker (Ghostwriter requires it)
  - curl -fsSL https://get.docker.com | sh
  - usermod -aG docker ${linux_user}

  # Clone Ghostwriter and run the upstream installer.
  # See https://github.com/GhostManager/Ghostwriter for current docs.
  - git clone --depth 1 https://github.com/GhostManager/Ghostwriter.git /opt/ghostwriter
  - chown -R ${linux_user}:${linux_user} /opt/ghostwriter
  - |
    cat <<'EOS' >/opt/ghostwriter/install.sh
    #!/bin/bash
    set -e
    cd /opt/ghostwriter
    # Use the helper that comes with the repo. Production setup pulls
    # images and seeds the DB. First run can take 5-10 minutes.
    sudo ./ghostwriter-cli install || sudo ./ghostwriter-cli-linux install
    EOS
  - chmod +x /opt/ghostwriter/install.sh
  - su - ${linux_user} -c "/opt/ghostwriter/install.sh" >> /var/log/ghostwriter-install.log 2>&1 || true

  # Ghostwriter ships with a hardcoded DJANGO_ALLOWED_HOSTS that lists
  # only loopback aliases — so reaching the UI by the VM's actual
  # private IP returns "Bad Request (400)". Inject the IP into the
  # list and bounce the stack. The CLI's `containers down/up` cycle
  # is the only supported way to apply env changes; `restart` isn't a
  # subcommand. operator can re-run via:
  #   sudo /opt/ghostwriter/ghostwriter-cli-linux config set django_allowed_hosts "<list>"
  - |
    set -e
    GW_IP=$(hostname -I | awk '{print $1}')
    GW_BIN=/opt/ghostwriter/ghostwriter-cli-linux
    [ -x "$GW_BIN" ] || GW_BIN=/opt/ghostwriter/ghostwriter-cli
    sudo "$GW_BIN" config set django_allowed_hosts \
      "localhost 127.0.0.1 django nginx host.docker.internal ghostwriter.local $GW_IP ghostwriter" \
      >> /var/log/ghostwriter-install.log 2>&1 || true
    sudo "$GW_BIN" containers down >> /var/log/ghostwriter-install.log 2>&1 || true
    sudo "$GW_BIN" containers up   >> /var/log/ghostwriter-install.log 2>&1 || true

  # MOTD with login URL
  - |
    cat >/etc/motd <<EOM
    ============================================================
      Ghostwriter
      https://<this-vm-public-ip>/
      Default admin password is in: /opt/ghostwriter/.env
      Repo:  /opt/ghostwriter
      Logs:  /var/log/ghostwriter-install.log
    ============================================================
    EOM
