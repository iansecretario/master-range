#!/bin/sh
# Bake-time baseline for the Sliver C2 teamserver image.
# Mirrors the binary-download portion of modules/azure/userdata/c2-sliver.sh.
set -eu

FILEBEAT_VER=8.13.4

echo "[sliver-bake] apt-get update + upgrade ..."
export DEBIAN_FRONTEND=noninteractive
apt-get -y update
apt-get -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" upgrade

echo "[sliver-bake] base packages ..."
apt-get -y install --no-install-recommends \
    ca-certificates \
    curl \
    openssl \
    openssh-server \
    jq \
    rsync

echo "[sliver-bake] fetching latest sliver-server binary from GitHub releases ..."
# Same logic as c2-sliver.sh — query GitHub API for the latest tag,
# then fetch the linux/amd64 server binary. Place at /root/sliver-server
# (where the deploy userdata expects it) + chmod +x.
URL=$(curl -fsSL --retry 3 https://api.github.com/repos/BishopFox/sliver/releases/latest \
       | jq -r '.assets[] | select(.name == "sliver-server_linux") | .browser_download_url')

if [ -z "$URL" ] || [ "$URL" = "null" ]; then
    echo "[sliver-bake] WARN: no sliver-server_linux asset in latest release — falling back to wildcard"
    URL=$(curl -fsSL --retry 3 https://api.github.com/repos/BishopFox/sliver/releases/latest \
           | jq -r '.assets[] | select(.name | test("sliver-server.*linux.*")) | .browser_download_url' \
           | head -1)
fi
echo "[sliver-bake]   URL: $URL"

curl -fsSL --retry 5 --retry-delay 10 --max-time 600 "$URL" -o /root/sliver-server
chmod +x /root/sliver-server
echo "[sliver-bake]   /root/sliver-server staged: $(ls -la /root/sliver-server)"

# Verify it runs (-h / version probe). Failure = bad binary, fail bake.
/root/sliver-server version 2>&1 | head -3 || {
    echo "[sliver-bake] sliver-server failed to run — refusing to capture image with bad binary"
    exit 1
}

echo "[sliver-bake] pre-installing filebeat ${FILEBEAT_VER} .deb ..."
curl -fsSL "https://artifacts.elastic.co/downloads/beats/filebeat/filebeat-${FILEBEAT_VER}-amd64.deb" \
    -o /tmp/filebeat.deb \
    && dpkg -i /tmp/filebeat.deb \
    && rm -f /tmp/filebeat.deb \
    || echo "  (filebeat install failed — deploy-time retry)"

# Marker so deploy userdata can detect baked image.
date > /root/.sliver-baked
echo "[sliver-bake] marker /root/.sliver-baked written"

echo "[sliver-bake] cleaning apt cache (shrinks captured image) ..."
apt-get clean
rm -rf /var/lib/apt/lists/*

echo "[sliver-bake] baseline complete."
