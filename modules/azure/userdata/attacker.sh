#cloud-config
# Kali attacker workstation cloud-init. Provides enough to make the VM
# SSH-reachable and Ansible-manageable. The Ansible role
# (modules/azure/ansible/roles/kali/) installs the actual GUI +
# kali-linux-default toolset on first repair — that takes ~15-30 min
# and is too risky to put inline here (cloud-init failures during
# multi-GB apt installs can leave the VM in a half-broken state).
#
# So this cloud-init keeps it minimal: SSH key + sudo for the user.
# Run `./range repair --limit kali` to install the desktop & toolset.
package_update: true
packages:
  - openssh-server

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
  - hostnamectl set-hostname attacker-${student_id}
  - sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
  - systemctl restart ssh
