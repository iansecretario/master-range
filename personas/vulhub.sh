#!/usr/bin/env bash
# =============================================================================
# Persona: vulhub
# =============================================================================
# Theme   : Vulhub — pre-built Docker labs for known CVEs.
# Source  : https://github.com/vulhub/vulhub
# OS      : Debian 12 / Ubuntu 22.04
# WARNING : Vulhub launches intentionally vulnerable services on the
#           configured ports. ISOLATED LAB ENVIRONMENT ONLY.
# =============================================================================
#
# Vulhub is a curated catalogue of >150 vulnerable environments, each as
# a docker-compose. This persona installs Docker, clones the repo to
# /opt/vulhub, and starts a handful of representative labs. Edit the
# `LABS_TO_START` list below to change which ones come up at boot.
#
# Once running, each lab is reachable on a different port (defined by
# the lab's docker-compose.yml). Browse /opt/vulhub/<dir>/README.md for
# the exploitation walkthrough.

set -euo pipefail

RED='\033[0;31m'; YEL='\033[1;33m'; GRN='\033[0;32m'
BLU='\033[0;34m'; CYN='\033[0;36m'; RST='\033[0m'; BLD='\033[1m'

banner() { echo -e "\n${CYN}${BLD}[*] $1${RST}"; }
ok()     { echo -e "${GRN}[+] $1${RST}"; }
warn()   { echo -e "${YEL}[!] $1${RST}"; }

[[ $EUID -ne 0 ]] && { echo -e "${RED}Run as root.${RST}"; exit 1; }

LAB_IP=$(hostname -I | awk '{print $1}')
LOGFILE="/var/log/vulhub_persona.log"
exec > >(tee -a "$LOGFILE") 2>&1

# -----------------------------------------------------------------------------
# Pick which Vulhub labs to bring up at boot. Each entry is a path
# relative to the vulhub repo root. Add or remove freely.
# -----------------------------------------------------------------------------
LABS_TO_START=(
    "log4j/CVE-2021-44228"     # Log4Shell
    "spring/CVE-2022-22965"    # Spring4Shell
    "struts2/s2-001"           # Struts2 OGNL
    "joomla/CVE-2023-23752"    # Joomla auth bypass
    "weblogic/CVE-2017-10271"  # WebLogic XMLDecoder RCE
)

banner "PHASE 0 — Packages"
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    git curl wget openssh-server jq vim 2>/dev/null || true

# Docker via official convenience script (idempotent)
if ! command -v docker >/dev/null 2>&1; then
    curl -fsSL https://get.docker.com | sh
fi
ok "Docker installed"

banner "PHASE 1 — Clone Vulhub"
if [[ ! -d /opt/vulhub ]]; then
    git clone --depth 1 https://github.com/vulhub/vulhub.git /opt/vulhub
fi
ok "Repo at /opt/vulhub"

banner "PHASE 2 — Bring up selected labs"
START_LOG="/var/log/vulhub_started.txt"
: > "$START_LOG"

for lab in "${LABS_TO_START[@]}"; do
    dir="/opt/vulhub/$lab"
    if [[ ! -d "$dir" ]]; then
        warn "Skipping (not found in repo): $lab"
        continue
    fi
    cd "$dir"
    if docker compose up -d >> "$START_LOG" 2>&1; then
        # Read the exposed port(s) from compose
        PORTS=$(docker compose ps --format json 2>/dev/null \
                | jq -r '.[].Publishers[]? | "\(.PublishedPort)/\(.Protocol)"' 2>/dev/null \
                | sort -u | paste -sd, -)
        ok "Started: $lab  (ports: ${PORTS:-unknown})"
        echo "$lab  ${PORTS:-?}" >> "$START_LOG"
    else
        warn "Failed to start: $lab — see $START_LOG"
    fi
done

banner "PHASE 3 — Convenience"
# MOTD
cat > /etc/motd <<EOM
============================================================
  Vulhub Lab Host
  Repo:        /opt/vulhub
  Started:     ${START_LOG}
  Lab IP:      ${LAB_IP}
  To list:     docker ps
  To stop one: cd /opt/vulhub/<lab> && docker compose down
  To start a new lab:
               cd /opt/vulhub/<category>/<lab>
               docker compose up -d
============================================================
EOM

# A trivial README on the box
cat > /root/README-vulhub.txt <<EOR
Vulhub is at /opt/vulhub. Each subdirectory is a self-contained CVE lab
with its own README.md describing the vulnerability and exploitation.

Started at provisioning time:
$(cat "$START_LOG")

To bring up a different lab:
  cd /opt/vulhub/<category>/<lab>
  docker compose up -d
  cat README.md   # walkthrough
EOR
chmod 644 /root/README-vulhub.txt

ok "Vulhub persona ready — see /etc/motd on next login"
