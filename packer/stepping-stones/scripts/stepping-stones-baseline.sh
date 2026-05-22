#!/bin/sh
# Bake-time baseline for the Stepping Stones (Cyberveiligheid) image.
#
# Stepping-Stones is a Django + gunicorn + nginx + sqlite app (NOT a
# docker-compose stack despite the name overlap with the upstream
# `stepping-stones-cyberveiligheid` repo, which DOES ship a compose
# file but the cloud-init userdata terra-range uses ignores it in
# favor of the lighter-weight venv+systemd deploy path).
#
# This bake pre-stages the slow parts of that deploy path:
#   - apt: python3-venv + pip + nginx + certbot + a few dev headers
#     for native-extension wheels (psycopg2 / cryptography)
#   - git clone of the repo to /opt/stepping-stones
#   - python3 -m venv .venv + pip install -r requirements.txt (the
#     SLOWEST piece — wheels for cryptography, pillow, etc.)
#   - touch a `.baked` marker so the deploy-time ansible role + cloud-
#     init userdata can skip the heavy install path.
#
# What's NOT done here (these stay deploy-time):
#   - manage.py migrate    (needs SECRET_KEY from per-deploy random_password)
#   - manage.py createsuperuser   (per-deploy operator credentials)
#   - systemd unit install + start  (cloud-init writes the unit + service
#                                    name needs the per-deploy hostname)
#   - certbot --nginx + LE issuance  (needs the per-deploy DNS / IP)
#
# Time saved per deploy (target): ~5-7 min (the pip install on a fresh
# VM is the dominant cost — ~3-5 min for the wheel builds + downloads).
#
# Upstream: https://github.com/stepping-stones-cyberveiligheid/Stepping-Stones
# Final URL students hit at deploy time: http://<vm-private-ip>:8000/
# (or http://<vm>/ via nginx reverse proxy when guacamole_dns + LE done)
#
# History note: an earlier version of this script tried to install
# Docker + pre-pull compose images. That was wrong — the deployed VM
# doesn't use docker. The script was rewritten to match cloud-init's
# venv path (this file). The corresponding ansible role under
# modules/azure/ansible/roles/stepping_stones/ is now a health-verify
# role, NOT a deployer (cloud-init owns deploy, ansible owns repair).
set -eu

SS_REPO="${SS_REPO:-https://github.com/stepping-stones-cyberveiligheid/Stepping-Stones.git}"
SS_DEST="${SS_DEST:-/opt/stepping-stones}"

echo "[ss-bake] apt-get update + upgrade ..."
export DEBIAN_FRONTEND=noninteractive
apt-get -y update
apt-get -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" upgrade

# Base packages — python venv + nginx + certbot + the libs Stepping-Stones'
# pip requirements need to build wheels for cleanly on a fresh VM:
#
#   - python3-venv        : `python3 -m venv` support
#   - python3-pip         : bootstrap pip outside the venv (only used to
#                            install the venv-managed pip itself; the
#                            venv has its own pip thereafter)
#   - python3-dev         : Python.h for native-extension builds
#   - build-essential     : gcc + make for wheel builds
#   - libpq-dev           : psycopg2 (postgres adapter; some configs need
#                            it even if the default backend is sqlite —
#                            requirements.txt pins psycopg2 unconditionally)
#   - libssl-dev libffi-dev : cryptography wheel build
#   - libjpeg-dev zlib1g-dev : pillow wheel build (image attachments)
#   - libxml2-dev libxslt1-dev : lxml wheel build (report rendering)
#   - nginx + certbot + python3-certbot-nginx : reverse-proxy + LE TLS
#   - git curl wget jq    : repo fetch + deploy-time misc
echo "[ss-bake] base packages (python venv + django build deps + nginx + certbot) ..."
apt-get -y install --no-install-recommends \
    ca-certificates \
    curl \
    git \
    wget \
    jq \
    openssl \
    python3 \
    python3-venv \
    python3-pip \
    python3-dev \
    build-essential \
    libpq-dev \
    libssl-dev \
    libffi-dev \
    libjpeg-dev \
    zlib1g-dev \
    libxml2-dev \
    libxslt1-dev \
    nginx \
    certbot \
    python3-certbot-nginx

