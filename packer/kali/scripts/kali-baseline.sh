#!/bin/sh
# terra-range — Kali pre-bake provisioner.
#
# Runs ONCE during `./range bake kali`. Installs the slow,
# deploy-INVARIANT bits so every subsequent `./range apply` skips them:
#   - kali-linux-default  : ~2.5 GB offensive toolset (the big one — the
#                           single slowest task in the whole deploy)
#   - kali-desktop-xfce   : XFCE desktop + dbus-x11
#   - tigervnc + xrdp     : the remote-desktop stack
#   - AdaptixClient Qt6 build deps — mirrors the kali role's
#     "Install AdaptixClient build deps" task, so the per-deploy `make`
#     is the only AdaptixClient cost left, not the ~12-package apt churn
#
# Everything deploy-SPECIFIC stays in the kali ansible role and runs
# fast against this baked image:
#   - xrdp.ini / sesman.ini patches, autorun=Xvnc
#   - ~/.xsession + screensaver-prevention dotfiles
#   - ~/Desktop/payloads scaffold, C2-client launchers, storage seed
#   - the AdaptixClient build itself
# The role's `apt ... state=present` for kali-linux-default becomes a
# sub-30s idempotent no-op here — and with nothing left to install
# there's no long async task for the poll loop to wedge on.
set -eu
export DEBIAN_FRONTEND=noninteractive

echo "[bake] apt update..."
apt-get update

# IMPORTANT: NO --no-install-recommends. kali-linux-default is a
# metapackage whose actual tools come in largely via Recommends — the
# kali role installs it with install_recommends:true for the same
# reason. Stripping recommends would bake an empty toolset.
echo "[bake] installing kali-linux-default + XFCE desktop + VNC/xrdp + AdaptixClient build deps..."
apt-get install -y \
  kali-linux-default \
  kali-desktop-xfce \
  dbus-x11 \
  tigervnc-standalone-server tigervnc-common tigervnc-tools \
  xrdp \
  xorgxrdp \
  cmake build-essential git \
  qt6-base-dev qt6-base-private-dev \
  qt6-tools-dev qt6-tools-dev-tools \
  qt6-websockets-dev qt6-multimedia-dev qt6-declarative-dev qt6-5compat-dev \
  libgl1-mesa-dev libssl-dev

# Post-install sanity check — fail the bake LOUDLY if any of the
# remote-desktop binaries didn't land. We've seen a published kali SIG
# image that was apparently baked from an earlier revision of this
# script (without xrdp listed) — deployments hit "X server could not be
# started" because xrdp + xorgxrdp + Xvnc weren't there. Asserting
# binary presence here means a re-bake either succeeds cleanly OR
# fails AT BAKE TIME (where it's easy to see), never silently producing
# a non-functional image.
echo "[bake] verifying remote-desktop binaries are installed ..."
missing=""
for bin in /usr/sbin/xrdp /usr/sbin/xrdp-sesman /usr/bin/Xvnc /usr/bin/Xtigervnc /usr/bin/xfce4-session; do
    [ -x "$bin" ] || missing="$missing $bin"
done
if [ -n "$missing" ]; then
    echo "[bake] FATAL — missing binaries:$missing" >&2
    echo "[bake] dpkg state for xrdp/tigervnc/xfce4:" >&2
    dpkg -l 2>/dev/null | grep -E '^ii .*(xrdp|tigervnc|xfce4)' >&2 || true
    exit 1
fi
echo "[bake] remote-desktop binaries OK ($(xrdp --version 2>&1 | head -1))"

# Enable xrdp + xrdp-sesman at boot so deployed VMs come up with the
# remote-desktop stack already running. The ansible role re-asserts
# this too (idempotent), but enabling at bake-time means a deploy that
# never runs the role (or runs it late) still gets xrdp listening on
# :3389 within ~30 seconds of first boot.
systemctl enable xrdp xrdp-sesman 2>/dev/null || true

