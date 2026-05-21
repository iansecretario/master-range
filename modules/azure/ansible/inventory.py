#!/usr/bin/env python3
"""
Dynamic Ansible inventory for terra-range.

Two data sources, tried in order:

  1. `terraform output -json ansible_inventory`
       Fast path. Used when the operator has run `terraform apply`
       since the `ansible_inventory` output was added to outputs.tf.

  2. `terraform show -json`
       Fallback when the output isn't in state yet (e.g., the operator
       updated the repo but hasn't applied). We walk the resource list
       directly to extract VM names, IPs, role tags, and the SSH key
       path. Per-student passwords aren't recoverable this way (they
       live in `random_password` resources), so the roles that need
       them will fail with a clear error -- BUT every connectivity-
       only task (ansible -m ping, redirector / sliver / guacamole
       roles) still works.

Invoke patterns:
    ansible-inventory --list                      # required by ansible
    ansible-inventory --host <name>               # noop (we put everything in _meta)
    TERRA_ENV=/path/to/envs/azure ./inventory.py  # override env dir
"""
import json
import os
import shutil
import subprocess
import sys


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
def env_dir() -> str:
    explicit = os.environ.get("TERRA_ENV")
    if explicit:
        return explicit
    here = os.path.dirname(os.path.abspath(__file__))
    candidate = os.path.normpath(os.path.join(here, "..", "..", "..", "envs", "azure"))
    if os.path.isdir(candidate):
        return candidate
    if os.path.isfile(os.path.join(os.getcwd(), "terraform.tfstate")):
        return os.getcwd()
    sys.stderr.write(
        "ERROR: cannot locate the terraform env dir. "
        "Set TERRA_ENV=/path/to/envs/azure and retry.\n"
    )
    sys.exit(2)


def run_terraform(args: list[str]) -> str:
    if not shutil.which("terraform"):
        sys.stderr.write("ERROR: terraform not on PATH.\n")
        sys.exit(2)
    r = subprocess.run(
        ["terraform"] + args,
        cwd=env_dir(),
        capture_output=True,
        text=True,
        check=False,
    )
    if r.returncode != 0:
        sys.stderr.write(
            f"ERROR: `terraform {' '.join(args)}` failed:\n{r.stderr}\n"
        )
        sys.exit(2)
    return r.stdout


# ---------------------------------------------------------------------------
# Path A: read the ansible_inventory output (fast path)
# ---------------------------------------------------------------------------
def try_load_via_file() -> dict | None:
    """If $TERRA_INVENTORY_FILE is set, load inventory data from that JSON file.
    Used by the guacamole-as-controller mode: `./range repair` renders the
    inventory on the operator's machine (where terraform state lives) and
    pushes the JSON to guac, so guac doesn't need terraform itself."""
    fn = os.environ.get("TERRA_INVENTORY_FILE")
    if not fn:
        return None
    try:
        with open(fn) as fh:
            return json.load(fh)
    except (OSError, json.JSONDecodeError) as e:
        sys.stderr.write(f"ERROR: cannot read $TERRA_INVENTORY_FILE={fn}: {e}\n")
        sys.exit(2)


def try_load_via_output() -> dict | None:
    """Returns the inventory data dict, or None if the output isn't in state."""
    # We use `terraform show -json` instead of `terraform output -json`
    # because show doesn't fail when the requested output is absent --
    # it just returns the full state and we look for the output.
    raw = run_terraform(["show", "-json"])
    try:
        state = json.loads(raw)
    except json.JSONDecodeError:
        return None
    outputs = (state.get("values", {}) or {}).get("outputs", {}) or {}
    if "ansible_inventory" not in outputs:
        return None
    return outputs["ansible_inventory"]["value"]