echo "[ss-bake] cloning Stepping-Stones to ${SS_DEST} ..."
if [ ! -d "${SS_DEST}/.git" ]; then
    # Full clone (not --depth 1) so the ansible repair pass can inspect
    # git log if a hotfix pin is needed later. Stepping-Stones is a
    # small repo — the full history is < 50 MB.
    git clone "${SS_REPO}" "${SS_DEST}"
fi
HEAD=$(cd "${SS_DEST}" && git rev-parse --short HEAD 2>/dev/null || echo unknown)
echo "[ss-bake]   Stepping-Stones HEAD: ${HEAD}"

# --- Create venv + install requirements ----------------------------------
#
# The SLOWEST part of a Stepping-Stones first-boot is `pip install -r
# requirements.txt`. The package list pulls ~50 packages; cryptography +
# pillow + lxml are wheel-built from source on Debian's ARM64 images
# (which terra-range doesn't currently target, but the deps are the
# same on amd64) — those three alone take 2-3 min on a fresh n2-standard-2.
#
# Baking the venv means deploy-time becomes "use the venv, run migrate
# + createsuperuser, start gunicorn" — < 60 sec on a baked image.
echo "[ss-bake] creating venv at ${SS_DEST}/.venv ..."
if [ ! -d "${SS_DEST}/.venv" ]; then
    python3 -m venv "${SS_DEST}/.venv"
fi

echo "[ss-bake] upgrading pip + setuptools + wheel inside the venv ..."
"${SS_DEST}/.venv/bin/pip" install --upgrade pip setuptools wheel \
    2>&1 | tail -5

REQ="${SS_DEST}/requirements.txt"
if [ -f "${REQ}" ]; then
    echo "[ss-bake] pip install -r requirements.txt (~3-5 min for the cryptography + pillow + lxml wheels) ..."
    "${SS_DEST}/.venv/bin/pip" install --no-cache-dir -r "${REQ}" 2>&1 | tail -10 \
        || echo "[ss-bake]   WARN: pip install failed — deploy-time will retry"
else
    echo "[ss-bake]   WARN: ${REQ} not found in clone — Stepping-Stones repo layout may have changed"
fi

# Fix ownership of the venv + repo so the deploy-time `ranger` user
# (created by cloud-init) can write its sqlite db + collect static files
# under the same tree without sudo. cloud-init's users: block creates
# ranger with uid 1000 on most Debian images; chown after the venv
# install so the python-managed bytecode is owned correctly.
echo "[ss-bake] chowning ${SS_DEST} to uid:gid 1000:1000 (matches the ranger user cloud-init will create) ..."
chown -R 1000:1000 "${SS_DEST}" || echo "  (chown failed, deploy-time will fix)"

# Marker for the deploy-time ansible role + cloud-init userdata to
# detect a baked image and skip the apt/clone/venv path. Same shape as
# /opt/mythic/.baked and /opt/adaptix/.baked.
{
    echo "${HEAD}"
    date
    echo "venv: ${SS_DEST}/.venv"
    echo "requirements: ${REQ}"
} > "${SS_DEST}/.baked"
echo "[ss-bake] marker ${SS_DEST}/.baked written"

echo "[ss-bake] cleaning apt cache + pip cache (shrinks captured image) ..."
apt-get clean
rm -rf /var/lib/apt/lists/*
rm -rf /root/.cache/pip /home/*/.cache/pip 2>/dev/null || true

echo "[ss-bake] baseline complete."
echo "[ss-bake] venv site-packages summary:"
"${SS_DEST}/.venv/bin/pip" list --format=columns 2>/dev/null | head -20 || true
