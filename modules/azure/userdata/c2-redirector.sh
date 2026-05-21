#cloud-config
# =============================================================================
# C2 redirector — uniform 5-CDN model for all teamserver framework backends.
# =============================================================================
# Topology:
#
#     CDN (AFD / CloudFront / workers.dev / Fastly / other) ───► :443 nginx
#                                                                     │
#         per-CDN header check: X-Api-<RandomName>: <UUID>            │
#                  ↓ matched                  ↓ no match              │
#          proxy to upstream port             302 cover URL           │
#          (8443/8444/8445/8446/8447)                                 │
#                                                                     │
# Each CDN injects its own (header_name, header_value) pair, matched
# by nginx and proxied to the per-CDN upstream port:
#
#   azure       -> X-Api-<random>: <uuid>  -> :8443 on teamserver
#   cloudfront  -> X-Api-<random>: <uuid>  -> :8444
#   workers     -> X-Api-<random>: <uuid>  -> :8445
#   fastly      -> X-Api-<random>: <uuid>  -> :8446
#   other       -> X-Api-<random>: <uuid>  -> :8447
#
# Header names + UUIDs are generated per (student, stack) in passwords.tf
# and threaded through vms.tf.
#
# Upstream teamserver IP comes from `fronts:` in the scenario YAML:
#   fronts: c2-server  → 10.<n>.1.5    (Adaptix)
#   fronts: c2-mythic  → 10.<n>.1.7    (Mythic)
#   fronts: c2-brc4    → 10.<n>.1.9    (BRC4)
# =============================================================================
package_update: true
packages:
  # NOTE: nginx is NOT in packages: anymore. cloud-init writes
  # /etc/nginx/conf.d/c2-redirect.conf via write_files BEFORE apt
  # installs nginx; if nginx is installed via packages, its post-install
  # script runs `nginx -t` + tries to start the service, BUT
  # /etc/nginx/tls/cert.pem doesn't exist yet (created in runcmd by
  # openssl req below). The dpkg-configure step fails -> nginx
  # service ends up in 'failed' state, redirector never serves.
  #
  # Install nginx in runcmd AFTER the cert is in place.
  - openssl
  - openssh-server
  - curl
  - gnupg      # needed by `gpg --dearmor` when adding the Elastic apt key

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
  - path: /etc/nginx/conf.d/c2-redirect.conf
    permissions: "0644"
    content: |
      # ---------------------------------------------------------------
      # Per-CDN header → upstream-port maps.
      #
      # Each map reads one HTTP request header by name. If the value
      # matches the expected UUID, the map emits the upstream port for
      # that CDN; otherwise 0. Exactly one map should fire per request.
      # ---------------------------------------------------------------
      %{ for h in cdn_headers ~}
      map $http_${h.header_var} $port_${h.cdn} {
        default                 0;
        "${h.value}"            ${h.port};
      }
      %{ endfor ~}

      # Combine the five per-CDN ports into one selected upstream port.
      # Each map above emits 0 or its assigned port — well-formed traffic
      # has exactly one non-zero entry. Concatenate and look up.
      map "$port_azure-$port_cloudfront-$port_workers-$port_fastly-$port_other" $upstream_port {
        default            0;
        "8443-0-0-0-0"     8443;
        "0-8444-0-0-0"     8444;
        "0-0-8445-0-0"     8445;
        "0-0-0-8446-0"     8446;
        "0-0-0-0-8447"     8447;
      }

      server {
        listen 443 ssl;
        server_name _;

        ssl_certificate     /etc/nginx/tls/cert.pem;
        ssl_certificate_key /etc/nginx/tls/key.pem;

        # Cover identity for casual scanning / direct probes.
        server_tokens off;
        add_header Server "Microsoft-IIS/10.0" always;

        # No matching CDN header → looks like a parked / redirect page.
        if ($upstream_port = 0) {
          return 302 ${cover_url};
        }

        # Cover content for index hits that DID validate (rare — most
        # CDN traffic is to the C2 endpoint path). Keeps a casual GET /
        # from looking like a C2 hit.
        location = / {
          return 200 "OK";
        }

        # Beacon traffic. Upstream is the teamserver's per-CDN HTTPS
        # listener on the port selected by which header matched.
        location / {
          proxy_pass              https://${upstream_host}:$upstream_port$request_uri;
          proxy_ssl_verify        off;
          proxy_set_header        Host $host;
          proxy_set_header        X-Real-IP $remote_addr;
          proxy_set_header        X-Forwarded-For $proxy_add_x_forwarded_for;
          proxy_set_header        X-Forwarded-Proto $scheme;
          proxy_http_version      1.1;
          proxy_buffering         off;
          proxy_read_timeout      600s;
          proxy_send_timeout      600s;

          access_log /var/log/nginx/c2.log;
          access_log /var/log/nginx/access-redelk.log redelklog;
        }
      }

  # RedELK-compatible access log format. Logs go to
  # /var/log/nginx/access-redelk.log; the Filebeat block below ships
  # them to the hub RedELK instance when one is present.
  #
  # IMPORTANT: filename prefixed with `00-` so nginx loads this file
  # BEFORE c2-redirect.conf (alphabetical order). Without the prefix,
  # c2-redirect.conf's `access_log ... redelklog;` references the
  # `redelklog` format before it's declared -> `nginx -t` errors with
  # "unknown log format redelklog" -> dpkg-configure fails -> nginx
  # service stays in failed state.
  - path: /etc/nginx/conf.d/00-redelk-log-format.conf
    permissions: "0644"
    content: |
      log_format redelklog '[$time_local] $host nginx[$pid]: '
        'frontend:${student_id}/$server_addr:$server_port '
        'backend:${upstream_host}:$upstream_port '
        'client:$remote_addr:$remote_port '
        'xforwardedfor:$http_x_forwarded_for '
        'headers:{$http_user_agent|$host|$http_x_forwarded_for|$http_x_forwarded_proto} '
        'statuscode:$status request:$request';

  # ---- Filebeat → RedELK shipper -------------------------------------
  - path: /etc/filebeat/filebeat.yml.tmpl
    permissions: "0640"
    content: |
      filebeat.inputs:
        - type: log
          enabled: true
          paths:
            - /var/log/nginx/access-redelk.log
          fields:
            infra: redirtraffic
            infralog: rtops
            redirector: redir-${student_id}
            redirprogram: nginx
          fields_under_root: true
          tags: ["redirtraffic"]
        - type: log
          enabled: true
          paths:
            - /var/log/nginx/error.log
          fields:
            infra: redirtraffic
            infralog: rterrors
            redirector: redir-${student_id}
          fields_under_root: true
          tags: ["redirtraffic", "errors"]
      output.logstash:
        hosts: ["__REDELK_IP__:5044"]
        ssl.enabled: false