# =============================================================================
# Wallpaper + lock-screen + autologin — bake-time, system-wide.
# =============================================================================
# These were previously done by the ansible role on every deploy. Two
# problems with that:
#   1. The role wrote to /home/ranger/.config/... (per-user) BEFORE
#      ranger had ever logged in — chown to ranger is right but
#      xfdesktop wasn't reloaded so the active session kept the Kali
#      default (purple tartan).
#   2. The lock-screen image is rendered by lightdm-greeter from a
#      DIFFERENT path (/etc/alternatives/desktop-background usually),
#      so users saw the CWR image on the greeter but the Kali default
#      on the actual XFCE desktop — exactly the "wallpaper only on
#      lockscreen" symptom.
# Fix: write SYSTEM-WIDE defaults (/etc/xdg + /etc/lightdm) at bake
# time. New users (ranger included) inherit them on first session,
# greeter + desktop use the same image, and the role doesn't have to
# fight xfconfd over an active session.
echo "[bake] installing CWR wallpaper system-wide..."
install -m 0644 -o root -g root /tmp/cwr-wallpaper.png /usr/share/backgrounds/cwr-wallpaper.png
# Some greeters look for /usr/share/desktop-base/active-theme/wallpaper/contents/images/1920x1080.svg
# or /etc/alternatives/desktop-background — symlink both to the CWR image
# so whichever path the active theme uses, it renders the right thing.
mkdir -p /usr/share/backgrounds /etc/alternatives
ln -sf /usr/share/backgrounds/cwr-wallpaper.png /etc/alternatives/desktop-background 2>/dev/null || true
ln -sf /usr/share/backgrounds/cwr-wallpaper.png /etc/alternatives/desktop-grub 2>/dev/null || true
rm -f /tmp/cwr-wallpaper.png

echo "[bake] dropping system-wide XFCE desktop default (wallpaper, screensaver off)..."
mkdir -p /etc/xdg/xfce4/xfconf/xfce-perchannel-xml
# xfce4-desktop.xml — the wallpaper. Listed under EVERY likely monitor
# name (monitor0, monitorVNC-0, monitorscreen) so xfdesktop picks the
# right channel no matter how the X server names the head. xfdesktop
# reads from /etc/xdg/... at FIRST session start for any user who
# doesn't have ~/.config/.../xfce4-desktop.xml yet — i.e. ranger on
# first boot.
cat > /etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-desktop" version="1.0">
  <property name="backdrop" type="empty">
    <property name="screen0" type="empty">
      <property name="monitor0" type="empty">
        <property name="workspace0" type="empty">
          <property name="color-style"  type="int"    value="0"/>
          <property name="image-style"  type="int"    value="5"/>
          <property name="last-image"   type="string" value="/usr/share/backgrounds/cwr-wallpaper.png"/>
        </property>
      </property>
      <property name="monitorVNC-0" type="empty">
        <property name="workspace0" type="empty">
          <property name="color-style"  type="int"    value="0"/>
          <property name="image-style"  type="int"    value="5"/>
          <property name="last-image"   type="string" value="/usr/share/backgrounds/cwr-wallpaper.png"/>
        </property>
      </property>
      <property name="monitorscreen" type="empty">
        <property name="workspace0" type="empty">
          <property name="color-style"  type="int"    value="0"/>
          <property name="image-style"  type="int"    value="5"/>
          <property name="last-image"   type="string" value="/usr/share/backgrounds/cwr-wallpaper.png"/>
        </property>
      </property>
    </property>
  </property>
</channel>
XML

# xfce4-power-manager.xml — kill the blank/lock timers system-wide so
# the desktop never blanks on idle. The role also writes this per-user
# but baking the system default means it's right from session #1.
cat > /etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-power-manager.xml <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-power-manager" version="1.0">
  <property name="xfce4-power-manager" type="empty">
    <property name="blank-on-ac"      type="uint" value="0"/>
    <property name="blank-on-battery" type="uint" value="0"/>
    <property name="dpms-enabled"     type="bool" value="false"/>
    <property name="lock-screen-suspend-hibernate" type="bool" value="false"/>
    <property name="presentation-mode" type="bool" value="true"/>
  </property>
</channel>
XML

