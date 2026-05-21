#cloud-config
# ============================================================================
# Ephemeral Kali workspace host.
#
# What this VM does:
#   - Installs Docker.
#   - Builds a `kali-2:latest` image from kalilinux/kali-rolling +
#     kali-linux-core + xfce4 + tigervnc-standalone-server. Recipe mirrors
#     what's running on the per-student Kali VM (proven to work end-to-end
#     through Guacamole VNC) — just packaged into a container.
#   - Pre-spawns ${pool_size} containers named kali-2-1..N, each binding
#     host port 5900+i → container port 5901. Containers run with --rm
#     so a `docker restart` leaves no FS trace.
#   - When auto_restart=true, a 30-min cron restarts idle slots (no recent
#     guacd TCP connection on the slot port) — "ephemeral session, zero
#     state accumulation".
#
# Why this is a separate VM (NOT co-located on the Guacamole host):
#   - Kali containers run aggressive pentest tools by design. Escape
#     blast-radius MUST NOT include the Guac control plane.
#   - Each container is ~2-3 GB RSS. Guac is sized for the proxy stack.
#   - Independent lifecycle: redeploying Guac doesn't kill workspaces.
#
# Wired into Guacamole:
#   guacd (on Guac VM at 10.0.0.20) → 10.0.1.50:590i → container :5901.
#   NSG rule `from-guacamole-vnc` on hub_infra opens this path; the VM has
#   no public IP. Connections are named "kali-2-<i>" in the Guacamole UI.
# ============================================================================
package_update: true
package_upgrade: false
packages:
  - git
  - curl
  - wget
  - openssh-server
  - ca-certificates
  - jq
  - iproute2

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
  - path: /opt/kali-2/Dockerfile
    permissions: "0644"
    content: |
      # Ephemeral Kali container for operator sessions.
      #
      # Previous iteration used `kali-linux-core` + plain `xfce4` and looked
      # like generic Debian XFCE — no Kali wallpaper, no purple theme, no
      # Whisker tools menu, no dragon icon. This rebuild installs the
      # curated `kali-desktop-xfce` meta-package + themes + wallpapers +
      # menu + undercover so the container looks like an actual Kali Rolling
      # install. Adds ~1.5 GB to the image; on a workspaces VM with 40+ GB
      # of disk that's a worthwhile trade for the operator UX.
      #
      # Raw RFB on 5901 (no auth) is safe because guacd connects over an
      # internal docker bridge and the host port is locked down by the
      # hub_infra NSG to the Guac VM IP only.
      FROM kalilinux/kali-rolling

      ENV DEBIAN_FRONTEND=noninteractive \
          USER=ranger \
          HOME=/home/ranger \
          DISPLAY=:1 \
          LANG=en_US.UTF-8 \
          XDG_CURRENT_DESKTOP=XFCE

      # Curated Kali desktop stack. The big package wins:
      #   kali-desktop-xfce    XFCE pre-configured the Kali way (panel
      #                        layout, default apps, kali-tweaks integration)
      #   kali-themes(-common) Flat-Remix-Blue-Dark GTK + matching cursors
      #   kali-wallpapers-2024 Official wallpapers (rolling release set)
      #   kali-menu            Tools tree under the Whisker menu (the thing
      #                        operators actually use)
      #   kali-undercover      One-click "look like Windows 10" toggle
      #   kali-tweaks          Built-in panel for theme/locale/desktop knobs
      #   kali-linux-core      Core tools (nmap, hashcat, msf, ...); upgraded
      #                        to the full set if the operator wants via
      #                        kali-linux-default at runtime.
      # Package-name notes:
      #   kali-wallpapers-all   replaces the yearly kali-wallpapers-YYYY
      #                         packages — pulls the current-rolling set.
      #   polkitd               replaces the old policykit-1 name (renamed
      #                         upstream in 2024). Required for XFCE's
      #                         session bus auth to work cleanly.
      #   kali-themes pulls kali-themes-common transitively — we list both
      #                         explicitly for clarity.
      RUN apt-get update && apt-get install -y --no-install-recommends \
            kali-linux-core \
            kali-desktop-xfce \
            kali-themes \
            kali-themes-common \
            kali-wallpapers-all \
            kali-menu \
            kali-undercover \
            kali-tweaks \
            xfce4-terminal \
            xfce4-goodies \
            xfce4-whiskermenu-plugin \
            tigervnc-standalone-server \
            tigervnc-common \
            tigervnc-tools \
            dbus-x11 \
            xfonts-base \
            fonts-noto-core \
            fonts-firacode \
            fonts-dejavu-core \
            sudo \
            curl wget git ca-certificates \
            iproute2 procps less nano vim-tiny \
            python3 python3-pip \
            polkitd \
          && rm -rf /var/lib/apt/lists/*

      RUN useradd -m -s /bin/zsh ranger \
          && echo "ranger ALL=(ALL) NOPASSWD:ALL" >/etc/sudoers.d/ranger \
          && chmod 0440 /etc/sudoers.d/ranger

      # Seed ranger's XFCE config from the Kali skel so the very first
      # session boots with the curated panel layout, wallpaper, and
      # keybindings — instead of XFCE's "First time setup" dialog.
      RUN if [ -d /etc/skel/.config ]; then \
            cp -a /etc/skel/.config /home/ranger/ ; \
          fi \
          && if [ -d /etc/skel/.local ]; then \
               cp -a /etc/skel/.local /home/ranger/ ; \
             fi \
          && if [ -d /etc/skel/.zshrc ] || [ -f /etc/skel/.zshrc ]; then \
               cp -a /etc/skel/.zshrc /home/ranger/.zshrc 2>/dev/null || true ; \
             fi \
          && chown -R ranger:ranger /home/ranger

      COPY start.sh /usr/local/bin/start.sh
      RUN chmod +x /usr/local/bin/start.sh

      EXPOSE 5901
      USER ranger
      WORKDIR /home/ranger
      CMD ["/usr/local/bin/start.sh"]

  - path: /opt/kali-2/start.sh
    permissions: "0755"
    content: |
      #!/bin/bash
      # Start Xvnc + Kali XFCE inside the kali-2 container.
      # No auth on RFB — guacd is the only thing that can reach the host
      # port (NSG-restricted to Guac VM IP).
      set -e

      # Belt-and-braces: each container is fresh (--rm), but clear stale
      # X1 state defensively in case of restart-without-rm.
      rm -f /tmp/.X1-lock /tmp/.X11-unix/X1 2>/dev/null || true
      mkdir -p /tmp/.X11-unix && chmod 1777 /tmp/.X11-unix

      # 2560x1440 starting geometry — same default as the regular Kali
      # VM (see modules/azure/ansible/roles/kali/tasks/main.yml for
      # the geometry trade-off discussion). Guacamole's VNC client
      # doesn't auto-resize, so this is what the operator gets for the
      # whole session. Override per-deploy by editing this file +
      # rebuilding the kali-2 image; the regular Kali VM uses an
      # ansible var `kali_vnc_geometry` for the same knob.
      Xvnc :1 \
        -geometry 2560x1440 -depth 24 \
        -SecurityTypes None \
        -BlacklistTimeout 0 \
        -AlwaysShared=1 \
        -AcceptSetDesktopSize=1 \
        -rfbport 5901 \
        -localhost no &
      # NOTE on bare $ refs below ($!, $XVNC_PID, $1, $5):
      # terraform's templatefile() only treats "dollar-dollar-brace" as
      # an escape (renders as a literal dollar-brace). Bare dollar refs
      # without braces pass through unchanged, so they're safe as-is.
      # Doubling them would render literally and break bash semantics.
      XVNC_PID=$!

      # Wait until Xvnc binds 5901 before launching the WM.
      for i in 1 2 3 4 5 6 7 8 9 10; do
        if ss -tln 2>/dev/null | grep -q ":5901 "; then break; fi
        sleep 1
      done

      export DISPLAY=:1
      # Pre-populate RandR modes so Guacamole's SetDesktopSize requests
      # (driven by the operator's browser viewport) can resize the
      # framebuffer past Xtigervnc's default 1920x1200 mode pool.
      # Without this the operator sees black-bar letterboxing on any
      # window larger than 1080p — same fix as the regular Kali VM.
      _addmode() {
        ml=$(cvt "$1" "$2" 2>/dev/null | grep '^Modeline' | sed 's/^Modeline //')
        [ -z "$ml" ] && return
        name=$(echo "$ml" | awk '{print $1}' | tr -d '"')
        rest=$(echo "$ml" | sed 's/^"[^"]*" *//')
        xrandr --newmode "$name" $rest 2>/dev/null
        xrandr --addmode VNC-0 "$name" 2>/dev/null
      }
      for res in 2048x1152 2256x1504 2400x1350 2560x1440 2560x1600 \
                 2880x1620 3000x2000 3200x1800 3840x2160; do
        # Bash parameter expansion: strip suffix (after x) and prefix
        # (before x) from "1920x1080" -> width "1920" and height "1080".
        # The doubled-dollar prefix below is mandatory so terraform's
        # templatefile() leaves the brace block alone for bash to
        # interpret at runtime; otherwise terraform sees a runaway HCL
        # expression and errors out.
        _addmode "$${res%x*}" "$${res#*x}"
      done

      # Screen-blank + lock prevention. Two layers, because the themed
      # kali-desktop-xfce image ships xfce4-screensaver (the LOCK-screen
      # daemon) which has its OWN idle timer independent of xset:
      #
      #   1. xset — disables the X server's built-in screensaver + DPMS
      #      blanking. Guacamole's HTML5 client doesn't emit the X11
      #      input events these timers count as activity, so without
      #      this the framebuffer goes black after the idle timeout.
      #   2. xfce4-screensaver autostart override — the kali-desktop-xfce
      #      meta pulls in xfce4-screensaver, which would lock/blank the
      #      session on its own schedule. A Hidden=true autostart entry
      #      stops it launching with the session. (Same approach the
      #      kali ansible role uses for the `kali` VM.)
      xset s off       2>/dev/null
      xset s noblank   2>/dev/null
      xset s 0 0       2>/dev/null
      xset -dpms       2>/dev/null
      mkdir -p /home/ranger/.config/autostart
      cat > /home/ranger/.config/autostart/xfce4-screensaver.desktop <<'SAVEROFF'
      [Desktop Entry]
      Type=Application
      Hidden=true
      SAVEROFF
      # Belt-and-braces: if a screensaver is already running (e.g. on a
      # container recycle where the session restarts), kill it.
      # NOTE: must use `pkill -f`, NOT `pkill -x`. The process name
      # "xfce4-screensaver" is 17 chars but the kernel comm field is
      # capped at 15, so it shows as "xfce4-screensav" — `pkill -x`
      # (exact comm match) would silently match nothing. `-f` matches
      # the full command line and works.
      pkill -f xfce4-screensaver 2>/dev/null || true

      # dbus-launch positional args become the command — wrap xfce4 in
      # sh -c so --exit-with-session stays bound to dbus-launch.
      # XDG_CURRENT_DESKTOP=XFCE is set in the Dockerfile so panel
      # plugins (whiskermenu, kali-undercover) activate correctly.
      dbus-launch --exit-with-session sh -c "exec xfce4-session" &

      # Foreground-wait on Xvnc; if it exits the container exits.
      wait "$XVNC_PID"

  - path: /usr/local/bin/kali-2-spawn-pool.sh
    permissions: "0755"
    content: |
      #!/bin/bash
      # Idempotent: spawn pool_size kali-2 containers on host ports
      # 5901..5900+POOL_SIZE. Skip slots that are already running.
      # Containers use --rm so they're truly ephemeral on restart.
      set -e
      POOL_SIZE=${pool_size}
      IMAGE=kali-2:latest

      for i in $(seq 1 $POOL_SIZE); do
        NAME="kali-2-$i"
        PORT=$((5900 + i))
        if docker ps --format '{{.Names}}' | grep -qx "$NAME"; then
          echo "[pool] $NAME already running on :$PORT — skip"
          continue
        fi
        # Clean up any stopped instance (--rm should have removed it, but
        # be defensive if a container died unexpectedly).
        docker rm -f "$NAME" 2>/dev/null || true
        echo "[pool] spawning $NAME on host :$PORT"
        docker run -d --rm \
          --name "$NAME" \
          -p "$${PORT}:5901" \
          --shm-size=512m \
          --tmpfs /tmp:size=512m \
          "$IMAGE"
      done

  - path: /usr/local/bin/kali-2-recycle.sh
    permissions: "0755"
    content: |
      #!/bin/bash
      # Recycle idle pool slots. "Idle" = no active TCP connection from
      # the Guac VM (10.0.0.20) to the slot's host port. Restarting a
      # container with --rm gets a fresh root filesystem — that's the
      # "ephemeral session" guarantee.
      set -e
      POOL_SIZE=${pool_size}
      GUAC_IP=10.0.0.20

      for i in $(seq 1 $POOL_SIZE); do
        NAME="kali-2-$i"
        PORT=$((5900 + i))
        # ss -tn dst :PORT shows established conns to that port. Count
        # peers from the Guac VM only.
        # awk: positional fields 4 and 5 are the local/peer addr
        # columns from `ss -tn`. Bare dollar-N refs pass through
        # terraform's templatefile() unchanged. Single-quoting the awk
        # program also prevents bash from touching them at run time.
        ACTIVE=$(ss -tn "( dport = :$PORT or sport = :$PORT )" 2>/dev/null \
                 | awk -v ip="$GUAC_IP" '$5 ~ ip || $4 ~ ip' \
                 | wc -l)
        if [ "$ACTIVE" -gt 0 ]; then
          echo "[recycle] $NAME has $ACTIVE active conn(s) — keep"
          continue
        fi
        echo "[recycle] $NAME idle — restarting for fresh state"
        docker rm -f "$NAME" 2>/dev/null || true
      done
      # Re-spawn anything we killed.
      /usr/local/bin/kali-2-spawn-pool.sh

  - path: /etc/systemd/system/kali-2-pool.service
    permissions: "0644"
    content: |
      [Unit]
      Description=Spawn kali-2 ephemeral container pool
      After=docker.service network-online.target
      Requires=docker.service
      Wants=network-online.target

      [Service]
      Type=oneshot
      ExecStart=/usr/local/bin/kali-2-spawn-pool.sh
      RemainAfterExit=yes

      [Install]
      WantedBy=multi-user.target

