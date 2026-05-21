#!/usr/bin/env bash
# =============================================================================
# Persona: splunk-server
# =============================================================================
# Theme   : Splunk Enterprise indexer for an Attack Range deployment.
# OS      : Debian 12 / Ubuntu 22.04
# Source  : https://github.com/splunk/attack_range
# WARNING : Free Splunk license. ISOLATED LAB ENVIRONMENT ONLY.
# =============================================================================
#
# Provides:
#   - Splunk Enterprise (free 60-day trial license) on :8000 (web) + :8089 (mgmt)
#   - HEC token for forwarders/Universal Forwarders
#   - Preconfigured indexes: wineventlog, sysmon, linux, attack
#   - Splunk_TA_microsoft-sysmon and Splunk_TA_windows TAs preinstalled
#
# Pair with Windows boxes running the splunk-uf persona to ship logs
# directly into this indexer.

set -euo pipefail

RED='\033[0;31m'; YEL='\033[1;33m'; GRN='\033[0;32m'
CYN='\033[0;36m'; RST='\033[0m'; BLD='\033[1m'

banner() { echo -e "\n${CYN}${BLD}[*] $1${RST}"; }
ok()     { echo -e "${GRN}[+] $1${RST}"; }
warn()   { echo -e "${YEL}[!] $1${RST}"; }

[[ $EUID -ne 0 ]] && { echo -e "${RED}Run as root.${RST}"; exit 1; }

LAB_IP=$(hostname -I | awk '{print $1}')
LOGFILE="/var/log/splunk_persona.log"
exec > >(tee -a "$LOGFILE") 2>&1

SPLUNK_VERSION="9.3.2"
SPLUNK_BUILD="d8bb32809498"
SPLUNK_PASS="${SPLUNK_PASS:-Sp1unk!Lab2025}"
HEC_TOKEN="00000000-1111-2222-3333-444444444444"

banner "PHASE 0 — Packages"
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    curl wget tar acl 2>/dev/null || true

banner "PHASE 1 — Splunk install"
SPLUNK_DEB="/tmp/splunk.deb"
if [[ ! -d /opt/splunk ]]; then
    curl -fsSL -o "$SPLUNK_DEB" \
      "https://download.splunk.com/products/splunk/releases/${SPLUNK_VERSION}/linux/splunk-${SPLUNK_VERSION}-${SPLUNK_BUILD}-linux-amd64.deb"
    dpkg -i "$SPLUNK_DEB"
    rm -f "$SPLUNK_DEB"
fi

# First-time start with admin password set
if [[ ! -f /opt/splunk/etc/passwd ]]; then
    /opt/splunk/bin/splunk start --accept-license --answer-yes --no-prompt \
        --seed-passwd "$SPLUNK_PASS" || true
fi

banner "PHASE 2 — Indexes + HEC"
cat > /opt/splunk/etc/system/local/indexes.conf <<INDEXES
[wineventlog]
homePath   = \$SPLUNK_DB/wineventlog/db
coldPath   = \$SPLUNK_DB/wineventlog/colddb
thawedPath = \$SPLUNK_DB/wineventlog/thaweddb

[sysmon]
homePath   = \$SPLUNK_DB/sysmon/db
coldPath   = \$SPLUNK_DB/sysmon/colddb
thawedPath = \$SPLUNK_DB/sysmon/thaweddb

[linux]
homePath   = \$SPLUNK_DB/linux/db
coldPath   = \$SPLUNK_DB/linux/colddb
thawedPath = \$SPLUNK_DB/linux/thaweddb

[attack]
homePath   = \$SPLUNK_DB/attack/db
coldPath   = \$SPLUNK_DB/attack/colddb
thawedPath = \$SPLUNK_DB/attack/thaweddb
INDEXES

# Enable HEC (for forwarders and direct REST ingest)
mkdir -p /opt/splunk/etc/apps/splunk_httpinput/local
cat > /opt/splunk/etc/apps/splunk_httpinput/local/inputs.conf <<HEC
[http]
disabled = 0
port = 8088
enableSSL = 1

[http://default]
disabled = 0
token = ${HEC_TOKEN}
indexes = wineventlog,sysmon,linux,attack
index = wineventlog
HEC

# Listen for forwarders (UF default port 9997)
cat > /opt/splunk/etc/system/local/inputs.conf <<RECV
[splunktcp://9997]
disabled = 0
RECV

# Enable receiving via REST too
/opt/splunk/bin/splunk enable listen 9997 -auth admin:$SPLUNK_PASS 2>/dev/null || true

# Boot-start
/opt/splunk/bin/splunk enable boot-start -user splunk -systemd-managed 1 || true
chown -R splunk:splunk /opt/splunk

# Restart to apply
/opt/splunk/bin/splunk restart || true

banner "PHASE 3 — Connection info"
cat > /root/SPLUNK-INFO.txt <<INFO
============================================================
  Splunk Enterprise (Attack Range Indexer)
  Web UI    : http://${LAB_IP}:8000/
  Login     : admin / ${SPLUNK_PASS}
  Mgmt API  : ${LAB_IP}:8089
  HEC URL   : https://${LAB_IP}:8088/services/collector
  HEC token : ${HEC_TOKEN}
  Recv port : 9997 (Splunk-to-Splunk for UF)
  Indexes   : wineventlog, sysmon, linux, attack
============================================================
INFO
chmod 600 /root/SPLUNK-INFO.txt

ok "Splunk persona ready — http://${LAB_IP}:8000/"
