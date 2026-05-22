#!/bin/sh
# Bake-time baseline for the Mythic teamserver image.
#
# Mirrors the heavy-install portion of modules/azure/userdata/c2-mythic.sh:
# install Docker + Go + clone Mythic + build mythic-cli + pre-pull
# every docker image the Mythic stack references.
set -eu

GO_VER=1.22.7
MYTHIC_REPO=https://github.com/its-a-feature/Mythic.git
FILEBEAT_VER=8.13.4

echo "[mythic-bake] apt-get update + upgrade ..."
export DEBIAN_FRONTEND=noninteractive
apt-get -y update
apt-get -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" upgrade

echo "[mythic-bake] base packages ..."
apt-get -y install --no-install-recommends \
    ca-certificates \
    curl \
    git \
    wget \
    make \
    jq \
    openssl \
    python3 \
    python3-yaml \
    rsync \
    gnupg \
    apt-transport-https

echo "[mythic-bake] installing Go ${GO_VER} under /usr/local/go ..."
# mythic-cli's `make` target needs Go 1.21+ (Debian 12's apt golang
# 1.19 is too old). Match the version pin from c2-mythic.sh.
if ! /usr/local/go/bin/go version 2>/dev/null | grep -q "go${GO_VER}"; then
    curl -fsSL "https://go.dev/dl/go${GO_VER}.linux-amd64.tar.gz" -o /tmp/go.tgz
    rm -rf /usr/local/go && tar -C /usr/local -xzf /tmp/go.tgz
    rm -f /tmp/go.tgz
    ln -sf /usr/local/go/bin/go    /usr/local/bin/go
    ln -sf /usr/local/go/bin/gofmt /usr/local/bin/gofmt
fi
go version

echo "[mythic-bake] installing Docker via get.docker.com ..."
curl -fsSL https://get.docker.com | sh
apt-get -y install --no-install-recommends docker-compose-plugin

echo "[mythic-bake] cloning Mythic to /opt/mythic ..."
if [ ! -d /opt/mythic ]; then
    git clone --depth 1 "$MYTHIC_REPO" /opt/mythic
fi
HEAD=$(cd /opt/mythic && git rev-parse --short HEAD 2>/dev/null || echo unknown)
echo "[mythic-bake]   Mythic HEAD: $HEAD"

echo "[mythic-bake] building mythic-cli (Go binary, ~3-5 min) ..."
cd /opt/mythic
make 2>&1 | tail -20 || echo "[mythic-bake] make exited non-zero — mythic-cli may still be built; verifying"
ls -la /opt/mythic/mythic-cli 2>/dev/null || echo "  WARN: /opt/mythic/mythic-cli not found"

echo "[mythic-bake] pre-pulling base Mythic docker images ..."
# Mythic's docker-compose stack uses these core images. We pull each
# explicitly so the first deploy doesn't have to fetch ~5-8 GB.
# Mythic upstream may bump versions — re-bake after a major Mythic
# upgrade to refresh the cache. Failures are non-fatal (deploy-time
# `docker compose up` will pull what's missing).
for img in \
    postgres:14 \
    mythicagents/mythic_react:0.0.31 \
    itsafeaturemythic/mythic_server:0.6.5 \
    itsafeaturemythic/mythic_nginx:0.0.13 \
    itsafeaturemythic/mythic_documentation:0.0.10 \
    itsafeaturemythic/mythic_rabbitmq:0.0.5 \
    itsafeaturemythic/mythic_graphql:0.0.10 ; do
    echo "  pulling $img"
    docker pull "$img" 2>&1 | tail -2 || echo "    (pull failed for $img — deploy-time retry)"
done

