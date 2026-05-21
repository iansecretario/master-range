#!/usr/bin/env bash
# goad-ansible-bridge.sh
# -----------------------------------------------------------------------------
# Reads `terraform output` from the deployed range plus the scenario YAML's
# goad: block, and emits two files the upstream Orange-Cyberdefense/GOAD
# ansible playbook consumes:
#
#   .goad-build/inventory.ini            — per-student WinRM/SSH inventory
#   .goad-build/group_vars/all.yml       — domain names, user roster, etc.
#
# Then runs the upstream playbook against each student's VMs.
#
# Prereqs on the operator workstation:
#   - terraform (with state for the range)
#   - python3 + PyYAML
#   - ansible-core
#   - The Orange-Cyberdefense/GOAD repo cloned somewhere
#
# Usage:
#   ./scripts/goad-ansible-bridge.sh <scenario_name> <path_to_GOAD_repo> [student_id]
#
# If student_id is omitted, the playbook runs for ALL students sequentially.
# -----------------------------------------------------------------------------

set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SCENARIO="${1:-}"
GOAD_REPO="${2:-}"
ONLY_STUDENT="${3:-}"

[[ -n "$SCENARIO" && -n "$GOAD_REPO" ]] || {
    echo "Usage: $0 <scenario_name> <path_to_GOAD_repo> [student_id]"
    echo "  scenario_name  : name from scenarios/ (e.g. 'goad')"
    echo "  GOAD_repo      : path to your clone of Orange-Cyberdefense/GOAD"
    echo "  student_id     : optional, e.g. 'g01' to limit"
    exit 1
}

YAML="$REPO/scenarios/$SCENARIO.yaml"
[[ -f "$YAML" ]] || { echo "scenario yaml not found: $YAML"; exit 1; }
[[ -d "$GOAD_REPO" ]] || { echo "GOAD repo dir not found: $GOAD_REPO"; exit 1; }

BUILD="$REPO/.goad-build"
mkdir -p "$BUILD/group_vars"

# --- 1. Pull live IPs from terraform -----------------------------------------
echo "[*] Pulling terraform outputs..."
cd "$REPO/envs/azure"
TF_OUT="$(terraform output -json)"
cd - >/dev/null

# --- 2. Render inventory + group_vars from YAML + outputs --------------------
echo "[*] Rendering ansible inventory + group_vars..."
python3 - <<PYEOF
import json, os, sys, yaml
from pathlib import Path

REPO = Path("$REPO")
BUILD = Path("$BUILD")
SCENARIO = "$SCENARIO"
ONLY = "$ONLY_STUDENT" or None

cfg = yaml.safe_load(open(REPO / "scenarios" / f"{SCENARIO}.yaml"))
g = cfg.get("goad", {})
if not g.get("enabled"):
    sys.exit(f"ERROR: scenarios/{SCENARIO}.yaml has goad.enabled=false")

tf = json.loads("""$TF_OUT""")
machine_ips = tf["machine_ips"]["value"]   # name -> private ip
admin_user  = "rangeadmin"                  # win_admin_user from default_credentials
admin_pass  = cfg["default_credentials"]["windows_local_password"]

# Group machines per student so we generate one inventory per student.
students = {}
for full_name, ip in machine_ips.items():
    # full_name format: g01-kingslanding (sid-base) or 'kingslanding' (single)
    parts = full_name.split("-", 1)
    if len(parts) == 2:
        sid, base = parts
    else:
        sid, base = "", parts[0]
    students.setdefault(sid, {})[base] = ip

target_sids = [ONLY] if ONLY else sorted(students)
if ONLY and ONLY not in students:
    sys.exit(f"student '{ONLY}' not found in machine_ips. "
             f"Available: {sorted(students)}")

# Hostname -> ansible group mapping (matches upstream GOAD inventory groups)
ROLE_GROUPS = {
    g["root_dc_name"]:     "sevenkingdoms",
    g["child_dc_name"]:    "north",
    g["separate_dc_name"]: "essos",
    g["member_name"]:      "north",     # member is in north domain
}