runcmd:
  - hostnamectl set-hostname redir-${student_id}
  - sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
  - systemctl restart ssh

  # Generate the TLS cert FIRST so nginx's first start can find it.
  - mkdir -p /etc/nginx/tls
  - openssl req -x509 -newkey rsa:2048 -nodes -days 825 -keyout /etc/nginx/tls/key.pem -out /etc/nginx/tls/cert.pem -subj "/CN=redir-${student_id}"
  - chmod 600 /etc/nginx/tls/key.pem

  # NOW install nginx. Its post-install runs nginx -t against the
  # config in /etc/nginx/conf.d/c2-redirect.conf (written via
  # write_files earlier); the cert it references is now in place so
  # the test passes and the service starts cleanly.
  - DEBIAN_FRONTEND=noninteractive apt-get install -y nginx

  # Strip every Debian-default config so our /etc/nginx/conf.d/c2-redirect.conf
  # is the ONLY thing serving on :443. The default site ships a
  # `listen 80 default_server` (harmless), but some flavors also ship
  # a `listen 443 ssl default_server` which would shadow our server
  # block and cause the operator to see "Welcome to nginx!" instead
  # of the cover-URL redirect / proxied beacon traffic.
  - rm -f /etc/nginx/sites-enabled/default /etc/nginx/sites-available/default /etc/nginx/conf.d/default.conf
  - nginx -t && systemctl restart nginx
  - systemctl enable nginx

  # Filebeat → RedELK (skip when RedELK is absent from the scenario).
  # Run as root so it can read /var/log/nginx/*.log (which nginx
  # creates as mode 0640 owned by root:adm).
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
      echo "[+] Filebeat (as root) shipping redirector logs to RedELK at ${redelk_ip}:5044"
    else
      echo "[i] RedELK not in scenario; Filebeat skipped"
    fi
