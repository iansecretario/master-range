#!/bin/sh
# Bake-time baseline for the Debian 12 redirector image.
#
# Installs everything the c2-redirector ansible role + userdata need
# pre-loaded so deploy-time first boot is just the per-redirector
# config (cert install, upstream conf, nginx reload).
set -eu

echo "[redirector-bake] apt-get update + upgrade ..."
export DEBIAN_FRONTEND=noninteractive
apt-get -y update
apt-get -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" upgrade

echo "[redirector-bake] installing base packages + nginx ..."
apt-get -y install --no-install-recommends \
    ca-certificates \
    curl \
    jq \
    openssl \
    python3 \
    python3-yaml \
    nginx \
    nginx-extras \
    logrotate \
    rsync \
    gnupg \
    apt-transport-https

# Stop nginx — deploy-time renders the conf and (re)starts. We don't
# want the image to ship a service running on default-conf during the
# first-boot window before terraform's user_data lays the real conf.
echo "[redirector-bake] disabling nginx auto-start (deploys re-enable) ..."
systemctl disable nginx
systemctl stop nginx || true

# Stub out the default nginx site so packer's nginx start during install
# leaves a clean state. Deploy-time conf replaces this entirely.
rm -f /etc/nginx/sites-enabled/default

echo "[redirector-bake] cleaning apt cache (shrinks captured image) ..."
apt-get clean
rm -rf /var/lib/apt/lists/*

echo "[redirector-bake] baseline complete."
