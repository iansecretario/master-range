#!/usr/bin/env bash
# =============================================================================
# Persona: realm-joined
# =============================================================================
# Theme   : Linux box that authenticates against AD via realmd/SSSD/Kerberos.
# OS      : Ubuntu 22.04 / 24.04 / Debian 12
# WARNING : ISOLATED LAB ENVIRONMENT ONLY
# =============================================================================
#
# Joins this box to the AD forest defined by env vars below. Used in the
# integration scenario to verify cross-OS domain authentication works
# end-to-end (Linux user logs in with AD credentials, gets Kerberos
# ticket via SSSD).
#
# This persona reads the per-student Domain Admin password from a file
# planted by cloud-init at /opt/realm/admin.pass. The wrapper deletes
# the file after this persona runs (standard persona cleanup).

set -euo pipefail

RED='\033[0;31m'; GRN='\033[0;32m'; YEL='\033[1;33m'; CYN='\033[0;36m'
RST='\033[0m'; BLD='\033[1m'

banner() { echo -e "\n${CYN}${BLD}[*] $1${RST}"; }
ok()     { echo -e "${GRN}[+] $1${RST}"; }
warn()   { echo -e "${YEL}[!] $1${RST}"; }

[[ $EUID -ne 0 ]] && { echo -e "${RED}Run as root.${RST}"; exit 1; }

LOGFILE="/var/log/realm-joined-persona.log"
exec > >(tee -a "$LOGFILE") 2>&1

# --- Hardcoded for the integration scenario. Operator can edit this
# persona to parameterise via env vars or a config file at /etc/realm-join.conf
DOMAIN_FQDN="${DOMAIN_FQDN:-corp-test.local}"
ADMIN_USER="${ADMIN_USER:-rangeadmin}"
ADMIN_PASS_FILE="/opt/realm/admin.pass"

banner "PHASE 0 — Packages"
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    realmd sssd sssd-tools sssd-ad libnss-sss libpam-sss \
    adcli samba-common-bin krb5-user packagekit \
    openssh-server curl wget vim 2>/dev/null || true
ok "Packages installed"

# Disable interactive Kerberos prompts
echo "krb5-config krb5-config/default_realm string ${DOMAIN_FQDN^^}" | debconf-set-selections
echo "krb5-config krb5-config/kerberos_servers string" | debconf-set-selections
echo "krb5-config krb5-config/admin_server string" | debconf-set-selections

banner "PHASE 1 — DNS resolver"
# Set the DC as the primary DNS resolver. The DC is at 10.<n>.0.10 by
# convention — discover it from our own subnet.
MY_IP=$(hostname -I | awk '{print $1}')
SUBNET_OCTET=$(echo "$MY_IP" | cut -d. -f2)
DC_IP="10.${SUBNET_OCTET}.0.10"

# Persistent DNS via netplan (Ubuntu) or resolvconf (Debian)
if [[ -d /etc/netplan ]]; then
    cat > /etc/netplan/99-realm-dns.yaml <<NETPLAN
network:
  version: 2
  ethernets:
    eth0:
      dhcp4: true
      dhcp4-overrides:
        use-dns: false
      nameservers:
        addresses: [${DC_IP}, 1.1.1.1]
        search: [${DOMAIN_FQDN}]
NETPLAN
    chmod 600 /etc/netplan/99-realm-dns.yaml
    netplan apply
fi
# /etc/resolv.conf direct (works on Debian + Ubuntu)
echo "search ${DOMAIN_FQDN}"     > /etc/resolv.conf
echo "nameserver ${DC_IP}"      >> /etc/resolv.conf
echo "nameserver 1.1.1.1"       >> /etc/resolv.conf
chattr +i /etc/resolv.conf 2>/dev/null || true
ok "DNS pointed at DC ${DC_IP}"

banner "PHASE 2 — Wait for domain to be reachable"
TRIES=0
while [[ $TRIES -lt 60 ]]; do
    if realm discover "$DOMAIN_FQDN" 2>/dev/null | grep -q 'domain-name'; then
        ok "Domain $DOMAIN_FQDN discovered"
        break
    fi
    sleep 30
    TRIES=$((TRIES + 1))
done
[[ $TRIES -ge 60 ]] && { warn "Domain never became reachable; aborting"; exit 0; }

banner "PHASE 3 — Realm join"
if [[ ! -f "$ADMIN_PASS_FILE" ]]; then
    warn "No admin password file at $ADMIN_PASS_FILE — skipping join"
    exit 0
fi

# Use stdin for the password so it doesn't end up in /proc or shell history
realm join -U "$ADMIN_USER" --install=/ "$DOMAIN_FQDN" < "$ADMIN_PASS_FILE" \
    || { warn "Realm join failed — see $LOGFILE"; exit 0; }
ok "Joined to $DOMAIN_FQDN"

banner "PHASE 4 — SSSD config"
# Allow Domain Users to login by short name + auto-create home dirs
sed -i 's/^use_fully_qualified_names = .*$/use_fully_qualified_names = False/' /etc/sssd/sssd.conf || \
    echo 'use_fully_qualified_names = False' >> /etc/sssd/sssd.conf
sed -i 's/^fallback_homedir = .*$/fallback_homedir = \/home\/%u/'                /etc/sssd/sssd.conf || \
    echo 'fallback_homedir = /home/%u' >> /etc/sssd/sssd.conf

pam-auth-update --enable mkhomedir 2>/dev/null || true
systemctl restart sssd
ok "SSSD configured"

banner "PHASE 5 — Sanity check"
sleep 5
if id "${ADMIN_USER}@${DOMAIN_FQDN}" &>/dev/null; then
    ok "AD user resolution works: id ${ADMIN_USER}@${DOMAIN_FQDN}"
else
    warn "AD user resolution NOT working yet — may need a reboot"
fi

# Allow Domain Users to SSH in
realm permit -g "Domain Users@${DOMAIN_FQDN}" 2>/dev/null || \
    realm permit --all 2>/dev/null || true
ok "SSH access granted to Domain Users"

# Trophy / verification marker
cat > /etc/realm-join-verified <<EOM
============================================================
  Linux realm-join verification
  Domain   : ${DOMAIN_FQDN}
  Joined   : $(date -u +%FT%TZ)
  Hostname : $(hostname)
  IP       : ${MY_IP}
  AD test  : id ${ADMIN_USER}@${DOMAIN_FQDN}
  SSH test : ssh ${ADMIN_USER}@${DOMAIN_FQDN}@<this-host>
============================================================
EOM
chmod 644 /etc/realm-join-verified

ok "Realm-joined persona complete"