# ---------------------------------------------------------------------------
# Path B: walk terraform state directly
# ---------------------------------------------------------------------------
def try_load_via_state() -> dict:
    """
    Walk `terraform show -json` to construct the same shape that
    Path A would have produced from the output. Per-student
    passwords come back as None (we can't safely extract them from
    `random_password.result` here without more module-walking; the
    roles that need them will fail at runtime with a clear error).
    """
    raw = run_terraform(["show", "-json"])
    state = json.loads(raw)

    # Walk every nested module to find Linux VMs + their NICs + public IPs.
    vms: dict[str, dict] = {}     # tf-name -> {role, tags, admin_username, nic_id}
    nics: dict[str, dict] = {}    # resource address -> {private_ip, public_ip_id}
    pubs: dict[str, str] = {}     # resource address -> ip_address

    def walk(node):
        if not isinstance(node, dict):
            return
        # `node` may be a child_module or a resource
        for r in node.get("resources", []) or []:
            t = r.get("type")
            addr = r.get("address", "")
            v = r.get("values", {}) or {}
            if t == "azurerm_linux_virtual_machine":
                vms[v.get("name", "")] = {
                    "address": addr,
                    "role": (v.get("tags") or {}).get("Role"),
                    "student_id": (v.get("tags") or {}).get("StudentId"),
                    "admin_username": v.get("admin_username"),
                    "network_interface_ids": v.get("network_interface_ids", []) or [],
                }
            elif t == "azurerm_network_interface":
                # `id` is the Azure resource ID matching what VMs reference.
                ipconf = (v.get("ip_configuration") or [{}])[0] or {}
                nics[v.get("id", "")] = {
                    "private_ip": v.get("private_ip_address") or ipconf.get("private_ip_address"),
                    "public_ip_id": ipconf.get("public_ip_address_id"),
                }
            elif t == "azurerm_public_ip":
                pubs[v.get("id", "")] = v.get("ip_address")
        for child in node.get("child_modules", []) or []:
            walk(child)

    root = (state.get("values", {}) or {}).get("root_module", {}) or {}
    walk(root)

    # Stitch VMs ↔ NICs ↔ public IPs.
    # The terraform VM name includes the range prefix (e.g.
    # "redteam-lab-adaptix"), so we use it verbatim.
    hosts = []
    redirector_pubs: dict[str, str] = {}
    for tf_name, vm in vms.items():
        if not vm.get("role"):
            # No Role tag -> probably the guacamole VM (which is named
            # `<range>-guac` but has no Role tag set in vms.tf because
            # it's a service, not a machine). We can recognise it by
            # the name suffix.
            role = "guacamole" if tf_name.endswith("-guac") else None
        else:
            role = vm["role"]
        nic_id = (vm["network_interface_ids"] or [None])[0]
        nic = nics.get(nic_id, {})
        priv = nic.get("private_ip")
        pub = pubs.get(nic.get("public_ip_id")) if nic.get("public_ip_id") else None

        host = {
            "name":          tf_name,
            "role":          role,
            "student_id":    vm.get("student_id"),
            "private_ip":    priv,
            "public_ip":     pub,
            "ssh_user":      vm.get("admin_username"),
            "linux_password": None,
            # Per-student passwords aren't extracted in fallback mode.
            "adaptix_password": None,
            "mythic_password":  None,
            "brc4_password":    None,
            # BRC4 second operator ("automation") used by brc4_payload role.
            # Null in fallback mode — the role will fail with a clear
            # message if it can't get this from the structured output.
            "brc4_automation_password": None,
            "sliver_password":  None,
            "cdn_headers":      None,
        }
        hosts.append(host)
        if role == "c2-redirector":
            # redteam-lab-adaptix-redir -> the redirector for redteam-lab-adaptix
            redirector_pubs[tf_name] = pub

    # SSH key path resolution for fallback mode (state-walk only).
    # The terraform state has the absolute filename in the
    # local_sensitive_file resource; pluck it out instead of guessing.
    # Falls back to the legacy envs/azure path if the resource isn't in
    # state yet (older deploys, pre-lab-dir change).
    ssh_key_path = None
    def find_key(node):
        nonlocal ssh_key_path
        if not isinstance(node, dict): return
        for r in node.get("resources", []) or []:
            if r.get("type") == "local_sensitive_file" and \
               r.get("name") == "operator_private_key":
                v = (r.get("values") or {})
                if v.get("filename"):
                    ssh_key_path = v["filename"]
                    return
        for c in node.get("child_modules", []) or []:
            find_key(c)
    find_key(root)
    if not ssh_key_path:
        # Legacy fallback: keys used to live in envs/azure/ before the
        # labs/<range_name>/ split. Honor that path if the new file
        # isn't in state yet.
        ssh_key_path = os.path.join(env_dir(), "operator-id_ed25519")

    return {
        "ssh_private_key_path": ssh_key_path,
        "redirector_public_ips": redirector_pubs,
        "hosts": hosts,
        "_fallback": True,
    }


