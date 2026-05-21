#!/bin/sh
# Bake-time baseline for the RedELK image.
#
# Pre-installs Docker + docker compose + git + apt prereqs, clones
# RedELK at /opt/redelk (where the deploy userdata expects it), and
# pre-pulls the docker images the install-elkserver.sh script would
# otherwise have to fetch at first boot (~3 GB of elasticsearch,
# kibana, logstash, nginx, jupyter images). Deploy-time just runs the
# config wrapper.
set -eu

echo "[redelk-bake] apt-get update + upgrade ..."
export DEBIAN_FRONTEND=noninteractive
apt-get -y update
apt-get -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" upgrade

echo "[redelk-bake] base packages + docker prereqs ..."
apt-get -y install --no-install-recommends \
    ca-certificates \
    curl \
    jq \
    git \
    openssl \
    python3 \
    python3-yaml \
    wget \
    apt-transport-https \
    gnupg

# Install Docker via the official convenience script (same path the
# deploy-time userdata uses; baking it here means deploy skips the
# 1-2 min docker install).
echo "[redelk-bake] installing Docker via get.docker.com ..."
curl -fsSL https://get.docker.com | sh
# docker compose plugin (v2). Required by RedELK's docker-compose.yml.
apt-get -y install --no-install-recommends docker-compose-plugin

# Clone RedELK at the canonical path. --depth 1 keeps the clone lean.
# Deploy-time userdata does NOT re-clone if /opt/redelk exists, so
# pre-baking the clone is a clean win.
echo "[redelk-bake] cloning RedELK to /opt/redelk ..."
if [ ! -d /opt/redelk ]; then
    git clone --depth 1 https://github.com/outflanknl/RedELK.git /opt/redelk
fi
HEAD=$(cd /opt/redelk && git rev-parse --short HEAD 2>/dev/null || echo unknown)
echo "[redelk-bake]   redelk HEAD: $HEAD"

# Pre-pull every docker image RedELK's compose files reference. Saves
# ~3-5 GB of pull time on first deploy. RedELK ships three compose
# profiles at the elkserver/ root (redelk-full.yml, redelk-limited.yml,
# redelk-dev.yml) — install-elkserver.sh symlinks the chosen one to
# docker-compose.yml at install time. Pre-bake pulls images referenced
# by ALL of them so any profile choice at deploy time is fast.
#
# We parse `image:` lines rather than hardcoding so a RedELK upstream
# bump is auto-picked-up on the next bake.
echo "[redelk-bake] pre-pulling RedELK docker images ..."
images=$(find /opt/redelk -type f \
         \( -name 'docker-compose*.yml' \
            -o -name 'docker-compose*.yaml' \
            -o -name 'redelk-*.yml' \
            -o -name 'redelk-*.yaml' \) 2>/dev/null \
         | xargs -r grep -h '^\s*image:' 2>/dev/null \
         | awk '{print $2}' \
         | tr -d '"' \
         | sort -u)
if [ -n "$images" ]; then
    echo "  images to pull:"
    echo "$images" | sed 's/^/    /'
    echo "$images" | while read -r img; do
        [ -z "$img" ] && continue
        echo "  pulling: $img"
        docker pull "$img" 2>&1 | tail -3 || echo "    (pull failed for $img — deploy-time will retry)"
    done
else
    echo "  (no docker-compose images detected — deploy-time will pull)"
fi

# Belt-and-suspenders: explicitly pull the upstream stack images RedELK
# uses, in case the compose-file parse above missed anything (e.g. when
# RedELK rev'd to a structure we don't auto-detect). Pinning to ES 8.x
# matches what the role expects to find. Failures non-fatal.
echo "[redelk-bake] pre-pulling baseline stack images (ES 8.x family) ..."
for img in \
    docker.elastic.co/elasticsearch/elasticsearch:8.13.4 \
    docker.elastic.co/kibana/kibana:8.13.4 \
    docker.elastic.co/logstash/logstash:8.13.4 \
    nginx:stable ; do
    docker image inspect "$img" >/dev/null 2>&1 && continue
    echo "  pulling $img"
    docker pull "$img" 2>&1 | tail -2 || echo "    (pull failed for $img — deploy-time retry)"
done

# Marker so deploy-time ansible role can detect baked image and skip
# the apt/docker install + git clone + image pulls (the slow path).
# The role gates its `Probe` task on this file's existence.
echo "$HEAD" > /opt/redelk/.baked
date >> /opt/redelk/.baked
echo "[redelk-bake] marker /opt/redelk/.baked written"

echo "[redelk-bake] cleaning apt cache (shrinks captured image) ..."
apt-get clean
rm -rf /var/lib/apt/lists/*

echo "[redelk-bake] baseline complete."
echo "[redelk-bake] /opt/redelk contents:"
ls /opt/redelk/ 2>/dev/null | head -10
echo "[redelk-bake] cached docker images:"
docker image ls 2>/dev/null | head -20
