#cloud-config
package_update: true
packages:
  - openssh-server
  - net-tools
  - curl
  - wget
  - vim
  - tmux
  - python3

users:
  - name: ${linux_user}
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: false
    shell: /bin/bash
    plain_text_passwd: ${linux_pass}

ssh_pwauth: true

write_files:
  # Persona script — base64-encoded by the generator. Cloud-init decodes
  # it and writes it to /tmp before runcmd executes. We chmod 700 so even
  # if cleanup somehow fails, only root could re-read it.
  - path: /tmp/persona.sh
    encoding: b64
    permissions: "0700"
    owner: root:root
    content: ${persona_b64}

  # Cleanup runner. Kept as a separate script (instead of inline in
  # runcmd) so the cleanup logic is auditable in one place and so we
  # can self-delete it cleanly.
  - path: /tmp/persona-cleanup.sh
    permissions: "0700"
    owner: root:root
    content: |
      #!/bin/bash
      # Wipe build-time traces of the persona. Deliberately NARROW —
      # only touches files that cloud-init created or that contain the
      # rendered persona script. Anything the persona itself wrote
      # (fake .bash_history files, planted flags, seeded log entries)
      # is preserved.
      set +e

      # 1. Persona script itself + this cleanup script
      shred -u /tmp/persona.sh        2>/dev/null || rm -f /tmp/persona.sh
      shred -u /tmp/persona-build.log 2>/dev/null || rm -f /tmp/persona-build.log

      # 2. Cloud-init logs — these contain the rendered runcmd, which
      #    includes the literal text of the persona script (cloud-init
      #    logs the b64-decoded version when it writes write_files).
      : > /var/log/cloud-init.log         2>/dev/null
      : > /var/log/cloud-init-output.log  2>/dev/null

      # 3. Cloud-init's cached user-data — original payload that brought
      #    up this VM. Wipe so a root-on-box student can't reverse the
      #    build by reading /var/lib/cloud/instances/*/user-data.txt.
      find /var/lib/cloud/instances -maxdepth 3 \
           \( -name 'user-data.txt*' -o -name 'cloud-config.txt' \
              -o -name 'scripts' -o -name 'sem' \) \
           -exec rm -rf {} + 2>/dev/null

      # 4. Systemd journal — drop entries from this boot. Persona
      #    scripts often write to journal too; if your scenario needs
      #    those preserved, comment these two lines out.
      journalctl --rotate    >/dev/null 2>&1
      journalctl --vacuum-time=1s >/dev/null 2>&1

      # 5. Self-destruct
      shred -u "$0" 2>/dev/null || rm -f "$0"

runcmd:
  - hostnamectl set-hostname ${hostname}
  - sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
  - systemctl restart ssh || systemctl restart sshd

  # Optional root SSH login. Used by scenarios like redteam-lab where
  # operators want a Guacamole connection as root for testing. Sets a
  # known root password and flips PermitRootLogin in sshd_config.
  - |
    if [ "${enable_root_ssh}" = "true" ]; then
      echo 'root:${root_password}' | chpasswd
      sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
      systemctl reload ssh || systemctl reload sshd || true
      echo "[+] Root SSH enabled"
    fi

  # Run the persona script as root. Any exit code is tolerated: the
  # persona may legitimately disable services or leave non-zero residue.
  - bash /tmp/persona.sh > /tmp/persona-build.log 2>&1 || true

  # Wipe build artefacts. This is the LAST runcmd entry; after it
  # finishes, /var/lib/cloud/instance/scripts/runcmd is gone.
  - bash /tmp/persona-cleanup.sh || true
