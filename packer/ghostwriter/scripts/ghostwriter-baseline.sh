#!/bin/sh
# Bake-time baseline for the Ghostwriter reporting/oplog image.
#
# Ghostwriter (SpecterOps) ships a pre-built `ghostwriter-cli-linux`
# binary in its repo root — NO Go compile needed. Its docker stack is
# locally-BUILT (every image has a `build:` block, not `image:` from a
# registry), so the heaviest deploy-time costs are:
#   1. apt/Docker install                    ~1-2 min
#   2. git clone of Ghostwriter              ~30 sec
#   3. Pulling base FROM images              ~2-3 min
#   4. `docker compose build`                ~10-15 min  <-- the big one
#
# This bake folds 1-4 into the image so a deploy-time
# `ghostwriter-cli-linux install` just renders .env + `docker compose up`.
#
# Marker file: /opt/ghostwriter/.baked  (ansible role probes this and
# skips the heavy install path).
set -eu

GHOSTWRITER_REPO=https://github.com/GhostManager/Ghostwriter.git

echo "[ghostwriter-bake] apt-get update + upgrade ..."
export DEBIAN_FRONTEND=noninteractive
apt-get -y update
apt-get -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" upgrade

echo "[ghostwriter-bake] base packages ..."
apt-get -y install --no-install-recommends \
    ca-certificates \
    curl \
    git \
    wget \
    jq \
    openssl \
    python3 \
    python3-yaml \
    gnupg \
    apt-transport-https

echo "[ghostwriter-bake] installing Docker via get.docker.com ..."
# get.docker.com installs docker-ce + cli + buildx + compose-plugin in
# one shot — same path the deploy userdata + every other terra-range
# c2 role uses, so we stay consistent across images.
curl -fsSL https://get.docker.com | sh
apt-get -y install --no-install-recommends docker-compose-plugin

# Ghostwriter doesn't need Go (CLI is pre-compiled), so we deliberately
# skip the Go install dance that mythic/adaptix bakes do. Keeps the
# captured image ~150 MB smaller.

echo "[ghostwriter-bake] cloning Ghostwriter to /opt/ghostwriter ..."
if [ ! -d /opt/ghostwriter ]; then
    git clone --depth 1 "$GHOSTWRITER_REPO" /opt/ghostwriter
fi
HEAD=$(cd /opt/ghostwriter && git rev-parse --short HEAD 2>/dev/null || echo unknown)
echo "[ghostwriter-bake]   Ghostwriter HEAD: $HEAD"

# The pre-built CLI ships in the repo root. Make sure it's executable
# (git preserves the mode but be defensive).
if [ -f /opt/ghostwriter/ghostwriter-cli-linux ]; then
    chmod +x /opt/ghostwriter/ghostwriter-cli-linux
    echo "[ghostwriter-bake]   ghostwriter-cli-linux present:"
    /opt/ghostwriter/ghostwriter-cli-linux version 2>&1 | head -5 || true
else
    echo "[ghostwriter-bake]   WARN: ghostwriter-cli-linux missing — repo layout changed?"
fi

# -----------------------------------------------------------------------------
# Pre-pull base FROM images referenced by Ghostwriter's production
# Dockerfiles. These won't change often and shave ~2-3 min off the
# subsequent `docker compose build`.
#
# Source: each compose/production/<svc>/Dockerfile `FROM` line, as of
# the master branch on 2026-05.  If Ghostwriter bumps a base, re-bake.
# Pull failures are non-fatal — deploy-time build will fetch what's missing.
# -----------------------------------------------------------------------------
echo "[ghostwriter-bake] pre-pulling Ghostwriter base FROM images ..."
for img in \
    node:25.9.0-alpine3.23 \
    python:3.10.20-alpine3.23 \
    postgres:16.4 \
    nginx:1.23.3-alpine \
    redis:6-alpine \
    hasura/graphql-engine:v2.39.1.cli-migrations-v3 ; do
    echo "  pulling $img"
    docker pull "$img" 2>&1 | tail -2 || echo "    (pull failed for $img — deploy-time retry)"
done

# -----------------------------------------------------------------------------
# Pre-BUILD the Ghostwriter docker images at bake time. This is the
# single biggest deploy-time saving (~10-15 min of `docker compose build`).
#
# ghostwriter-cli's `containers build` reads production.yml + .env and
# runs `docker compose build` for every service. We need a placeholder
# .env to satisfy variable interpolation; the real .env will be regenerated
# at deploy time by `ghostwriter-cli install` so anything we put here is
# throw-away. We rely on the same template the CLI uses — but if the CLI
# refuses to build without `install` having run first, we fall back to a
# direct `docker compose -f production.yml build`.
# -----------------------------------------------------------------------------
echo "[ghostwriter-bake] pre-building Ghostwriter docker images ..."
cd /opt/ghostwriter

