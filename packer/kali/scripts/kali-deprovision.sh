#!/bin/sh
# terra-range — Kali pre-bake DEPROVISION / generalize step.
#
# Runs as the LAST packer provisioner, immediately before image capture.
#
# Kali's Azure Marketplace image is cloud-init-provisioned and ships NO
# WALinuxAgent: /usr/sbin/waagent does not exist, so the conventional
# Linux generalize step `waagent -deprovision+user` exits 127
# ("not found") and fails the build. We do the equivalent by hand.
#
# This is not just a workaround — it is the CORRECT generalize path for
# a cloud-init-provisioned image. A VM deployed from the captured image
# must have cloud-init RE-RUN from scratch (it creates `ranger`, drops
# the operator key, sets the hostname, ...). Only `cloud-init clean`
# resets that "already provisioned" state; `waagent -deprovision` would
# not have, so deployed VMs could have come up unconfigured.
#
# Best-effort throughout: every step is guarded so the script always
# exits 0 (packer's allowed exit codes are [0]).

set -u
cd /

echo "[deprovision] reset cloud-init (re-runs fresh on every deployed VM)..."
cloud-init clean --logs --seed 2>/dev/null || true
rm -rf /var/lib/cloud/* 2>/dev/null || true

echo "[deprovision] drop host identity (SSH host keys + machine-id regenerate on boot)..."
rm -f /etc/ssh/ssh_host_* 2>/dev/null || true
: > /etc/machine-id 2>/dev/null || true
rm -f /var/lib/dbus/machine-id 2>/dev/null || true

echo "[deprovision] clear DHCP leases + any stale agent state..."
rm -f /var/lib/dhcp/* 2>/dev/null || true
rm -rf /var/lib/waagent 2>/dev/null || true

echo "[deprovision] truncate logs + shell history..."
find /var/log -type f -exec truncate -s 0 {} + 2>/dev/null || true
rm -f /root/.bash_history 2>/dev/null || true
for h in /home/*/.bash_history; do
  [ -e "$h" ] && rm -f "$h" 2>/dev/null || true
done

echo "[deprovision] schedule removal of the temporary packer build user..."
# The packer SSH session is running AS the `packer` user right now, so a
# userdel here would either fail or risk dropping packer's connection
# before this script returns 0. Defer it to a root-owned systemd
# one-shot that fires on the first boot of a deployed VM, removes the
# user, then deletes itself.
cat > /etc/systemd/system/terra-deprovision-user.service 2>/dev/null <<'UNIT' || true
[Unit]
Description=terra-range one-shot - strip the packer build user from the baked image

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'userdel -r -f packer || true; rm -rf /home/packer || true; systemctl disable terra-deprovision-user.service || true; rm -f /etc/systemd/system/terra-deprovision-user.service || true'

[Install]
WantedBy=multi-user.target
UNIT
systemctl enable terra-deprovision-user.service 2>/dev/null || true

echo "[deprovision] flush to disk."
sync
echo "[deprovision] complete - image ready for capture."
exit 0
