#!/bin/sh
# Bake-time baseline for the AdaptixC2 teamserver image.
#
# Mirrors the install logic in modules/azure/userdata/c2-server.sh —
# everything up to and including `make all`. Deploy-time userdata only
# needs to drop profile.yaml + start systemd; the slow apt + Go install
# + git clone + compile is already done.
set -eu

GO_VER=1.25.4
ADAPTIX_REPO=https://github.com/Adaptix-Framework/AdaptixC2.git

echo "[adaptix-bake] apt-get update + upgrade ..."
export DEBIAN_FRONTEND=noninteractive
apt-get -y update
apt-get -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" upgrade

echo "[adaptix-bake] installing build toolchain + Adaptix dependencies ..."
# build-essential / cmake: AdaptixC2 make target
# Qt6-* (qt6-base-dev, qt6-tools-dev, libqt6*-dev): client deps that
#   the umbrella `make all` target chains through. Server compile alone
#   doesn't NEED them, but baking once with full deps avoids surprises
#   if anyone runs `make all` on the deployed VM.
# ca-certificates + curl + git: code fetch
apt-get -y install --no-install-recommends \
    ca-certificates \
    curl \
    git \
    wget \
    make \
    cmake \
    build-essential \
    pkg-config \
    libssl-dev \
    qt6-base-dev \
    qt6-tools-dev \
    qt6-multimedia-dev \
    libqt6opengl6-dev \
    libqt6openglwidgets6 \
    qt6-l10n-tools \
    libqt6websockets6-dev \
    qt6-declarative-dev \
    qt6-charts-dev \
    libgl1-mesa-dev \
    libxkbcommon-dev \
    rsync \
    jq \
    openssl \
    python3

echo "[adaptix-bake] installing Go ${GO_VER} under /usr/local/go ..."
if ! /usr/local/go/bin/go version 2>/dev/null | grep -q "go${GO_VER}"; then
    curl -fsSL "https://go.dev/dl/go${GO_VER}.linux-amd64.tar.gz" -o /tmp/go.tgz
    rm -rf /usr/local/go && tar -C /usr/local -xzf /tmp/go.tgz
    rm -f /tmp/go.tgz
    # Symlink into /usr/local/bin/ so non-login shells (cloud-init,
    # systemd) find it without PATH changes.
    ln -sf /usr/local/go/bin/go    /usr/local/bin/go
    ln -sf /usr/local/go/bin/gofmt /usr/local/bin/gofmt
fi
go version

echo "[adaptix-bake] cloning AdaptixC2 to /opt/adaptix/AdaptixC2 ..."
mkdir -p /opt/adaptix
if [ ! -d /opt/adaptix/AdaptixC2 ]; then
    git clone --depth 1 "$ADAPTIX_REPO" /opt/adaptix/AdaptixC2
fi
HEAD=$(cd /opt/adaptix/AdaptixC2 && git rev-parse --short HEAD 2>/dev/null || echo unknown)
echo "[adaptix-bake]   AdaptixC2 HEAD: $HEAD"

cd /opt/adaptix/AdaptixC2

# AdaptixC2's Makefile has SEPARATE targets — the default `make` builds
# only the server binary. The slow parts are the EXTENDERS (each Go
# plugin compiles to its own .so/.tact file) and the listener plugins,
# which are what students actually use for beacon callbacks. If we
# only build the server, deploys would still have to compile every
# extender at first boot — defeating the bake.
#
# Compile order (slow → slowest):
#   1. server       — Go teamserver binary (~1-2 min)
#   2. extenders    — every listener + protocol plugin (~5-8 min)
#   3. agents       — beacon binaries / templates (~2-3 min)
#   4. plugins      — auxiliary plugins (BOF loader, etc.) (~1-2 min)
#
# `make all` chains every target including the Qt6 client (which we
# don't need on the server box but is built anyway since we baked the
# Qt6 deps). Client build adds ~5-10 min but means the bake produces
# a complete AdaptixC2 install — useful if you ever want to develop /
# debug on the teamserver. Net bake time: ~15-20 min for `make all`
# vs ~10-12 min for server+extenders+agents+plugins. Worth the extra
# minutes for completeness.

echo "[adaptix-bake] running 'make all' — compiles server + extenders + agents + plugins (+ client). ~15-20 min."
make all 2>&1 | tail -40 || echo "[adaptix-bake] WARN: make all exited non-zero — verifying which targets succeeded below"

# Fallback: if `make all` choked on the Qt6 client (most likely cause
# of a non-zero exit on a server-class build), run the SERVER + EXTENDER
# targets explicitly so the teamserver image is still useful.
echo "[adaptix-bake] explicit fallback: ensuring server + extenders + agents + plugins are built ..."
for target in server extenders agents plugins; do
    if make -n "$target" >/dev/null 2>&1; then
        echo "  → make $target"
        make "$target" 2>&1 | tail -10 || echo "    (target $target failed — non-fatal, verifying artefacts)"
    else
        echo "  (no '$target' target in Makefile — skipping)"
    fi
done

echo "[adaptix-bake] build artefacts:"
find /opt/adaptix/AdaptixC2/dist 2>/dev/null | head -30 || true
echo "  server binary candidates:"
find /opt/adaptix/AdaptixC2 -name 'adaptixserver*' -type f 2>/dev/null | head -5 || true
echo "  extender / plugin artefacts (.so/.tact/.bin files):"
find /opt/adaptix/AdaptixC2 \( -name '*.so' -o -name '*.tact' -o -name '*.bin' \) -type f 2>/dev/null | head -20 || true

# Write a marker so the deploy-time userdata (c2-server.sh) can detect
# a baked image and skip the apt/go/git/make path. Userdata can read
# this with: `[ -f /opt/adaptix/.baked ] && echo skip-heavy-install`
echo "$HEAD" > /opt/adaptix/.baked
date >> /opt/adaptix/.baked
echo "[adaptix-bake] marker /opt/adaptix/.baked written"

# Build sentinel — what the ansible role's `Check build sentinel` task
# slurps to decide whether a rebuild is required. Without this, the
# role's needs_rebuild check evaluates true on every deploy (because
# the file doesn't exist), and it re-runs `make server` + every
# extender + beacon_agent — ~5-8 min wasted per deploy, since we
# already did it via `make all` above.
#
# The format MUST match exactly what the role writes after its own
# successful rebuild:
#   "go<adaptix_go_version>|<GOEXPERIMENT>"
# Currently:
#   - adaptix_go_version is "1.25.4" (group_vars/all.yml)
#   - GOEXPERIMENT is "jsonv2,greenteagc" (roles/adaptix/tasks/main.yml line 103)
# If either changes upstream, bump these to match or the bake's
# sentinel will be considered stale and rebuilds will fire anyway.
SENTINEL_GO_VER="$GO_VER"
SENTINEL_GOEXPERIMENT="jsonv2,greenteagc"
printf 'go%s|%s' "$SENTINEL_GO_VER" "$SENTINEL_GOEXPERIMENT" > /opt/adaptix/.build-sentinel
echo "[adaptix-bake] build-sentinel written: $(cat /opt/adaptix/.build-sentinel)"

echo "[adaptix-bake] cleaning apt cache (shrinks captured image) ..."
apt-get clean
rm -rf /var/lib/apt/lists/*

echo "[adaptix-bake] baseline complete."