runcmd:
  - hostnamectl set-hostname workspaces
  - sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
  - systemctl restart ssh

  # Docker install (upstream script — same pattern as redelk.sh).
  - curl -fsSL https://get.docker.com | sh
  - usermod -aG docker ${linux_user}

  # Build the kali-2 image in the BACKGROUND. Apt pulling kali-linux-core
  # + xfce4 + dependencies is ~1.5 GB of packages; first build is 10-15
  # min on Azure first-boot networking. Blocking cloud-init would push
  # the VM past Azure's extension-status timeout. Transcript at
  # /var/log/kali-2-build.log on the VM; tail -f to watch.
  - |
    cd /opt/kali-2
    nohup bash -c '
      set -e
      docker build -t kali-2:latest . 2>&1
      # Once the image is built, enable+start the pool unit (which
      # spawns the containers). The unit is installed but not enabled
      # until the image is ready, so a partial build never leaves the
      # system trying to docker-run a non-existent image.
      systemctl enable --now kali-2-pool.service
    ' > /var/log/kali-2-build.log 2>&1 &
    disown || true

  # Cron: recycle idle slots every ${restart_interval_min} minutes.
  # Skipped when auto_restart=false (the template renders an empty
  # cron line, which crontab tolerates as a noop).
  - |
    if [ "${auto_restart}" = "true" ]; then
      cat >/etc/cron.d/kali-2-recycle <<EOF
    # Recycle idle kali-2 slots every ${restart_interval_min} min for
    # ephemeral session guarantees. Reads guac VM peer from kernel
    # socket table — idle slots get torn down + respawned with --rm,
    # yielding a fresh root filesystem.
    */${restart_interval_min} * * * * root /usr/local/bin/kali-2-recycle.sh >> /var/log/kali-2-recycle.log 2>&1
    EOF
      chmod 0644 /etc/cron.d/kali-2-recycle
    fi

  # MOTD: orient operators who SSH in for debugging.
  - |
    cat >/etc/motd <<'EOM'
    ============================================================
      Workspaces — ephemeral Kali container pool
      Image build : tail -f /var/log/kali-2-build.log
      Recycle log : tail -f /var/log/kali-2-recycle.log
      Pool state  : docker ps --filter name=kali-2
      Pool spawn  : /usr/local/bin/kali-2-spawn-pool.sh
      Pool recycle: /usr/local/bin/kali-2-recycle.sh
      Image src   : /opt/kali-2/{Dockerfile,start.sh}
      Slot ports  : 5901..590N (one container each → :5901 inside)
      Guac access : kali-2-<i> connections in the Guacamole UI
    ============================================================
    EOM