# xfce4-screensaver.xml — disable the lock-screen-on-idle entirely.
# Without this the user gets the lock screen after 5 min idle and
# THINKS the box is locked when really they just need to dismiss it.
# Their reported "wallpaper only on lockscreen" symptom likely was
# this: they were always seeing the lock screen because their session
# was getting locked.
cat > /etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-screensaver.xml <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-screensaver" version="1.0">
  <property name="saver" type="empty">
    <property name="enabled" type="bool" value="false"/>
    <property name="mode"    type="int"  value="0"/>
    <property name="idle-activation" type="empty">
      <property name="enabled" type="bool" value="false"/>
      <property name="delay"   type="int"  value="0"/>
    </property>
  </property>
  <property name="lock" type="empty">
    <property name="enabled"    type="bool" value="false"/>
    <property name="saver-activation" type="empty">
      <property name="enabled" type="bool" value="false"/>
    </property>
  </property>
</channel>
XML

# Mask the screensaver service so nothing user-side can re-enable it
# without admin. Belt + suspenders on top of the xfconf XML above.
systemctl mask xfce4-screensaver.service 2>/dev/null || true

echo "[bake] configuring lightdm greeter wallpaper + autologin for 'ranger'..."
# lightdm-gtk-greeter background — the LOGIN/LOCK SCREEN that the user
# was already seeing the wallpaper on, so this is just making sure it
# stays consistent with the desktop.
mkdir -p /etc/lightdm/lightdm-gtk-greeter.conf.d
cat > /etc/lightdm/lightdm-gtk-greeter.conf.d/90-cwr.conf <<'CONF'
[greeter]
background = /usr/share/backgrounds/cwr-wallpaper.png
default-user-image = /usr/share/backgrounds/cwr-wallpaper.png
CONF

# lightdm autologin — `ranger` user is created by cloud-init at deploy
# time (NOT at bake time, image is generalized), so the autologin
# config references the username; lightdm just no-ops if the user
# doesn't exist yet. On first boot post-deploy, ranger exists → lightdm
# logs in automatically → XFCE session starts → CWR wallpaper renders
# (because the system-wide xfce4-desktop.xml above is the default for
# a user without their own per-user override).
mkdir -p /etc/lightdm/lightdm.conf.d
cat > /etc/lightdm/lightdm.conf.d/90-cwr-autologin.conf <<'CONF'
[Seat:*]
autologin-user=ranger
autologin-user-timeout=0
# Default-session-x11 — XFCE only. (Kali ships GNOME + XFCE on some
# images; if the default-session entry is missing, lightdm picks
# alphabetically which can land on gnome-shell.)
autologin-session=xfce
# Don't show the user list on the greeter (which doesn't fire when
# autologin works, but if autologin fails we want a clean fallback).
greeter-hide-users=false
greeter-show-manual-login=true
CONF

# PAM autologin group — lightdm needs ranger to be a member of
# `autologin` (or `nopasswdlogin`) to skip the password prompt. The
# group itself may not exist on Kali by default; create it here, the
# cloud-init `useradd ranger` at deploy time will pick it up via
# /etc/login.defs USERGROUPS_ENAB if we wire it in /etc/group.
groupadd -f autologin
groupadd -f nopasswdlogin

# Wire up so cloud-init's `useradd ranger` at deploy adds it to both
# groups automatically — write a useradd default override.
cat > /etc/default/cwr-autologin-groups <<'CONF'
# Used by /etc/cloud/cloud.cfg.d/99-cwr-autologin.cfg below.
AUTOLOGIN_GROUPS="autologin,nopasswdlogin,sudo"
CONF

# cloud-init hook — append ranger to autologin/nopasswdlogin groups
# right after the user is created. cloud-init's `users` block creates
# ranger with sudo group; we layer on the autologin groups here.
mkdir -p /etc/cloud/cloud.cfg.d
cat > /etc/cloud/cloud.cfg.d/99-cwr-autologin.cfg <<'CFG'
# terra-range: ensure the ranger user gets the autologin PAM groups
# right after cloud-init creates them. lightdm reads /etc/group at
# greeter-start; if the user is in `autologin` lightdm bypasses the
# password prompt entirely (combined with the autologin-user= entry
# in /etc/lightdm/lightdm.conf.d/90-cwr-autologin.conf).
runcmd:
  - [ sh, -c, "id ranger >/dev/null 2>&1 && usermod -aG autologin,nopasswdlogin ranger || true" ]
CFG

echo "[bake] trimming apt cache to keep the SIG image small..."
apt-get clean
rm -rf /var/lib/apt/lists/*

echo "[bake] kali-baseline provisioner complete — image ready for capture."