for sid in target_sids:
    boxes = students[sid]
    inv = BUILD / f"inventory.{sid or 'single'}.ini"
    with open(inv, "w") as f:
        f.write(f"# auto-generated for student {sid}\n\n")
        # Per-domain groups
        groups = {}
        for hostname, ip in boxes.items():
            group = ROLE_GROUPS.get(hostname)
            if group is None:
                continue   # kali etc. — skipped
            groups.setdefault(group, []).append((hostname, ip))
        for group, hosts in groups.items():
            f.write(f"[{group}]\n")
            for hostname, ip in hosts:
                f.write(f"{hostname} ansible_host={ip}\n")
            f.write("\n")
        # Common Windows connection vars
        f.write("[all:vars]\n")
        f.write(f"ansible_user={admin_user}\n")
        f.write(f"ansible_password={admin_pass}\n")
        f.write("ansible_connection=winrm\n")
        f.write("ansible_winrm_transport=ntlm\n")
        f.write("ansible_winrm_server_cert_validation=ignore\n")
        f.write("ansible_port=5985\n")
    print(f"  wrote {inv}")

# group_vars/all.yml — ONE file works across all students because the
# domain names and rosters are the same per scenario. The bridge runs
# the playbook once per student against a different inventory.
all_vars = BUILD / "group_vars" / "all.yml"
with open(all_vars, "w") as f:
    yaml.safe_dump({
        # ---- Domain identities (override upstream defaults) ----
        "domain":           g["root_domain"],
        "domain_sevenkingdoms": g["root_domain"],
        "domain_north":         g["child_domain"],
        "domain_essos":         g["separate_forest_domain"],
        # NetBIOS (the upstream playbook computes from FQDN; override here)
        "domain_netbios_sevenkingdoms": g["root_domain"].split(".")[0].upper(),
        "domain_netbios_north":         g["child_domain"].split(".")[0].upper(),
        "domain_netbios_essos":         g["separate_forest_domain"].split(".")[0].upper(),
        # ---- DC + member hostnames ----
        "dc01_hostname": g["root_dc_name"],
        "dc02_hostname": g["child_dc_name"],
        "dc03_hostname": g["separate_dc_name"],
        "srv01_hostname": g["member_name"],
        # ---- Domain admin per domain ----
        "domain_user_sevenkingdoms": g["root_admin_user"],
        "domain_pass_sevenkingdoms": g["root_admin_password"],
        "domain_user_north":         g["child_admin_user"],
        "domain_pass_north":         g["child_admin_password"],
        "domain_user_essos":         g["separate_admin_user"],
        "domain_pass_essos":         g["separate_admin_password"],
        # ---- User roster (the upstream playbook iterates over this) ----
        "extra_users": [
            {"name": u["name"], "password": u["password"],
             "domain": {"root": "sevenkingdoms", "child": "north",
                        "separate": "essos"}[u["domain"]],
             "groups": u.get("groups", ["Domain Users"])}
            for u in g.get("users", [])
        ],
        # ---- Service-account roster ----
        "service_accounts": [
            {"name": s["name"], "password": s["password"],
             "domain": {"root": "sevenkingdoms", "child": "north",
                        "separate": "essos"}[s["domain"]],
             "kerberoastable":  s.get("kerberoastable", False),
             "asreproastable":  s.get("asreproastable", False),
             "spn":             s.get("spn", "")}
            for s in g.get("service_accounts", [])
        ],
        # ---- Vuln-config toggles ----
        "install_mssql_root":    g["install_mssql_on_root"],
        "install_mssql_member":  g["install_mssql_on_member"],
        "install_iis_root":      g["install_iis_on_root"],
        "seed_kerberoast":       g["seed_kerberoast"],
        "seed_asreproast":       g["seed_asreproast"],
        "seed_acl_misconfigs":   g["seed_acl_misconfigs"],
        "seed_unconstrained":    g["seed_unconstrained_deleg"],
        "seed_constrained":      g["seed_constrained_deleg"],
        "seed_dnsadmins":        g["seed_dnsadmins"],
        "seed_smbv1":            g["seed_smbv1"],
    }, f, default_flow_style=False, sort_keys=False)
print(f"  wrote {all_vars}")
PYEOF

# --- 3. Run the upstream playbook --------------------------------------------
echo
echo "[*] Inventory + group_vars rendered to $BUILD"
echo "[*] Next: run the upstream GOAD playbook"
echo
echo "    cd $GOAD_REPO/ansible"
for inv in "$BUILD"/inventory.*.ini; do
    sid="$(basename "$inv" .ini | sed 's/^inventory\.//')"
    cat <<EOM
    # student $sid:
    ansible-playbook -i $inv \\
        -e @$BUILD/group_vars/all.yml \\
        ../ansible/build.yml
EOM
done
echo
echo "If you want the bridge to run the playbook for you, pass --auto-run"
echo "(not implemented in this version — review the inventory + vars first)."
