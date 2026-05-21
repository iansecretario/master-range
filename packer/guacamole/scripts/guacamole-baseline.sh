#!/bin/sh
# Bake-time baseline for the Guacamole image (Ubuntu 22.04).
# Pre-installs everything the per-deploy userdata + LE bootstrap
# would otherwise have to install on first boot.
set -eu

echo "[guac-bake] apt-get update + upgrade ..."
export DEBIAN_FRONTEND=noninteractive
apt-get -y update
apt-get -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" upgrade

echo "[guac-bake] base packages ..."
apt-get -y install --no-install-recommends \
    ca-certificates \
    curl \
    jq \
    gnupg \
    apt-transport-https \
    python3 \
    python3-pip \
    rsync \
    openssl

echo "[guac-bake] installing Docker via get.docker.com ..."
# Same path as the deploy-time userdata uses. Pre-baking means deploys
# skip the ~1-2 min docker-ce install.
curl -fsSL https://get.docker.com | sh
apt-get -y install --no-install-recommends docker-compose-plugin

echo "[guac-bake] installing nginx + certbot stack ..."
# nginx for TLS termination + reverse proxy to guacamole:8080.
# certbot for LE cert issuance (HTTP-01 against the per-deploy hostname).
# python3-certbot-dns-azure for the wildcard / DNS-01 path (used by
# the per-range Guac when wildcard cert is configured).
apt-get -y install --no-install-recommends \
    nginx \
    certbot \
    python3-certbot \
    python3-certbot-nginx \
    python3-certbot-dns-azure

# Stop nginx — deploy-time renders the per-deploy vhost (with the
# hostname + cert paths) and starts it explicitly. We don't want the
# image to ship with the default nginx serving "Welcome to nginx!" on
# port 80 during the first-boot config window.
systemctl disable nginx
systemctl stop nginx || true
rm -f /etc/nginx/sites-enabled/default

echo "[guac-bake] installing Java runtime (for cwr-branding.jar build) ..."
# The per-deploy guacamole role builds a cwr-branding.jar that overrides
# the login-page wordmark ("APACHE GUACAMOLE" → operator's chosen
# title). The build uses `jar` from openjdk-17-jdk-headless. Pre-baking
# avoids ~30 sec of apt install per deploy.
apt-get -y install --no-install-recommends openjdk-17-jdk-headless

echo "[guac-bake] pre-pulling Guacamole + Postgres docker images ..."
# These are the four images the per-range Guac userdata's docker-compose.yml
# references. Pre-pulling saves ~2-4 min per deploy (the slowest network
# step on the Guac box). Versions match what guacamole.sh hardcodes today.
# If the userdata bumps to a newer version, re-bake to refresh.
docker pull guacamole/guacd:1.5.5    || echo "  (guacd pull failed — deploy will retry)"
docker pull guacamole/guacamole:1.5.5 || echo "  (guacamole pull failed — deploy will retry)"
docker pull postgres:14               || echo "  (postgres pull failed — deploy will retry)"

echo "[guac-bake] cleaning apt cache (shrinks captured image) ..."
apt-get clean
rm -rf /var/lib/apt/lists/*

echo "[guac-bake] baseline complete."
echo "[guac-bake] cached docker images:"
docker image ls 2>/dev/null | head -10
