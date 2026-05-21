#!/bin/sh
# terra-range — Kali MINIMAL pre-bake provisioner.
#
# Runs ONCE during `./range bake kali-minimal`. Same shape as
# kali-baseline.sh, but installs a CURATED, offensive-focused toolset
# instead of the full kali-linux-default metapackage:
#   - kali-linux-core    : the minimal Kali base. NOTE there is no
#                          "kali-linux-minimal" metapackage — `core` is
#                          Kali's minimal base. It carries no toolset on
#                          its own; the kali-tools-* groups below do.
#   - kali-tools-*       : a hand-picked set of tool groups focused on
#                          offensive security / VAPT / red team —
#                          top10, information-gathering, vulnerability,
#                          web, exploitation, passwords,
#                          post-exploitation, windows-resources,
#                          sniffing-spoofing. Deliberately SKIPS
#                          forensics / reverse-engineering / wireless /
#                          reporting / social-engineering / etc. —
#                          `apt install kali-tools-<group>` on demand
#                          if a given engagement needs them.
#   - kali-desktop-xfce  : XFCE desktop + dbus-x11. The operator still
#                          RDPs into this box — the GUI is required.
#   - tigervnc + xrdp    : the remote-desktop stack
#   - AdaptixClient Qt6 build deps — identical to kali-baseline.sh, so
#     the per-deploy `make` is the only AdaptixClient cost left.
#
# Everything deploy-SPECIFIC stays in the kali ansible role and runs
# fast against this baked image (xrdp.ini/sesman.ini patches,
# autorun=Xvnc, ~/.xsession + screensaver dotfiles, ~/Desktop/payloads
# scaffold + C2-client launchers, the AdaptixClient build itself).
set -eu
export DEBIAN_FRONTEND=noninteractive

echo "[bake] apt update..."
apt-get update

# IMPORTANT: NO --no-install-recommends. The kali-tools-* groups pull
# their actual tools in via Depends/Recommends — stripping recommends
# would bake a half-empty toolset. Same reasoning as kali-baseline.sh's
# kali-linux-default install.
echo "[bake] installing kali-linux-core + curated offensive kali-tools-* + XFCE desktop + VNC/xrdp + AdaptixClient build deps..."
apt-get install -y \
  kali-linux-core \
  kali-tools-top10 \
  kali-tools-information-gathering \
  kali-tools-vulnerability \
  kali-tools-web \
  kali-tools-exploitation \
  kali-tools-passwords \
  kali-tools-post-exploitation \
  kali-tools-windows-resources \
  kali-tools-sniffing-spoofing \
  kali-desktop-xfce \
  dbus-x11 \
  tigervnc-standalone-server tigervnc-common tigervnc-tools \
  xrdp \
  cmake build-essential git \
  qt6-base-dev qt6-base-private-dev \
  qt6-tools-dev qt6-tools-dev-tools \
  qt6-websockets-dev qt6-multimedia-dev qt6-declarative-dev qt6-5compat-dev \
  libgl1-mesa-dev libssl-dev

echo "[bake] trimming apt cache to keep the SIG image small..."
apt-get clean
rm -rf /var/lib/apt/lists/*

echo "[bake] kali-minimal-baseline provisioner complete — image ready for capture."