# Try the CLI path first (preferred — keeps bake symmetric with deploy).
# `containers build` is documented in the CLI subcommand list.
if [ -x /opt/ghostwriter/ghostwriter-cli-linux ]; then
    # The CLI needs SOMETHING in .env or it'll fail variable interpolation
    # during build. Generate a throwaway .env via `install --help` is not
    # an option (install would also bring up containers), so we minimally
    # seed the env vars production.yml references. Real `install` will
    # rewrite this file at deploy time.
    if [ ! -f .env ]; then
        echo "[ghostwriter-bake]   seeding throwaway .env for build phase ..."
        cat > .env <<'EOF'
# Placeholder .env created at bake time. Deploy-time `ghostwriter-cli
# install` will rewrite this file with real per-deploy secrets.
USE_DOCKER=yes
IPYTHONDIR=/app/.ipython
SPACY_MODEL=en_core_web_sm
SPACY_DOWNLOAD_MISSING_MODEL=0
POSTGRES_DB=ghostwriter
POSTGRES_USER=ghostwriter
POSTGRES_PASSWORD=bake-placeholder
POSTGRES_HOST=postgres
POSTGRES_PORT=5432
DJANGO_SETTINGS_MODULE=config.settings.production
DJANGO_SECRET_KEY=bake-placeholder
DJANGO_JWT_SECRET_KEY=bake-placeholder
DJANGO_ALLOWED_HOSTS=localhost
DJANGO_ADMIN_URL=admin/
DJANGO_ACCOUNT_ALLOW_REGISTRATION=False
DJANGO_ACCOUNT_EMAIL_VERIFICATION=none
DJANGO_SOCIAL_ACCOUNT_ALLOW_REGISTRATION=False
DJANGO_SOCIAL_ACCOUNT_DOMAIN_ALLOWLIST=
DJANGO_SOCIAL_ACCOUNT_LOGIN_ON_GET=False
DJANGO_MFA_ALWAYS_REVEAL_BACKUP_TOKENS=False
DJANGO_DATE_FORMAT=DATE_FORMAT
DJANGO_CSRF_COOKIE_SECURE=True
DJANGO_CSRF_TRUSTED_ORIGINS=
DJANGO_SECURE_SSL_REDIRECT=True
DJANGO_SESSION_COOKIE_AGE=1800
DJANGO_SESSION_COOKIE_SECURE=True
DJANGO_SESSION_EXPIRE_AT_BROWSER_CLOSE=True
DJANGO_SESSION_SAVE_EVERY_REQUEST=True
DJANGO_QCLUSTER_NAME=ghostwriter_q
DJANGO_WEB_CONCURRENCY=4
DJANGO_SUPERUSER_USERNAME=admin
DJANGO_SUPERUSER_EMAIL=admin@ghostwriter.local
DJANGO_SUPERUSER_PASSWORD=bake-placeholder
DJANGO_MAILGUN_API_KEY=
DJANGO_MAILGUN_DOMAIN=
HASURA_GRAPHQL_ACTION_SECRET=bake-placeholder
HASURA_GRAPHQL_ADMIN_SECRET=bake-placeholder
HASURA_GRAPHQL_SERVER_HOSTNAME=graphql_engine
REDIS_HOST=redis
REDIS_PORT=6379
HEALTHCHECK_INTERVAL=30s
HEALTHCHECK_TIMEOUT=10s
HEALTHCHECK_RETRIES=3
HEALTHCHECK_START=120s
HEALTHCHECK_DISK_USAGE_MAX=80
HEALTHCHECK_MEM_MIN=100
GHOSTWRITER_MAX_FILE_SIZE=10485760
EOF
    fi

    # `containers build` calls docker compose build under the hood. We
    # don't `up` here — we just want the image layers cached. Time out
    # after 25 min in case a base image stalls.
    timeout 1500 /opt/ghostwriter/ghostwriter-cli-linux containers build 2>&1 | tail -30 \
        || echo "[ghostwriter-bake]   CLI build path failed, falling back to direct compose build ..."
fi

# Fallback: direct docker compose build, same end result. Either path
# leaves the same layered images in the local docker cache.
if ! docker image ls --format '{{.Repository}}' | grep -q '^ghostwriter_production_'; then
    echo "[ghostwriter-bake]   direct: docker compose -f production.yml build ..."
    timeout 1500 docker compose -f /opt/ghostwriter/production.yml build 2>&1 | tail -30 \
        || echo "[ghostwriter-bake]   compose build failed — deploy-time will retry"
fi

# Marker so deploy-time ansible role can detect baked image + skip the
# Docker install / git clone / docker compose build phase. HEAD pins
# the exact Ghostwriter commit baked in — useful for debugging when a
# later upstream change drifts.
echo "$HEAD" > /opt/ghostwriter/.baked
date >> /opt/ghostwriter/.baked
echo "[ghostwriter-bake] marker /opt/ghostwriter/.baked written"

echo "[ghostwriter-bake] cleaning apt cache (shrinks captured image) ..."
apt-get clean
rm -rf /var/lib/apt/lists/*

echo "[ghostwriter-bake] baseline complete."
echo "[ghostwriter-bake] cached docker images:"
docker image ls 2>/dev/null | head -25