# Also pre-pull every image referenced under
# /opt/mythic/InstalledServices/ (these are C2 profiles + agents that
# Mythic ships pre-installed). Parsing their docker-compose.yml +
# Dockerfile.* refs is fragile; instead we walk for `FROM` lines + any
# explicit `image:` keys.
echo "[mythic-bake] pre-pulling InstalledServices images ..."
extra_images=$(
  {
    find /opt/mythic/InstalledServices -type f -name 'Dockerfile*' 2>/dev/null \
      | xargs -r grep -h '^FROM' 2>/dev/null \
      | awk '{print $2}'
    find /opt/mythic/InstalledServices -type f \( -name 'docker-compose*.yml' -o -name 'docker-compose*.yaml' \) 2>/dev/null \
      | xargs -r grep -h '^\s*image:' 2>/dev/null \
      | awk '{print $2}' | tr -d '"'
  } | sort -u
)
if [ -n "$extra_images" ]; then
    echo "$extra_images" | while read -r img; do
        [ -z "$img" ] && continue
        # Skip already-pulled core images
        case "$img" in postgres:14|mythicagents/*|itsafeaturemythic/*) ;; esac
        echo "  pulling $img"
        docker pull "$img" 2>&1 | tail -2 || echo "    (pull failed for $img — deploy-time retry)"
    done
fi

echo "[mythic-bake] pre-installing filebeat ${FILEBEAT_VER} .deb ..."
curl -fsSL "https://artifacts.elastic.co/downloads/beats/filebeat/filebeat-${FILEBEAT_VER}-amd64.deb" \
    -o /tmp/filebeat.deb \
    && dpkg -i /tmp/filebeat.deb \
    && rm -f /tmp/filebeat.deb \
    || echo "  (filebeat install failed — deploy-time will retry)"

# =============================================================================
# Pre-install Mythic's extra payload types + C2 profiles at bake time.
# =============================================================================
# WHY: the mythic ansible role installs 5 services on every deploy via
# `mythic-cli install github <url>` (see roles/mythic/defaults/main.yml).
# Each `install` does a git clone + docker build of a per-service container
# image, taking 2-10 min depending on the service. With 5 services, that's
# 10-50 min of slow async work the role had to do on every deploy.
#
# Baking those installs here means /opt/mythic/InstalledServices/<name>
# exists in the published SIG image, the per-service docker images are
# pre-built in the local docker cache, and the role's
# `stat /opt/mythic/InstalledServices/<name>` probe returns exists →
# skips the install loop entirely. Cuts mythic deploy time by ~30-45 min.
#
# Constraint: `mythic-cli install` requires the mythic stack to be RUNNING
# (it POSTs to the Hasura GraphQL admin endpoint). We start the stack,
# install, then stop it. ~5-10 min of extra bake time for a much bigger
# deploy-time saving.
#
# The list below MUST stay in sync with mythic_extra_services in
# modules/azure/ansible/roles/mythic/defaults/main.yml. Update both when
# adding a new payload/profile.
MYTHIC_EXTRAS="\
apfell    https://github.com/MythicAgents/apfell
apollo    https://github.com/MythicAgents/apollo
poseidon  https://github.com/MythicAgents/poseidon
http      https://github.com/MythicC2Profiles/http
websocket https://github.com/MythicC2Profiles/websocket"

echo "[mythic-bake] starting mythic stack so we can mythic-cli install the 5 extras ..."
cd /opt/mythic
if ! ./mythic-cli start 2>&1 | tail -20; then
    echo "  WARN: mythic-cli start failed at bake time — skipping extras install."
    echo "  WARN: deploy-time mythic role will install them (adds ~30-45 min per deploy)."
else
    # Mythic services typically need 60-120 sec after `start` for the
    # Hasura endpoint to be reachable. Poll the GraphQL endpoint until it
    # responds with a 401 (unauthenticated GET — means it's UP), or give
    # up after 5 min.
    echo "[mythic-bake] waiting for mythic_graphql to come up (max 5 min) ..."
    for i in $(seq 1 60); do
        # Hasura's GraphQL endpoint returns 200 for OPTIONS or 401/200
        # for unauthenticated GET. Either is "up".
        if curl -sSf -o /dev/null --max-time 3 http://127.0.0.1:8080/ 2>/dev/null \
           || curl -sS  -o /dev/null --max-time 3 http://127.0.0.1:8080/ 2>/dev/null | head -1 | grep -qE '40[0-9]|200'; then
            echo "  [mythic-bake]   graphql reachable on attempt $i"
            break
        fi
        sleep 5
        [ "$i" -eq 60 ] && echo "  WARN: graphql never came up; extras may fail"
    done

    echo "[mythic-bake] installing extra payloads + C2 profiles ..."
    echo "$MYTHIC_EXTRAS" | while read -r name url; do
        [ -z "$name" ] && continue
        echo "  → mythic-cli install github $url  (~2-10 min)"
        if ./mythic-cli install github "$url" 2>&1 | tail -5; then
            if [ -d "/opt/mythic/InstalledServices/$name" ]; then
                echo "    ✓ /opt/mythic/InstalledServices/$name exists"
            else
                echo "    ! install reported success but dir missing — deploy-time role will retry"
            fi
        else
            echo "    ! install failed for $name — deploy-time role will retry"
        fi
    done

    echo "[mythic-bake] stopping mythic stack (so the baked image isn't running services) ..."
    ./mythic-cli stop 2>&1 | tail -5 || true
fi
echo

# Marker so deploy-time c2-mythic.sh can detect baked image + skip
# Docker install / Go install / git clone / make.
echo "$HEAD" > /opt/mythic/.baked
date >> /opt/mythic/.baked
echo "[mythic-bake] marker /opt/mythic/.baked written"

echo "[mythic-bake] cleaning apt cache (shrinks captured image) ..."
apt-get clean
rm -rf /var/lib/apt/lists/*

echo "[mythic-bake] baseline complete."
echo "[mythic-bake] cached docker images:"
docker image ls 2>/dev/null | head -20
