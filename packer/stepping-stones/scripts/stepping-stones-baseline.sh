#!/bin/sh
# Bake-time baseline for the Stepping Stones (Cyberveiligheid) image.
#
# Mirrors the structure of packer/mythic/scripts/mythic-baseline.sh: install
# Docker + compose plugin + supporting tooling, clone the upstream repo,
# pre-pull every container image referenced by the project's
# docker-compose.yml, and drop a /opt/stepping-stones/.baked marker so the
# Ansible role can short-circuit the slow install at deploy time.
#
# Upstream: https://github.com/stepping-stones-cyberveiligheid/Stepping-Stones
# Final URL students hit at deploy time: http://<vm-private-ip>:8000/
#
# Time saved per deploy (target): ~5-8 min (apt + docker install ~1-2 min,
# git clone ~10 s, compose image pulls ~3-5 min depending on egress).
set -eu

SS_REPO="${SS_REPO:-https://github.com/stepping-stones-cyberveiligheid/Stepping-Stones.git}"
SS_DEST="${SS_DEST:-/opt/stepping-stones}"

echo "[ss-bake] apt-get update + upgrade ..."
export DEBIAN_FRONTEND=noninteractive
apt-get -y update
apt-get -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" upgrade

echo "[ss-bake] base packages (nginx + certbot + helpers) ..."
# Docker is installed SEPARATELY via get.docker.com below — NOT via
# apt's docker.io. Reasons:
#   1. `docker-compose-plugin` is ONLY available in Docker Inc.'s apt
#      repo (download.docker.com), NOT in Debian's main repos. Trying
#      to apt-install it on stock Debian 12 fails with
#      "No package matching 'docker-compose-plugin' is available".
#   2. The mythic + ghostwriter bakes also use get.docker.com — using
#      it here keeps the install path identical → fewer surprises.
#   3. docker.io (Debian's CE-equivalent) DOES exist and would work
#      for the engine, but it ships docker-compose-v2 under a different
#      binary name and we'd have to alias around it. Not worth the
#      complexity.
apt-get -y install --no-install-recommends \
    ca-certificates \
    curl \
    git \
    wget \
    jq \
    openssl \
    gnupg \
    apt-transport-https \
    nginx \
    certbot \
    python3-certbot-nginx

echo "[ss-bake] installing Docker via get.docker.com (includes docker-compose-plugin) ..."
curl -fsSL https://get.docker.com | sh

echo "[ss-bake] enable docker.service ..."
systemctl enable --now docker || true

echo "[ss-bake] cloning Stepping-Stones to ${SS_DEST} ..."
if [ ! -d "${SS_DEST}/.git" ]; then
    # Full clone (not --depth 1) so the deploy-time Ansible role can
    # inspect git log if a hotfix pin is needed later. Stepping-Stones
    # is a small repo — the full history is < 50 MB.
    git clone "${SS_REPO}" "${SS_DEST}"
fi
HEAD=$(cd "${SS_DEST}" && git rev-parse --short HEAD 2>/dev/null || echo unknown)
echo "[ss-bake]   Stepping-Stones HEAD: ${HEAD}"

# --- pre-pull every docker image referenced by the compose stack ----
#
# Stepping-Stones' canonical layout puts a docker-compose.yml at the
# repo root. We walk it (plus any auxiliary compose files under the
# tree — some forks split out a separate compose.override.yml for
# postgres/redis/etc.) and pull each `image:` reference. We also walk
# any Dockerfiles' `FROM` lines so that build-from-source services
# have their base layers cached.
#
# Same defensive shape as packer/mythic/scripts/mythic-baseline.sh —
# parsing upstream compose files is fragile, so failures are non-fatal:
# `docker compose up` at deploy time will fetch anything we missed.
echo "[ss-bake] enumerating docker images from compose + Dockerfiles ..."
ss_images=$(
  {
    find "${SS_DEST}" -maxdepth 4 -type f \
        \( -name 'docker-compose*.yml' -o -name 'docker-compose*.yaml' \
           -o -name 'compose*.yml' -o -name 'compose*.yaml' \) \
        2>/dev/null \
      | xargs -r grep -hE '^\s*image:\s*' 2>/dev/null \
      | sed -E 's/^\s*image:\s*//; s/^["'"'"']//; s/["'"'"']$//; s/\s+#.*$//' \
      | grep -vE '^\$\{|^\s*$'
    find "${SS_DEST}" -maxdepth 4 -type f -name 'Dockerfile*' 2>/dev/null \
      | xargs -r grep -hE '^\s*FROM\s+' 2>/dev/null \
      | awk '{print $2}' \
      | grep -vE '^scratch$|^\$\{'
  } | sort -u
)

# Fallback: if the repo layout changed and we found zero images, still
# pre-pull the well-known dependencies a Django + postgres stack uses,
# so the baked image isn't useless. These are the same versions
# Stepping-Stones has historically pinned.
if [ -z "${ss_images}" ]; then
    echo "[ss-bake]   WARN: no images discovered in compose/Dockerfile — falling back to stock set"
    ss_images=$(printf '%s\n' \
        postgres:15 \
        postgres:14 \
        redis:7 \
        nginx:1.25 \
        python:3.12-slim)
fi

echo "[ss-bake] pre-pulling images:"
printf '%s\n' "${ss_images}" | sed 's/^/  - /'
printf '%s\n' "${ss_images}" | while IFS= read -r img; do
    [ -z "${img}" ] && continue
    echo "[ss-bake] pulling ${img}"
    docker pull "${img}" 2>&1 | tail -2 || echo "  (pull failed for ${img} — deploy-time retry)"
done

# If the compose stack has any service that builds from source
# (build: . blocks), do an offline `docker compose build` so the
# resulting images are baked in too. Best-effort; non-fatal.
COMPOSE_FILE=""
for f in docker-compose.yml docker-compose.yaml compose.yml compose.yaml; do
    [ -f "${SS_DEST}/${f}" ] && { COMPOSE_FILE="${SS_DEST}/${f}"; break; }
done
if [ -n "${COMPOSE_FILE}" ] && grep -qE '^\s*build:' "${COMPOSE_FILE}" 2>/dev/null; then
    echo "[ss-bake] pre-building local compose services from ${COMPOSE_FILE} ..."
    ( cd "${SS_DEST}" && docker compose -f "${COMPOSE_FILE}" build 2>&1 | tail -20 ) \
        || echo "[ss-bake]   (compose build failed — deploy-time retry)"
fi

# Marker so the Ansible role can detect a baked image and skip the
# Docker install / git clone / image pull phases. Same shape as
# /opt/mythic/.baked.
{
    echo "${HEAD}"
    date
} > "${SS_DEST}/.baked"
echo "[ss-bake] marker ${SS_DEST}/.baked written"

echo "[ss-bake] cleaning apt cache (shrinks captured image) ..."
apt-get clean
rm -rf /var/lib/apt/lists/*

echo "[ss-bake] baseline complete."
echo "[ss-bake] cached docker images:"
docker image ls 2>/dev/null | head -20
