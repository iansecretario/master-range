#!/usr/bin/env bash
# =============================================================================
# VulnLab — Sentry Operations Center (Linux)
# =============================================================================
# Theme   : SOC / monitoring box that is itself misconfigured
# OS      : Debian 12 / Ubuntu 22.04
# WARNING : ISOLATED LAB ENVIRONMENT ONLY
# =============================================================================
#
# This is a SKELETON. Fill in vulnerable services, fake monitoring data,
# and CTF flags appropriate for your training narrative.
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; YEL='\033[1;33m'; GRN='\033[0;32m'
BLU='\033[0;34m'; CYN='\033[0;36m'; RST='\033[0m'; BLD='\033[1m'

banner() { echo -e "\n${CYN}${BLD}[*] $1${RST}"; }
ok()     { echo -e "${GRN}[+] $1${RST}"; }
warn()   { echo -e "${YEL}[!] $1${RST}"; }

[[ $EUID -ne 0 ]] && { echo -e "${RED}Run as root.${RST}"; exit 1; }

LAB_IP=$(hostname -I | awk '{print $1}')
LOGFILE="/var/log/sentry_vulnlab.log"
exec > >(tee -a "$LOGFILE") 2>&1

echo -e "${YEL}${BLD}"
cat <<'EOF'
   ____             _
  / ___|  ___ _ __ | |_ _ __ _   _
  \___ \ / _ \ '_ \| __| '__| | | |
   ___) |  __/ | | | |_| |  | |_| |
  |____/ \___|_| |_|\__|_|   \__, |
                              |___/
   O P E R A T I O N S   C E N T E R
   VulnLab — TRAINING USE ONLY
EOF
echo -e "${RST}"

warn "Intentionally insecure. Never expose to public network."
sleep 3

# =============================================================================
# PHASE 0 — Packages
# =============================================================================
banner "PHASE 0 — Installing packages"
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    openssh-server curl wget git vim sudo cron \
    nginx apache2-utils \
    rsyslog logrotate \
    netcat-traditional socat \
    python3 python3-pip \
    nmap tcpdump 2>/dev/null || true
ok "Packages installed"

# =============================================================================
# PHASE 1 — Users
# =============================================================================
banner "PHASE 1 — Users"

declare -A USERS=(
    ["sentry_admin"]="W4tch3r#2025"      # SOC admin
    ["analyst"]="Tier1!observer"          # SOC analyst, sudoers misconfig target
    ["incident"]=""                        # passwordless service account
)

for USER in "${!USERS[@]}"; do
    PASS="${USERS[$USER]}"
    id "$USER" &>/dev/null || useradd -m -s /bin/bash "$USER"
    if [[ -z "$PASS" ]]; then passwd -d "$USER"
    else echo "$USER:$PASS" | chpasswd; fi
    ok "User: $USER"
done

usermod -aG sudo sentry_admin
echo "sentry_admin ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/sentry_admin
chmod 440 /etc/sudoers.d/sentry_admin

# Sudoers misconfig: analyst can read any file via sudo less
echo "analyst ALL=(ALL) NOPASSWD: /usr/bin/less, /usr/bin/tail" > /etc/sudoers.d/analyst
chmod 440 /etc/sudoers.d/analyst
ok "Sudoers misconfigs applied"

# =============================================================================
# PHASE 2 — SSH (deliberately permissive)
# =============================================================================
banner "PHASE 2 — SSH"
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/'                /etc/ssh/sshd_config
systemctl restart ssh
ok "SSH: password auth + root login enabled"

# =============================================================================
# PHASE 3 — Fake SOC dashboard (placeholder; extend as needed)
# =============================================================================
banner "PHASE 3 — SOC Dashboard"
mkdir -p /var/www/sentry
cat > /var/www/sentry/index.html <<HTML
<!DOCTYPE html>
<title>Sentry Operations</title>
<body style="background:#0d0d0d;color:#e0e0e0;font-family:sans-serif;padding:40px">
<h1 style="color:#fbbf24">SENTRY OPERATIONS CENTER</h1>
<p>SOC Dashboard — Internal use only</p>
<pre style="background:#111;padding:20px;border-left:3px solid #fbbf24">
SOC Status   : OPERATIONAL
Hostname     : $(hostname)
Server IP    : ${LAB_IP}
Tier-1 ack   : open
Last alert   : queue depth 0
</pre>
<p style="color:#666;font-size:0.8rem">Help desk: ext. 5000</p>
</body>
HTML

cat > /etc/nginx/sites-available/sentry <<'NGINX'
server {
    listen 80 default_server;
    root /var/www/sentry;
    index index.html;
    server_tokens on;
    autoindex on;
}
NGINX
ln -sf /etc/nginx/sites-available/sentry /etc/nginx/sites-enabled/sentry
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl restart nginx && systemctl enable nginx
ok "SOC dashboard at http://${LAB_IP}/"

# =============================================================================
# PHASE 4 — Sensitive monitoring data + flags
# =============================================================================
banner "PHASE 4 — Sensitive data + flag plants"

mkdir -p /var/log/sentry /opt/sentry
cat > /opt/sentry/api_keys.txt <<KEYS
# DO NOT COMMIT — internal SOC API tokens
splunk_token   = guidem{sentry_api_token_l34k3d}
elastic_apikey = es-prod-sentry-2025-hardcoded
victorops_key  = vops-incident-fwd-9kx2p
KEYS
chmod 644 /opt/sentry/api_keys.txt

cat > /var/log/sentry/incidents.log <<INC
2025-01-14 03:11:08 INC-001 sev=high   src=10.0.0.99   note=guidem{soc_log_grep_revealed_creds}
2025-01-14 03:42:22 INC-002 sev=med    src=10.0.0.50   note=tier1 acked
INC
chmod 644 /var/log/sentry/incidents.log

# Tier 1 fake bash history (planted by lab)
cat > /home/analyst/.bash_history <<HIST
ssh sentry_admin@10.0.0.50
sudo less /var/log/sentry/incidents.log
curl http://localhost/api_keys.txt
HIST
chown analyst:analyst /home/analyst/.bash_history

# Trophy
cat > /root/TROPHY.txt <<TROPHY
============================================================
  SENTRY OPS — INCIDENT REPORT
  TROPHY: guidem{sentry_soc_fully_compromised_2025}
============================================================
TROPHY
chmod 400 /root/TROPHY.txt
ok "Flags planted"

# =============================================================================
# PHASE 5 — Disable defences
# =============================================================================
banner "PHASE 5 — Disabling defences"
systemctl disable auditd 2>/dev/null || true
systemctl stop    auditd 2>/dev/null || true
ufw disable 2>/dev/null || true
iptables -F; iptables -X 2>/dev/null || true
ok "Defences disabled"

banner "Sentry VulnLab — Ready"
echo -e "${BLD}Target : http://${LAB_IP}/${RST}"
echo -e "${BLD}Log    : ${LOGFILE}${RST}"