# ---------------------------------------------------------------------------
# Build the inventory JSON
# ---------------------------------------------------------------------------
def build_inventory(data: dict) -> dict:
    # When running on the guacamole controller, the key lives at a
    # fixed path on that VM (deployed there by `./range repair`'s
    # bootstrap). Otherwise use the path from terraform output.
    if os.environ.get("ANSIBLE_FROM_GUAC") == "1":
        key_path = "/home/guacadmin/.ssh/operator-id_ed25519"
    else:
        key_path = os.path.expanduser(data["ssh_private_key_path"])
        # Terraform stores the filename as a string relative to its
        # CWD at apply-time (envs/azure/), e.g. "./../../labs/<name>/
        # operator-id_ed25519". Ansible runs from modules/azure/ansible/
        # so that relative path would resolve to a non-existent location
        # and SSH would fail with "no such identity: ...". Resolve to an
        # absolute path against env_dir() — the same anchor terraform
        # used — and normpath it so OpenSSH gets a clean path.
        if not os.path.isabs(key_path):
            key_path = os.path.normpath(os.path.join(env_dir(), key_path))
    redirector_pip = data.get("redirector_public_ips", {}) or {}

    # Extra operator "ian" creds, surfaced via group_vars so roles
    # don't need to know which student a host belongs to.
    operator_ian = data.get("operator_ian") or {}
    # Guacamole login-page title (replaces "APACHE GUACAMOLE"). Default
    # to "Guidem CWR" if not set — matches the generator's default.
    guac_login_title = data.get("guacamole_login_title") or "Guidem CWR"
    # Guacamole public FQDN + ACME contact email — used by the role's
    # Let's Encrypt issuance step. The FQDN is the Azure-assigned
    # cloudapp.azure.com hostname; the email is the operator-supplied
    # ACME contact (defaults to a placeholder if not set, which still
    # produces a browser-trusted cert but won't deliver renewal emails).
    guac_acme_fqdn  = data.get("guacamole_fqdn", "") or ""
    guac_acme_email = data.get("guacamole_acme_email", "") or ""
    # Fresh Guacamole manifest (base64 of the same content cloud-init
    # baked at first boot). Surfaced so the guacamole ansible role can
    # rewrite /opt/guac/manifest.json before register.py — otherwise the
    # baked-once-stale-forever manifest keeps regressing live connection
    # edits on every repair (e.g. kali RDP -> VNC migration).
    guac_manifest_b64 = data.get("guacamole_manifest_b64", "") or ""

    groups = {
        "all":          {"children": [], "vars": {
            "terra_operator_ian_username":         operator_ian.get("username", "ian"),
            "terra_operator_ian_adaptix_password": operator_ian.get("adaptix_password", ""),
            "terra_operator_ian_mythic_password":  operator_ian.get("mythic_password", ""),
            "terra_guacamole_login_title":         guac_login_title,
            "terra_guacamole_fqdn":                guac_acme_fqdn,
            "terra_guacamole_acme_email":          guac_acme_email,
            "terra_guacamole_manifest_b64":        guac_manifest_b64,
        }},
        "linux":        {"hosts": []},
        "redirectors":  {"hosts": []},
        "teamservers":  {"hosts": []},
        "adaptix":      {"hosts": []},
        "mythic":       {"hosts": []},
        "brc4":         {"hosts": []},
        "sliver":       {"hosts": []},
        "guacamole":    {"hosts": []},
        "shared":       {"hosts": []},
        "kali":         {"hosts": []},
        # Hub-tier shared services with dedicated ansible roles. Each
        # role's play in playbook.yml targets the corresponding group
        # so `--limit redteam-lab-ghostwriter` / `--tags ghostwriter`
        # work the same way they do for adaptix/mythic/sliver/etc.
        "ghostwriter":     {"hosts": []},
        "stepping-stones": {"hosts": []},
        "stepping_stones": {"hosts": []},  # ansible_play_role compat (Django snake_case)
        "redelk":          {"hosts": []},
        "elk":             {"hosts": []},
        # Windows hosts (WinRM-managed). The `windows` parent group is
        # the union; the role-named subgroups let plays target narrowly
        # (e.g. `hosts: windows-dcs`).
        "windows":              {"hosts": []},
        "windows-dcs":          {"hosts": []},
        "windows-members":      {"hosts": []},
        "windows-workstations": {"hosts": []},
        "windows-analysts":     {"hosts": []},
    }
    hostvars: dict[str, dict] = {}

    role_to_groups = {
        "c2-server":     ["linux", "teamservers", "adaptix"],
        "c2-mythic":     ["linux", "teamservers", "mythic"],
        "c2-brc4":       ["linux", "teamservers", "brc4"],
        "c2-sliver":     ["linux", "teamservers", "sliver"],
        "c2-redirector": ["linux", "redirectors"],
        "guacamole":     ["linux", "guacamole"],
        "redelk":           ["linux", "shared", "redelk"],
        "ghostwriter":      ["linux", "shared", "ghostwriter"],
        "stepping-stones":  ["linux", "shared", "stepping-stones", "stepping_stones"],
        "elk":              ["linux", "shared", "elk"],
        # The Kali attacker workstation. Scenario YAMLs tag this role
        # as "attacker" (matches modules/azure/userdata/attacker.sh);
        # we also accept the literal "kali" in case a scenario uses it.
        "attacker":         ["linux", "kali"],
        "kali":             ["linux", "kali"],
        # Windows roles → windows group + role-named subgroup. These
        # are NOT members of `linux` so Linux-only plays skip them
        # cleanly. Connection vars are swapped to WinRM in the host
        # loop below (gated on WINDOWS_ROLES).
        "windows-dc":          ["windows", "windows-dcs"],
        "windows-member":      ["windows", "windows-members"],
        "windows-workstation": ["windows", "windows-workstations"],
        "windows-analyst":     ["windows", "windows-analysts"],
        "windows-blank":       ["windows"],
        "windows-persona":     ["windows", "windows-workstations"],
    }

    # Roles whose hosts use WinRM instead of SSH. The host loop below
    # branches on this to swap connection vars. Keep aligned with the
    # windows-* entries in role_to_groups.
    WINDOWS_ROLES = {
        "windows-dc", "windows-member", "windows-workstation",
        "windows-analyst", "windows-blank", "windows-persona",
    }

    for h in data.get("hosts", []):
        name = h["name"]
        role = h["role"]
        if not role:
            continue  # e.g., shared infra rows we haven't categorized
        priv = h.get("private_ip")
        pub  = h.get("public_ip")
        ssh_user = h["ssh_user"]

        # Connection strategy depends on where Ansible runs:
        #   ANSIBLE_FROM_GUAC=1 (the deployed-as-controller mode)
        #     The playbook executes on the guacamole VM, which lives in
        #     the hub VNet and is peered with every student attacker
        #     subnet. From guac, every teamserver's PRIVATE IP is
        #     directly reachable (NSG from-hub rule). So: use private
        #     IP directly, no ProxyJump, no public IP needed.
        #
        #   default (operator-laptop mode)
        #     The playbook runs on the operator's machine. Teamservers
        #     have no public IP and the laptop can't reach private IPs
        #     directly, so we ProxyCommand through the redirector's
        #     public IP. (We use ProxyCommand, not ProxyJump, because
        #     ssh's child ProxyJump process doesn't inherit the parent's
        #     -i flag, which causes auth failures.)
        from_guac = os.environ.get("ANSIBLE_FROM_GUAC") == "1"
        jump = redirector_pip.get(f"{name}-redir")
        if from_guac:
            # Always use private IP. Even hosts with a public IP
            # (redirectors, guac itself) are reachable on their private.
            ansible_host = priv or pub
            ssh_common = ""
        elif pub:
            ansible_host = pub
            ssh_common = ""
        elif jump:
            ansible_host = priv
            ssh_common = (
                f"-o ProxyCommand='ssh -i {key_path} "
                f"-o StrictHostKeyChecking=no "
                f"-o UserKnownHostsFile=/dev/null "
                f"-o IdentitiesOnly=yes "
                f"-W %h:%p {ssh_user}@{jump}'"
            )
        else:
            ansible_host = priv or "0.0.0.0"
            ssh_common = ""

        vars_ = {
            "ansible_host":            ansible_host,
            "ansible_user":            ssh_user,
            "ansible_ssh_private_key_file": key_path,
            "ansible_python_interpreter":   "/usr/bin/python3",
            "ansible_ssh_common_args":      ssh_common,
            # Domain-specific facts the roles use:
            "terra_role":        role,
            "terra_student_id":  h.get("student_id"),
            "terra_private_ip":  priv,
            "terra_public_ip":   pub,
            "terra_jump_host":   jump,
            "terra_adaptix_password": h.get("adaptix_password"),
            # Per-CDN beacon callback URLs, set by terraform's listeners.tf
            # so the Adaptix role can register listeners with real
            # callback addresses instead of the historical CHANGEME-*
            # placeholders. None on non-c2-server hosts.
            "terra_adaptix_callbacks": h.get("adaptix_callbacks"),
            # Mythic http-profile beacon callback URL. Resolves to the
            # AFD-fronted mythic redirector subdomain when advanced_c2
            # is enabled (e.g. https://cdn-edge-02.example.com), else
            # null. The Mythic role uses this to pre-fill the http
            # profile's `default_value` so the Create Payload wizard
            # lands populated. Null on non-c2-mythic hosts.
            "terra_mythic_callback_host": h.get("mythic_callback_host"),
            "terra_mythic_password":  h.get("mythic_password"),
            "terra_brc4_password":    h.get("brc4_password"),
            # BRC4 second operator ("automation") — dedicated identity
            # for the brc4_payload Ansible role's WebSocket API session
            # so it doesn't kick the operator's Commander GUI session
            # off the shared :9000 endpoint. See listeners.tf
            # `brc4_profile.user_list.automation` and
            # passwords.tf `random_password.brc4_automation`.
            # Null on non-c2-brc4 hosts.
            "terra_brc4_automation_password": h.get("brc4_automation_password"),
            # Per-student BRC4 c2.profile JSON (5 HTTPS listeners +
            # commander), rendered by listeners.tf. The brc4 role syncs
            # /opt/bruteratel/{profiles/c2.profile,autosave.profile}
            # against this on every repair. Null on non-c2-brc4 hosts.
            "terra_brc4_profile":     h.get("brc4_profile"),
            "terra_sliver_password":  h.get("sliver_password"),
            "terra_cdn_headers":      h.get("cdn_headers"),
        }
        # Windows hosts: swap SSH connection vars for WinRM. HTTP on
        # 5985 with basic auth + AllowUnencrypted (lab-tier — the
        # WinRM listener is gated by the per-spoke NSG to the hub /
        # guacamole subnet only). Switching to HTTPS-over-5986 is a
        # separate hardening pass (self-signed cert + the same
        # cert_validation=ignore until a proper CA is wired up).
        if role in WINDOWS_ROLES:
            vars_["ansible_connection"]                   = "winrm"
            # ansible_user MUST be the Windows admin username — that's
            # `windows_admin_user` from the host entry (sourced from
            # outputs.tf's m.win_admin_user, which is `rangeadmin` by
            # default or var.domain.admin_user on the DC). Falling
            # back to `ssh_user` (=="ranger", the Linux convention)
            # would fail with "credentials rejected" because no
            # `ranger` user exists on Windows — only `rangeadmin`.
            vars_["ansible_user"] = (
                h.get("windows_admin_user")
                or h.get("ssh_user", "")
            )
            # ansible_password for Windows hosts MUST be the random
            # local-admin password terraform planted at VM-create
            # time — that's the `windows_admin_password` field on the
            # host entry (sourced from outputs.tf's
            # `local.effective_domain_password[student_id]`). Falling
            # back to `linux_password` would pass the YAML's
            # "Lab!Linux1" placeholder, which is wrong for Windows and
            # triggers `basic: the specified credentials were rejected
            # by the server` from the WinRM listener.
            vars_["ansible_password"] = (
                h.get("windows_admin_password")
                or h.get("linux_password", "")
            )
            vars_["ansible_winrm_transport"]              = "basic"
            vars_["ansible_winrm_scheme"]                 = "http"
            vars_["ansible_port"]                         = 5985
            vars_["ansible_winrm_server_cert_validation"] = "ignore"
            # Strip the SSH-specific entries — no python3, no key,
            # no ssh_common_args on Windows.
            for k in ("ansible_ssh_private_key_file",
                      "ansible_python_interpreter",
                      "ansible_ssh_common_args"):
                vars_.pop(k, None)

        hostvars[name] = vars_

        for g in role_to_groups.get(role, ["linux"]):
            groups[g]["hosts"].append(name)

    groups["all"]["children"] = [
        g for g in ("redirectors", "teamservers", "adaptix", "mythic",
                    "brc4", "sliver", "guacamole", "shared", "kali",
                    "ghostwriter", "stepping-stones", "stepping_stones",
                    "redelk", "elk",
                    "windows", "windows-dcs", "windows-members",
                    "windows-workstations", "windows-analysts")
        if groups[g]["hosts"]
    ]

    out = {"_meta": {"hostvars": hostvars}}
    out.update(groups)
    return out


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
def main() -> None:
    # --emit-data: print the raw inventory data dict (NOT the ansible
    # inventory format). Used by `./range repair` to render a single
    # JSON file from terraform state on the operator's machine and push
    # it to guacamole, where inventory.py reads it via $TERRA_INVENTORY_FILE.
    if "--emit-data" in sys.argv:
        data = try_load_via_output() or try_load_via_state()
        print(json.dumps(data))
        return

    if "--list" in sys.argv:
        # Resolution order:
        #   1. $TERRA_INVENTORY_FILE  (guac-controller mode -- file pushed
        #      from operator's machine)
        #   2. terraform output 'ansible_inventory'  (full mode w/ creds)
        #   3. terraform show -json (state walk fallback when output absent)
        data = try_load_via_file()
        if data is None:
            data = try_load_via_output()
        if data is None:
            data = try_load_via_state()
            if sys.stderr.isatty():
                sys.stderr.write(
                    "[inventory] note: ansible_inventory tf output not in state yet; "
                    "falling back to state walk. Per-student passwords will be null. "
                    "Run `terraform apply` in envs/azure to compute the structured output.\n"
                )
        print(json.dumps(build_inventory(data), indent=2))
        return
    if "--host" in sys.argv:
        print("{}")
        return
    sys.stderr.write("usage: inventory.py --list | --host <name>\n")
    sys.exit(1)


if __name__ == "__main__":
    main()
