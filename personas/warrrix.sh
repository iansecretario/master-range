#!/usr/bin/env bash
# =============================================================================
# VulnLab — Warrrix Linux (Hardened-Appearing Box)
# =============================================================================
# Theme   : Looks locked-down on the surface (fail2ban, ufw, audit, no
#           obvious creds), but has deep privesc paths reachable by
#           determined enumeration.
# OS      : Ubuntu 22.04 / Debian 12
# WARNING : ISOLATED LAB ENVIRONMENT ONLY
# =============================================================================
#
# This is a SKELETON. Add your own initial-foothold vector (web app,
# misconfigured service, exposed credential) and chain to root.
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; YEL='\033[1;33m'; GRN='\033[0;32m'
BLU='\033[0;34m'; CYN='\033[0;36m'; RST='\033[0m'; BLD='\033[1m'

banner() { echo -e "\n${CYN}${BLD}[*] $1${RST}"; }
ok()     { echo -e "${GRN}[+] $1${RST}"; }
warn()   { echo -e "${YEL}[!] $1${RST}"; }

[[ $EUID -ne 0 ]] && { echo -e "${RED}Run as root.${RST}"; exit 1; }

LAB_IP=$(hostname -I | awk '{print $1}')
LOGFILE="/var/log/warrrix_vulnlab.log"
exec > >(tee -a "$LOGFILE") 2>&1

echo -e "${RED}${BLD}"
cat <<'EOF'
 __        __                     _
 \ \      / /_ _ _ __ _ __ _ __  | |__ __  __
  \ \ /\ / / _` | '__| '__| '__| | '_ \\ \/ /
   \ V  V / (_| | |  | |  | |    | | | |>  <
    \_/\_/ \__,_|_|  |_|  |_|    |_| |_/_/\_\
   VulnLab — TRAINING USE ONLY
EOF
echo -e "${RST}"

warn "Looks hardened on the surface. Enumerate carefully."
sleep 3

# =============================================================================
# PHASE 0 — Packages
# =============================================================================
banner "PHASE 0 — Installing packages"
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    openssh-server curl wget git vim sudo cron \
    fail2ban ufw auditd \
    python3 python3-pip \
    libcap2-bin gcc make 2>/dev/null || true
ok "Packages installed"

# =============================================================================
# PHASE 1 — Users (legitimate-looking)
# =============================================================================
banner "PHASE 1 — Users"

declare -A USERS=(
    ["warrior"]="W4rri0r#L0ngP4ss!2025"     # standard user (foothold via other vector)
    ["valkyrie"]="V4lk!ChooseTheSlain"      # second user, different group
    ["forge"]=""                              # service account (passwordless, but locked sh)
)

for USER in "${!USERS[@]}"; do
    PASS="${USERS[$USER]}"
    id "$USER" &>/dev/null || useradd -m -s /bin/bash "$USER"
    if [[ -z "$PASS" ]]; then passwd -l "$USER"
    else echo "$USER:$PASS" | chpasswd; fi
    ok "User: $USER"
done

# Forge runs a service; nologin shell would be too obvious — keep bash but lock pw
usermod -s /bin/bash forge

# =============================================================================
# PHASE 2 — SSH (looks tight)
# =============================================================================
banner "PHASE 2 — SSH (appears hardened)"
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/'              /etc/ssh/sshd_config
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
sed -i 's/^#\?MaxAuthTries.*/MaxAuthTries 3/'                      /etc/ssh/sshd_config
systemctl restart ssh

# fail2ban looks active (enumeration red herring)
systemctl enable fail2ban && systemctl restart fail2ban 2>/dev/null || true
ok "SSH/fail2ban: appears hardened"

# UFW with looks-restrictive rules
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw allow 80/tcp
ufw --force enable
ok "UFW enabled"

# =============================================================================
# PHASE 3 — Privesc vectors (deep, not obvious)
# =============================================================================
banner "PHASE 3 — Privesc paths"

# Capability-based privesc: cap_setuid on python3 (subtle vs SUID)
setcap cap_setuid,cap_setgid+ep $(which python3) 2>/dev/null || true

# A writable PATH directory entry that root's cron uses
mkdir -p /opt/warrrix/bin
chmod 777 /opt/warrrix/bin
echo "PATH=/opt/warrrix/bin:/usr/bin:/bin" > /etc/cron.d/warrrix-maintenance
echo "* * * * * root /opt/warrrix/bin/cleanup.sh 2>/dev/null" >> /etc/cron.d/warrrix-maintenance
chmod 644 /etc/cron.d/warrrix-maintenance

# A "looks intentional" but world-writable .sh placed in PATH order
# Student needs to drop their own cleanup.sh to win

# Vim with cap_dac_read_search — can read /etc/shadow without being root
setcap cap_dac_read_search+ep $(which vim) 2>/dev/null || true

# Sudo timestamps_timeout extended on a specific user
echo "Defaults:warrior  timestamp_timeout=60" > /etc/sudoers.d/warrrix-timeout
chmod 440 /etc/sudoers.d/warrrix-timeout

ok "Privesc vectors planted"

# =============================================================================
# PHASE 4 — Flag plants
# =============================================================================
banner "PHASE 4 — Flag plants"

# User flag (reachable after foothold, before privesc)
echo "guidem{warrrix_user_foothold_achieved}" > /home/warrior/user.txt
chmod 644 /home/warrior/user.txt
chown warrior:warrior /home/warrior/user.txt

# Capability privesc flag
echo "guidem{cap_setuid_python3_root_via_warrrix}" > /root/cap_flag.txt
chmod 400 /root/cap_flag.txt

# Cron PATH hijack flag
echo "guidem{cron_path_hijack_warrrix_pwned}" > /root/cron_flag.txt
chmod 400 /root/cron_flag.txt

# Trophy
cat > /root/TROPHY.txt <<TROPHY
==========================================================
   WARRRIX — Compromised
   TROPHY: guidem{warrrix_full_chain_completed_2025}
==========================================================
TROPHY
chmod 400 /root/TROPHY.txt

ok "Flags planted"

banner "Warrrix VulnLab — Ready"
echo -e "${BLD}Target : ssh warrior@${LAB_IP}${RST}"
echo -e "${BLD}Log    : ${LOGFILE}${RST}"
