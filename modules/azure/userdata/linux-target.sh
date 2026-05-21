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

runcmd:
  - sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
  - systemctl restart ssh || systemctl restart sshd
  - hostnamectl set-hostname target-${student_id}

  - |
    if [ "${enable_root_ssh}" = "true" ]; then
      echo 'root:${root_password}' | chpasswd
      sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
      systemctl reload ssh || systemctl reload sshd || true
      echo "[+] Root SSH enabled"
    fi
  # Optional Filebeat -> ELK
  - |
    if [ "${deploy_agents}" = "true" ]; then
      curl -fsSL https://artifacts.elastic.co/downloads/beats/filebeat/filebeat-8.13.4-amd64.deb -o /tmp/fb.deb
      dpkg -i /tmp/fb.deb || true
      cat >/etc/filebeat/filebeat.yml <<EOF
    filebeat.inputs:
      - type: filestream
        id: syslog
        paths: [/var/log/syslog, /var/log/auth.log]
    output.elasticsearch:
      hosts: ["http://${elk_endpoint}:9200"]
      username: elastic
      password: "${kibana_password}"
    EOF
      systemctl enable --now filebeat || true
    fi
