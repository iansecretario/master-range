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
  # SteppingStones is a Django app (not a docker-compose service), so
  # we need the system Python + venv tooling to install requirements
  # and bring it up via systemd. The userdata below provisions that.
  - python3
  - python3-pip
  - python3-venv
  - python3-dev
  - build-essential
  - libpq-dev

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
  - hostnamectl set-hostname stepping-stones
  - sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
  - systemctl restart ssh

  # Docker is unused — we run SteppingStones as a venv + systemd unit.
  # Keep `apt install docker.io` out of the picture to save ~150 MB.

  # SteppingStones is a SpecterOps Django project (NOT a docker-
  # compose stack — earlier versions of this userdata expected one and
  # silently exited after the git clone). Bring it up Django-style:
  # venv + pip install + migrate + collectstatic + gunicorn via systemd.
  #
  # PIN: SteppingStones main branch is on Django 6.0.4 / Python 3.12,
  # but the deploy VM is Debian 12 (Python 3.11). We pin to the last
  # commit that targets Django 5.x. When/if we upgrade the VM image
  # to Ubuntu 24.04 or install Python 3.12 via deadsnakes, drop the
  # checkout and just track main.
  - git clone https://github.com/nccgroup/SteppingStones.git /opt/stepping-stones
  - |
    cd /opt/stepping-stones
    # Find the most recent commit where requirements.txt still says
    # django==5.x. Falls back to a known-good SHA if the history walk
    # fails (e.g. very shallow clone or future upstream rewrites).
    set -e
    TARGET=$(git log --oneline -- requirements.txt 2>/dev/null | \
             while read sha _; do
               if git show "$sha:requirements.txt" 2>/dev/null | grep -qE "^[Dd]jango==[5]\."; then
                 echo "$sha"; break
               fi
             done)
    [ -z "$TARGET" ] && TARGET=ecfe500   # known-good fallback
    git checkout -q "$TARGET"
    # Python 3.11 (Debian 12) can't parse nested same-quote f-strings
    # like `f"{d["k"]}"` (that's a 3.12-only feature). Rewrite to
    # single quotes so the api.hashmob.views module imports cleanly.
    if [ -f api/hashmob/views.py ]; then
      python3 -c 'import pathlib; p = pathlib.Path("api/hashmob/views.py"); p.write_text(p.read_text().replace("serializer.data[\"founds\"]", "serializer.data[\x27founds\x27]"))'
    fi
  - chown -R ${linux_user}:${linux_user} /opt/stepping-stones

  # SteppingStones' settings.py HARDCODES DEBUG / ALLOWED_HOSTS /
  # CSRF_TRUSTED_ORIGINS — the pinned django==5.x commit reads no
  # environment at all — so the Environment= lines in the systemd unit
  # below were silently ignored: the app came up DEBUG=True with
  # ALLOWED_HOSTS=['.example.net', ...] and rejected every real request
  # with Django's DisallowedHost ("Invalid HTTP_HOST header"). Patch
  # settings.py to read the three from the environment (idempotent
  # regex rewrite — re-running re-applies the same substitution); the
  # systemd unit feeds them via the EnvironmentFile generated below.
  - |
    python3 - <<'PYEOF'
    import re, pathlib
    p = pathlib.Path("/opt/stepping-stones/stepping_stones/settings.py")
    s = p.read_text()
    if not re.search(r'^import os$', s, re.M):
        s = s.replace("from pathlib import Path\n",
                      "from pathlib import Path\nimport os\n", 1)
    s = re.sub(r'^DEBUG = .*$',
        'DEBUG = os.environ.get("DJANGO_DEBUG", "True").strip().lower() in ("1", "true", "yes", "on")',
        s, count=1, flags=re.M)
    s = re.sub(r'^ALLOWED_HOSTS = .*$',
        'ALLOWED_HOSTS = [h.strip() for h in os.environ.get("DJANGO_ALLOWED_HOSTS", "").split(",") if h.strip()] or [".localhost", "127.0.0.1", "[::1]"]',
        s, count=1, flags=re.M)
    s = re.sub(r'^CSRF_TRUSTED_ORIGINS = .*$',
        'CSRF_TRUSTED_ORIGINS = [o.strip() for o in os.environ.get("DJANGO_CSRF_TRUSTED_ORIGINS", "").split(",") if o.strip()] or ["http://127.0.0.1"]',
        s, count=1, flags=re.M)
    p.write_text(s)
    print("settings.py patched: DEBUG/ALLOWED_HOSTS/CSRF_TRUSTED_ORIGINS now env-driven")
    PYEOF

  # Write the Django env file the systemd unit reads. ALLOWED_HOSTS is
  # left wide open (*) — this VM has no public IP and is only reachable
  # from the hub VNet, so any-host is fine for a lab and means the app
  # keeps working if the VM's private IP ever changes. CSRF_TRUSTED_
  # ORIGINS can't take a bare * (Django requires scheme://host), so it
  # gets the VM's actual IP (computed at boot) plus the hostname/
  # localhost variants — enough for the login POST to work over
  # http://<ip>:8000. DEBUG off so errors don't leak the settings dump.
  - |
    SS_IP=$(hostname -I | awk '{print $1}')
    cat >/etc/stepping-stones.env <<ENVEOF
    DJANGO_ALLOWED_HOSTS=*
    DJANGO_CSRF_TRUSTED_ORIGINS=http://$SS_IP:8000,http://stepping-stones:8000,http://localhost:8000
    DJANGO_DEBUG=False
    ENVEOF
    chmod 0644 /etc/stepping-stones.env

  # IMPORTANT: cloud-init's `runcmd` heredocs execute under /bin/sh
  # (dash on Debian), NOT bash. dash supports `set -u` / `set -x` but
  # does NOT recognize `-o pipefail` — passing it makes dash bail with
  #   /var/lib/cloud/instance/scripts/runcmd: 27: set: Illegal option -o pipefail
  # which aborts the ENTIRE runcmd module mid-flight. We saw this
  # previously: the script ran git clone + ownership chown, then died
  # before installing the venv / gunicorn unit, leaving the VM with
  # the repo cloned but no service running.
  #
  # Fix: drop `-o pipefail` here. We keep `-u` and `-x` (both supported
  # by dash) for the safety net. The script doesn't rely on
  # pipe-status-aware short-circuiting; any pipe failures show up in
  # /var/log/stepping-stones.log via the explicit `>>` redirects below.
  - |
    set -ux
    cd /opt/stepping-stones
    sudo -u ${linux_user} python3 -m venv .venv
    sudo -u ${linux_user} .venv/bin/pip install --upgrade pip wheel >> /var/log/stepping-stones.log 2>&1
    # SteppingStones requirements.txt expects Django, gunicorn, etc.
    # We also add gunicorn explicitly in case it's absent upstream.
    sudo -u ${linux_user} .venv/bin/pip install -r requirements.txt >> /var/log/stepping-stones.log 2>&1
    sudo -u ${linux_user} .venv/bin/pip install gunicorn >> /var/log/stepping-stones.log 2>&1

    # First-time DB migration (sqlite by default) + admin seed. The
    # repo's manage.py is at the project root.
    sudo -u ${linux_user} .venv/bin/python manage.py migrate --noinput >> /var/log/stepping-stones.log 2>&1 || true
    sudo -u ${linux_user} .venv/bin/python manage.py collectstatic --noinput >> /var/log/stepping-stones.log 2>&1 || true
    # Seed superuser ranger / Op!01! (per-deploy creds match the
    # student template defaults the operator already gets via creds).
    sudo -u ${linux_user} DJANGO_SUPERUSER_USERNAME=${linux_user} \
                          DJANGO_SUPERUSER_EMAIL=${linux_user}@local \
                          DJANGO_SUPERUSER_PASSWORD='${linux_pass}' \
      .venv/bin/python manage.py createsuperuser --noinput >> /var/log/stepping-stones.log 2>&1 || true

  - |
    cat >/etc/systemd/system/stepping-stones.service <<'EOS'
    [Unit]
    Description=SteppingStones Django app
    After=network-online.target
    Wants=network-online.target

    [Service]
    Type=simple
    User=${linux_user}
    WorkingDirectory=/opt/stepping-stones
    # DEBUG / ALLOWED_HOSTS / CSRF_TRUSTED_ORIGINS come from
    # /etc/stepping-stones.env (written at boot above with this VM's
    # actual hub-VNet IP). settings.py was patched above to read them —
    # the pinned SteppingStones commit hardcodes all three otherwise,
    # which is why the old inline `Environment=DJANGO_ALLOWED_HOSTS=*`
    # had no effect. Leading `-` keeps the unit startable even if the
    # file is somehow missing (settings.py then falls back to defaults).
    EnvironmentFile=-/etc/stepping-stones.env
    ExecStart=/opt/stepping-stones/.venv/bin/gunicorn \
      --bind 0.0.0.0:8000 --workers 3 --timeout 120 \
      stepping_stones.wsgi:application
    Restart=on-failure
    RestartSec=5
    StandardOutput=append:/var/log/stepping-stones.log
    StandardError=append:/var/log/stepping-stones.log

    [Install]
    WantedBy=multi-user.target
    EOS

  - systemctl daemon-reload
  - systemctl enable --now stepping-stones.service

  # `$${...}` is the terraform templatefile() escape — it renders as
  # `$${...}` in the resulting file so bash (not terraform) evaluates
  # the `:-this-host` default. $${linux_user} / $${linux_pass} stay as
  # single-dollar terraform interpolations because they ARE template
  # vars provided to this file.
  - |
    cat >/etc/motd <<EOM
    ============================================================
      SteppingStones (Django)
      Web UI :   http://$(hostname -I | awk '{print $$1}'):8000/
      Login  :   ${linux_user} / ${linux_pass}
      Repo   :   /opt/stepping-stones
      venv   :   /opt/stepping-stones/.venv
      Logs   :   /var/log/stepping-stones.log
      Service:   systemctl status stepping-stones
    ============================================================
    EOM
