#!/usr/bin/env python3
"""
generate.py — cyber range Terraform generator (multi-student).

Reads a YAML range definition, validates it, expands the machine template
across N students, and writes terraform.tfvars.json into envs/<provider>/.

Usage:
    python generator/generate.py generator/range.example.yaml
    python generator/generate.py path/to/your.yaml --provider azure
    python generator/generate.py path/to/your.yaml --students 5
"""

from __future__ import annotations

import argparse
import ipaddress
import json
import os
import string
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    print("ERROR: PyYAML required. pip install -r generator/requirements.txt",
          file=sys.stderr)
    sys.exit(1)


REPO = Path(__file__).resolve().parent.parent
PERSONA_DIR = REPO / "personas"
GEOFENCE_DIR = REPO / "geofence"


def _fetch_operator_public_ip() -> str | None:
    """Best-effort lookup of the operator's current public IPv4.

    Tries three independent sources; returns the first valid IPv4
    string or None if every source failed (offline, blocked, etc.).
    """
    import urllib.error
    import urllib.request

    sources = [
        "https://api.ipify.org",
        "https://ipv4.icanhazip.com",
        "https://checkip.amazonaws.com",
    ]
    for url in sources:
        try:
            with urllib.request.urlopen(url, timeout=5) as resp:
                ip = resp.read().decode("ascii", "ignore").strip()
            parts = ip.split(".")
            if (len(parts) == 4
                    and all(p.isdigit() and 0 <= int(p) <= 255 for p in parts)):
                return ip
        except (urllib.error.URLError, OSError, UnicodeDecodeError):
            continue
    return None


def _expand_geofence(country_codes: list[str]) -> list[str]:
    """Read geofence/<CC>.txt for each country; return merged CIDR list.

    Returns a deduped list, one country at a time in operator-supplied
    order, capped at NSG_TOTAL_PREFIX_CAP across all rules.

    Azure NSG hard limits in play here:
      - Per single security rule: 4000 source_address_prefixes.
      - PER WHOLE NSG (sum across all rules): 6000 source prefixes.
        This is the killer — chunking per-rule doesn't help when the
        same CIDR list is referenced across multiple service rules
        (https + ssh + kibana = 3× the cost in the same NSG).

    The hub_mgmt NSG fans the same CIDR list across 3 services. With
    a 6000-prefix budget that means each service rule may use at most
    ~2000 CIDRs. We cap at 1800 to leave headroom for the operator's
    own /32 and any future service additions.
    """
    cidrs: list[str] = []
    missing: list[str] = []
    per_country: list[tuple[str, list[str]]] = []
    for cc in country_codes:
        ccu = cc.strip().upper()
        if not ccu:
            continue
        path = GEOFENCE_DIR / f"{ccu}.txt"
        if not path.exists() or path.stat().st_size == 0:
            missing.append(ccu)
            continue
        country_cidrs = [
            line.strip() for line in path.read_text().splitlines()
            if line.strip() and not line.strip().startswith("#")
        ]
        per_country.append((ccu, country_cidrs))
    if missing:
        fail(
            f"guacamole_allow_countries references countries with no "
            f"geofence data: {sorted(missing)}. Run "
            f"`./scripts/refresh-geofence.sh {' '.join(missing)}` first."
        )

    # 6000-prefix-per-NSG cap (Azure hard limit), divided across the 3
    # services that fan-out the CIDR list (https/ssh/kibana). Operator
    # IP /32 + a small safety margin → 1800 effective per-service cap.
    NSG_TOTAL_PREFIX_CAP = 1800

    # Merge in operator-listed order; stop early when adding the next
    # country would push past the cap. This way the FIRST listed country
    # is guaranteed to fit (operator's own region), the rest are bonus.
    seen: set[str] = set()
    out: list[str] = []
    dropped: list[tuple[str, int]] = []
    for ccu, country_cidrs in per_country:
        before = len(out)
        for c in country_cidrs:
            if c in seen:
                continue
            if len(out) >= NSG_TOTAL_PREFIX_CAP:
                break
            seen.add(c)
            out.append(c)
        added = len(out) - before
        if added < len(country_cidrs):
            dropped.append((ccu, len(country_cidrs) - added))

    if dropped:
        msg = ", ".join(f"{cc} (-{n} CIDRs)" for cc, n in dropped)
        print(
            f"WARNING: geofence trimmed to NSG_TOTAL_PREFIX_CAP={NSG_TOTAL_PREFIX_CAP} "
            f"to fit Azure's 6000-prefix-per-NSG limit. Dropped tail: {msg}. "
            f"Reorder guacamole_allow_countries to keep your priority countries.",
            file=sys.stderr,
        )

    return out

VALID_ROLES = {
    "windows-dc",
    "windows-member",
    "windows-workstation",
    "windows-blank",        # bare Windows server (used for GOAD topology)
    "windows-analyst",      # Windows 10 + Mandiant FLARE-VM (RE/malware
                            # analysis toolset). Sits in the attacker
                            # subnet alongside Kali; 4 vCPU/16 GB,
                            # 256 GB disk. Bootstrap PS schedules
                            # the FLARE installer on first RDP logon
                            # (~1-2 hr unattended install).
    "linux-target",
    "attacker",
    "c2-server",            # Adaptix teamserver
    "c2-mythic",            # Mythic teamserver
    "c2-brc4",              # Brute Ratel C4 teamserver (license-gated;
                            # scenarios that use this MUST set
                            # students.count: 1).
    "c2-sliver",            # Sliver C2 teamserver (BishopFox; OSS).
    "c2-redirector",
}

# Roles that deploy in the hub (shared across all students), not per-student.
# C2 teamservers are deliberately NOT in this list — Adaptix, Mythic, and
# BRC4 are all per-student.
SHARED_ROLES = {
    "ghostwriter",
    "stepping-stones",
    "redelk",
}

VALID_OS = {
    "windows-server-2019",
    "windows-server-2022",
    "windows-server-2025",
    "windows-10",
    "windows-11",
    "ubuntu-22",
    "ubuntu-24",
    "debian-12",
    "kali",
}

VALID_SIZES = {"small", "medium", "large"}
MAX_MACHINES_PER_STUDENT = 100
MAX_STUDENTS = 254  # /22 per student inside a /8 plan


def fail(msg: str) -> None:
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(1)


def validate(cfg: dict) -> None:
    for required in ("range_name", "provider", "machines", "services"):
        if required not in cfg:
            fail(f"missing required top-level key: {required}")

    # Supported providers:
    #   aws   — modules/aws (existing)
    #   azure — modules/azure (existing, default)
    #   gcp   — modules/gcp (added 2026 Q2)
    #   both  — emit both AWS + Azure tfvars (legacy convenience; doesn't
    #           include gcp because it'd produce 3-way emit which isn't
    #           a meaningful workflow)
    if cfg["provider"] not in ("aws", "azure", "gcp", "both"):
        fail("provider must be one of: aws, azure, gcp, both")

    students = cfg.get("students") or {"count": 1, "tenancy": "shared",
                                       "name_format": "s{n:02d}"}
    cfg["students"] = students
    count = int(students.get("count", 1))
    if count < 1 or count > MAX_STUDENTS:
        fail(f"students.count must be 1..{MAX_STUDENTS}")
    if students.get("tenancy", "shared") not in ("shared", "isolated"):
        fail("students.tenancy must be 'shared' or 'isolated'")

    machines = cfg["machines"]
    if not isinstance(machines, list) or not machines:
        fail("machines must be a non-empty list")
    if len(machines) > MAX_MACHINES_PER_STUDENT:
        fail(f"too many machines per student "
             f"({len(machines)}); max is {MAX_MACHINES_PER_STUDENT}")

    # name_format sanity check.
    # In multi-student mode, the name_format MUST embed `{n}` somewhere so
    # each student gets a unique sid (alice/bob/01/02/...). Without it,
    # every per_student=true machine collapses to the same name and the
    # expansion silently produces duplicates — terraform then fails opaquely
    # on `azurerm_linux_virtual_machine.machine["lab-kali"]` already-exists.
    # Catch it here with a clear message.
    name_fmt_raw = students.get("name_format", "s{n:02d}")
    if count > 1 and "{n" not in name_fmt_raw:
        any_per_student = any(
            m.get("per_student", True) for m in machines
        )
        if any_per_student:
            fail(f"students.name_format='{name_fmt_raw}' doesn't contain a "
                 f"`{{n}}` placeholder. In multi-student mode (count={count}) "
                 f"with any per_student=true machines, the format must "
                 f"render each student to a UNIQUE id. Use e.g. "
                 f"'{{n:02d}}' for numeric (01, 02, ...) or 'lab{{n:02d}}' "
                 f"for a prefixed form.")

    # BRC4 license constraint: the range can only have one BRC4 activation.
    # Two ways to be compliant when students.count > 1:
    #   1. No c2-brc4 machine in the scenario at all (fine).
    #   2. The c2-brc4 machine has `per_student: false` — then it's emitted
    #      exactly once and used only by the operator (students never get
    #      BRC4 in this shape). See the redteam-lab.yaml comment near the
    #      brc4 entry for the rationale.
    # We only fail when there's a c2-brc4 machine flagged for per-student
    # expansion AND students.count > 1 — that would require N license
    # activations, which the BRC4 vendor doesn't sell.
    brc4_per_student = any(
        m.get("role") == "c2-brc4" and m.get("per_student", True)
        for m in machines
    )
    if brc4_per_student and count > 1:
        fail(f"c2-brc4 with `per_student: true` requires students.count: 1 "
             f"(BRC4 license caps the range at one teamserver activation; "
             f"got students.count: {count}). To run BRC4 alongside a "
             f"multi-student deploy, set `per_student: false` on the "
             f"c2-brc4 machine — it becomes operator-only, students "
             f"never see it.")

    seen_names = set()
    role_counts = {r: 0 for r in VALID_ROLES}
    for m in machines:
        for k in ("name", "role", "os"):
            if k not in m:
                fail(f"machine entry missing '{k}': {m}")
        if m["role"] not in VALID_ROLES:
            fail(f"machine {m['name']}: role must be one of "
                 f"{sorted(VALID_ROLES)}")
        if m["os"] not in VALID_OS:
            fail(f"machine {m['name']}: os must be one of {sorted(VALID_OS)}")
        if m.get("size", "small") not in VALID_SIZES:
            fail(f"machine {m['name']}: size must be one of "
                 f"{sorted(VALID_SIZES)}")
        if m["name"] in seen_names:
            fail(f"duplicate machine name: {m['name']}")
        seen_names.add(m["name"])
        if not all(c in string.ascii_lowercase + string.digits + "-"
                   for c in m["name"]):
            fail(f"machine name must be lowercase alnum/hyphen: {m['name']}")
        role_counts[m["role"]] += 1

        # Lab-access fields (used by redteam-lab).
        if m.get("assigned_user"):
            if m["role"] not in ("windows-member", "windows-workstation"):
                fail(f"machine {m['name']}: assigned_user only allowed on "
                     f"windows-member or windows-workstation (got "
                     f"role={m['role']})")
            lab_users = (cfg.get("domain") or {}).get("lab_users") or []
            lab_names = {u["name"] for u in lab_users
                         if isinstance(u, dict) and "name" in u}
            if m["assigned_user"] not in lab_names:
                fail(f"machine {m['name']}: assigned_user "
                     f"'{m['assigned_user']}' is not in domain.lab_users "
                     f"(seen: {sorted(lab_names) or '[]'}). Add the user to "
                     f"the domain.lab_users list or remove the assignment.")
        if m.get("enable_root_ssh"):
            if m["role"] != "linux-target":
                fail(f"machine {m['name']}: enable_root_ssh only allowed on "
                     f"linux-target (got role={m['role']})")

        # Persona: linux-target uses .sh, windows-* uses .ps1.
        persona = m.get("persona")
        if persona:
            if m["role"] == "linux-target":
                ext = ".sh"
            elif m["role"] in ("windows-member", "windows-workstation"):
                ext = ".ps1"
            else:
                fail(f"machine {m['name']}: persona is only allowed on "
                     f"linux-target / windows-member / windows-workstation "
                     f"(got role={m['role']})")
            persona_path = PERSONA_DIR / f"{persona}{ext}"
            if not persona_path.is_file():
                fail(f"machine {m['name']}: persona file not found: "
                     f"{persona_path}")
            if persona_path.stat().st_size == 0:
                fail(f"machine {m['name']}: persona file is empty: "
                     f"{persona_path}")

    if role_counts["windows-dc"] > 1:
        fail("only one windows-dc per student template is allowed")
    if role_counts["c2-server"] > 1:
        fail("only one c2-server (Adaptix) per student template is allowed "
             "(static IP is pinned to 10.<n>.1.5)")
    if role_counts["c2-mythic"] > 1:
        fail("only one c2-mythic per student template is allowed "
             "(static IP is pinned to 10.<n>.1.7)")
    if role_counts["c2-brc4"] > 1:
        fail("only one c2-brc4 per student template is allowed "
             "(static IP is pinned to 10.<n>.1.9). Combined with the "
             "students.count: 1 constraint above, this means exactly "
             "one BRC4 teamserver per range.")
    if role_counts["c2-sliver"] > 1:
        fail("only one c2-sliver per student template is allowed "
             "(static IP is pinned to 10.<n>.1.11)")

    # Multiple c2-redirectors are allowed (one per C2 framework). Each
    # MUST declare `fronts: <role>` and exactly one redirector per
    # fronted role. The fronted role must exist in the same template.
    valid_fronts = ("c2-server", "c2-mythic", "c2-brc4", "c2-sliver")
    redir_fronts = []
    for m in machines:
        if m["role"] != "c2-redirector":
            continue
        fronts = m.get("fronts")
        if not fronts:
            fail(f"machine {m['name']}: c2-redirector requires "
                 f"`fronts: {' | '.join(valid_fronts)}`")
        if fronts not in valid_fronts:
            fail(f"machine {m['name']}: fronts must be one of "
                 f"{valid_fronts}, got '{fronts}'")
        redir_fronts.append(fronts)
    # Each c2-redirector must front a distinct C2 (no two redirectors
    # front the same teamserver in the same student).
    if len(redir_fronts) != len(set(redir_fronts)):
        fail("multiple c2-redirectors front the same C2 in this template — "
             "only one redirector per (c2-server | c2-mythic) is allowed")
    # Each c2-redirector's fronted C2 must actually exist in the
    # per-student `machines:` template.
    for fronts in redir_fronts:
        if role_counts.get(fronts, 0) < 1:
            fail(f"c2-redirector fronts '{fronts}' but no machine of "
                 f"that role exists in the template")
    if (cfg.get("domain", {}).get("enabled")
            and role_counts["windows-dc"] == 0):
        fail("domain.enabled is true but no windows-dc machine defined")

    # static_ip format check.
    #
    # Two valid forms depending on per_student:
    #   per_student: true   (or default in single-student mode): last-octet
    #     integer as a string, e.g. "10". The generator computes the
    #     full address as 10.<student_index>.0.<octet> at expand time.
    #   per_student: false  (shared targets / operator-only machines):
    #     full dotted IPv4 address, e.g. "10.1.0.10". Preserved verbatim
    #     because shared machines live on a FIXED subnet (10.1.0.0/24 for
    #     the targets pod), not on a per-student subnet, so the octet-only
    #     form can't express the address.
    # In single-student mode (count == 1) both forms accept any well-formed
    # IPv4 string — there's no expansion happening either way.
    for m in machines:
        if "static_ip" not in m:
            continue
        ip = str(m["static_ip"])
        is_per_student = bool(m.get("per_student", True))
        if count > 1 and is_per_student:
            # last-octet form required
            try:
                octet = int(ip)
            except ValueError:
                fail(f"{m['name']}: in multi-student mode a per_student=true "
                     f"machine's static_ip must be the last-octet integer as "
                     f"a string (e.g. '10'), got '{ip}'. If this machine is a "
                     f"shared target (one copy across all students), set "
                     f"per_student: false and use the full IP form.")
            if not 4 <= octet <= 250:
                fail(f"{m['name']}: static_ip octet out of range: {octet}")
        else:
            # Single-student mode OR shared (per_student=false) machine:
            # accept any valid IPv4. ipaddress.ip_address raises on
            # malformed input.
            try:
                ipaddress.ip_address(ip)
            except ValueError:
                fail(f"{m['name']}: invalid static_ip: {ip}")

    if any(m.get("domain_join") for m in machines) \
            and not cfg.get("domain", {}).get("enabled"):
        fail("a machine has domain_join=true but domain.enabled is false")

    # domain.lab_users: optional list of {name, password}. Each must be
    # a valid AD sAMAccountName.
    lab_users = (cfg.get("domain") or {}).get("lab_users") or []
    if not isinstance(lab_users, list):
        fail("domain.lab_users must be a list of {name, password} objects")
    seen_lab = set()
    for u in lab_users:
        if not isinstance(u, dict) or "name" not in u or "password" not in u:
            fail(f"domain.lab_users entry must have name + password: {u}")
        n = u["name"]
        if not all(c.isalnum() or c in "._-" for c in n) or len(n) > 20:
            fail(f"domain.lab_users[{n}]: invalid sAMAccountName "
                 f"(alphanum/dot/hyphen/underscore, ≤20 chars)")
        if n in seen_lab:
            fail(f"domain.lab_users: duplicate name '{n}'")
        seen_lab.add(n)

    if not any(m["role"] in ("attacker", "c2-server") for m in machines):
        print("WARN: no attacker or c2-server machine defined", file=sys.stderr)

    # ---- shared_infrastructure ------------------------------------------
    shared = cfg.get("shared_infrastructure") or []
    if shared and not isinstance(shared, list):
        fail("shared_infrastructure must be a list")
    seen_shared = set()
    for s in shared:
        for k in ("name", "role", "os"):
            if k not in s:
                fail(f"shared_infrastructure entry missing '{k}': {s}")
        if s["role"] not in SHARED_ROLES:
            fail(f"shared_infrastructure {s['name']}: role must be one of "
                 f"{sorted(SHARED_ROLES)}")
        if s["os"] not in VALID_OS:
            fail(f"shared_infrastructure {s['name']}: invalid os {s['os']}")
        if s.get("size", "small") not in VALID_SIZES:
            fail(f"shared_infrastructure {s['name']}: invalid size")
        if s["name"] in seen_shared:
            fail(f"duplicate shared_infrastructure name: {s['name']}")
        seen_shared.add(s["name"])
        if s["name"] in seen_names:
            fail(f"shared_infrastructure name '{s['name']}' collides with "
                 f"a per-student machine name")

    # ---- advanced_c2 -----------------------------------------------------
    adv = cfg.get("advanced_c2") or {"enabled": False}
    cfg["advanced_c2"] = adv
    if adv.get("enabled"):
        if not adv.get("domain"):
            fail("advanced_c2.enabled=true requires advanced_c2.domain")
        if not any(m["role"] == "c2-redirector" for m in machines):
            fail("advanced_c2.enabled=true but no c2-redirector role in "
                 "machines — AFD has no origin to point at")

    # ---- goad ------------------------------------------------------------
    # Don't materialise an empty goad block into cfg — scenarios without
    # goad shouldn't emit a `goad` tfvar (module doesn't declare it).
    goad = cfg.get("goad") or {"enabled": False}
    if goad.get("enabled"):
        # Required identity fields, all customisable
        for field in ("root_domain", "child_domain", "separate_forest_domain"):
            if not goad.get(field):
                fail(f"goad.enabled=true requires goad.{field}")
            v = goad[field]
            if "." not in v or " " in v:
                fail(f"goad.{field}='{v}' must be a dotted FQDN with no spaces")

        # Custom hostnames (NetBIOS-safe, ≤15 chars). Default to upstream names.
        defaults = {
            "root_dc_name":     "kingslanding",
            "child_dc_name":    "winterfell",
            "separate_dc_name": "meereen",
            "member_name":      "castelblack",
        }
        seen_hosts = set()
        for k, default in defaults.items():
            goad.setdefault(k, default)
            v = goad[k]
            if len(v) > 15:
                fail(f"goad.{k} '{v}' exceeds 15-char NetBIOS limit")
            if not all(c.isalnum() or c in "-" for c in v):
                fail(f"goad.{k} '{v}' must be lowercase alnum/hyphen")
            if v in seen_hosts:
                fail(f"goad: duplicate hostname '{v}' across DC/member fields")
            seen_hosts.add(v)

        # Child domain should be a subdomain of root for the parent-child
        # trust to make sense (upstream convention).
        if not goad["child_domain"].endswith("." + goad["root_domain"]):
            print(f"WARN: goad.child_domain '{goad['child_domain']}' is not a "
                  f"subdomain of goad.root_domain '{goad['root_domain']}'. "
                  f"Upstream playbook expects parent-child trust.",
                  file=sys.stderr)

        # ---- users roster --------------------------------------------
        users = goad.get("users")
        if users is not None and not isinstance(users, list):
            fail("goad.users must be a list of user objects")
        for u in (users or []):
            for required in ("name", "password", "domain"):
                if required not in u:
                    fail(f"goad.users entry missing '{required}': {u}")
            if u["domain"] not in ("root", "child", "separate"):
                fail(f"goad.users[{u['name']}].domain must be one of "
                     f"root/child/separate (got {u['domain']})")
            if not all(c.isalnum() or c in "._-" for c in u["name"]):
                fail(f"goad.users[{u['name']}]: invalid sAMAccountName")

        # ---- service-account roster ----------------------------------
        svcs = goad.get("service_accounts")
        if svcs is not None and not isinstance(svcs, list):
            fail("goad.service_accounts must be a list of objects")
        for s in (svcs or []):
            for required in ("name", "password", "domain"):
                if required not in s:
                    fail(f"goad.service_accounts entry missing '{required}': {s}")
            if s["domain"] not in ("root", "child", "separate"):
                fail(f"goad.service_accounts[{s['name']}].domain invalid")
            if s.get("kerberoastable") and not s.get("spn"):
                fail(f"goad.service_accounts[{s['name']}]: kerberoastable=true "
                     f"requires an SPN (e.g. MSSQLSvc/host.domain:1433)")

        # ---- machine-template coverage check -------------------------
        # The scenario's machines list must contain machines whose
        # base_name matches the four GOAD hostnames above. We don't
        # auto-generate them — we just enforce the operator wired
        # them up. The bridge script later maps base_name → role/IP.
        names_in_template = {m["name"] for m in machines}
        for k in ("root_dc_name", "child_dc_name",
                  "separate_dc_name", "member_name"):
            if goad[k] not in names_in_template:
                fail(f"goad.enabled=true but no machine named '{goad[k]}' "
                     f"in machines: list (referenced by goad.{k})")

        # Optional-service toggles default to true
        for k, dflt in (
            ("install_mssql_on_root",    True),
            ("install_mssql_on_member",  True),
            ("install_iis_on_root",      True),
            ("seed_kerberoast",          True),
            ("seed_asreproast",          True),
            ("seed_acl_misconfigs",      True),
            ("seed_unconstrained_deleg", True),
            ("seed_constrained_deleg",   True),
            ("seed_dnsadmins",           True),
            ("seed_smbv1",               True),
        ):
            goad.setdefault(k, dflt)


def expand_machines(cfg: dict) -> list[dict]:
    """
    Expand the machine template across students.

    Each machine can opt in or out of per-student expansion via the
    `per_student` field (default `true` for backward compat with existing
    multi-student scenarios that pre-date this flag):

      per_student: true   (default)
        When students.count > 1, the machine is emitted N times with names
        `<base>-<sid>` (e.g. `kali-alice`, `kali-bob`, ...) and student_id
        set to each student's sid. When students.count == 1, the machine
        is emitted once with student_id="" and student_index=1 — same
        behavior as before this flag existed.

      per_student: false
        The machine is emitted exactly ONCE regardless of students.count,
        with student_id="" and student_index=0. This is for SHARED
        resources every student uses: target-lab Windows boxes (dc01,
        srv01, ws10, ws11, analyst), the shared linux01 target, the
        operator-only BRC4 teamserver, etc. terraform's NIC/subnet logic
        recognises student_index==0 as "place on the shared targets
        subnet, not a per-student attacker subnet" (see B3 in ROADMAP.md
        §1b).

    student_index conventions emitted by this function:
      0  = shared machine (per_student=false), single-deploy mode never
           uses this value
      1..N = per-student machine for student N (per_student=true with
             students.count > 1) — also the value used in the single-
             student case (count=1, n=1, sid="") for backward compat
             with downstream code that does `10.{student_index}.0.X`
             CIDR math.

    Other transformations applied in this pass:
      - For windows-dc machines when domain.enabled is true, the local
        admin is FORCED to equal domain.admin_user/admin_password —
        after Install-ADDSForest the local admin becomes the Domain
        Administrator, and members must join using that exact credential.
      - static_ip on per-student machines is rebuilt as
        `10.<student_index>.0.<octet>`. On shared machines (student_index=0)
        the YAML's static_ip is preserved verbatim — operators set it to
        the shared targets subnet's IP (e.g. dc01 -> 10.1.0.10).
      - For linux-target / windows-member / windows-workstation machines
        with `persona: <name>`, the persona script content from
        personas/<name>.{sh,ps1} is read and base64-encoded so the
        module can embed it into the cloud-init / RunCommand payload.
    """
    import base64

    students = cfg["students"]
    count = int(students["count"])
    name_fmt = students.get("name_format", "s{n:02d}")
    defaults = cfg.get("default_credentials", {})
    domain = cfg.get("domain", {}) or {}
    domain_enabled = bool(domain.get("enabled", False))

    # Cache persona contents (read each file at most once).
    persona_cache: dict[str, str] = {}

    def _load_persona(name: str, role: str) -> str:
        ext = ".ps1" if role.startswith("windows") else ".sh"
        key = f"{name}{ext}"
        if key in persona_cache:
            return persona_cache[key]
        path = PERSONA_DIR / key
        encoded = base64.b64encode(path.read_bytes()).decode("ascii")
        persona_cache[key] = encoded
        return encoded

    def _build_record(m: dict, n: int, sid: str) -> dict:
        """Render one machine record at student_index=n with student_id=sid.

        Called once per (machine × student) for per-student machines, and
        once per shared machine (with n=0, sid="").
        """
        base = m["name"]
        full_name = f"{sid}-{base}" if sid else base

        # static_ip rewrite: only applies in true multi-student mode for
        # per-student machines (sid set + n>=1). Shared machines (n==0)
        # use the YAML's static_ip verbatim — the operator sets it to the
        # shared targets subnet (10.1.0.X). Single-student mode (count==1,
        # n==1, sid="") also preserves the YAML value as today.
        static_ip = ""
        if m.get("static_ip", "") != "":
            if sid:  # multi-student per-student case
                static_ip = f"10.{n}.0.{int(m['static_ip'])}"
            else:    # single-student OR shared machine
                static_ip = str(m["static_ip"])

        # Default win admin credentials
        win_user = m.get(
            "win_admin_user",
            defaults.get("windows_local_admin", "rangeadmin"))
        win_pass = m.get(
            "win_admin_password",
            defaults.get("windows_local_password", "P@ssw0rd!Local1"))

        # DC: align local admin with domain admin
        if m["role"] == "windows-dc" and domain_enabled:
            win_user = domain.get("admin_user", win_user)
            win_pass = domain.get("admin_password", win_pass)

        persona_name = m.get("persona", "") or ""
        persona_b64  = _load_persona(persona_name, m["role"]) if persona_name else ""

        return {
            "name":              full_name,
            "base_name":         base,
            "student_id":        sid,
            "student_index":     n,
            "role":              m["role"],
            "os":                m["os"],
            "size":              m.get("size", "small"),
            "static_ip":         static_ip,
            "domain_join":       bool(m.get("domain_join", False)),
            "win_admin_user":    win_user,
            "win_admin_password": win_pass,
            "linux_user":        m.get(
                "linux_user", defaults.get("linux_user", "ranger")),
            "linux_password":    m.get(
                "linux_password",
                defaults.get("linux_password", "P@ssw0rd!Linux1")),
            "persona_name":      persona_name,
            "persona_b64":       persona_b64,
            "fronts":            m.get("fronts", "") or "",
            "callsign":          m.get("callsign", "") or "",
            # Lab-access (used by redteam-lab; default empty/false).
            "assigned_user":     m.get("assigned_user", "") or "",
            "enable_root_ssh":   bool(m.get("enable_root_ssh", False)),
            # Emit per_student through to terraform's machine schema so
            # the NIC subnet picker / NSG generator (B3, B4) can route
            # this VM correctly. terraform itself doesn't trigger any
            # behavior off this field today; it's plumbing for the
            # subnet/NSG work coming in the next phase.
            "per_student":       bool(m.get("per_student", True)),
        }

    out = []
    for m in cfg["machines"]:
        is_per_student = bool(m.get("per_student", True))

        if count == 1:
            # Single-student / solo-operator mode: every machine emits
            # exactly once, sid="", n=1. per_student has no effect here
            # because there's only one student anyway. This is identical
            # to pre-`per_student` behavior.
            out.append(_build_record(m, n=1, sid=""))

        elif is_per_student:
            # Multi-student mode, machine is per-student: emit N copies,
            # one per student, with student_id and student_index set.
            for n in range(1, count + 1):
                sid = name_fmt.format(n=n)
                out.append(_build_record(m, n=n, sid=sid))

        else:
            # Multi-student mode, machine is shared: emit exactly once
            # with student_id="" (consistent with single-student
            # convention) and student_index=0 (sentinel for "no specific
            # student"; terraform NIC/subnet logic in B3 will treat 0 as
            # "shared targets subnet placement").
            out.append(_build_record(m, n=0, sid=""))

    return out


def build_student_users(cfg: dict) -> list[dict]:
    """Generate the per-student Guacamole user list."""
    students = cfg["students"]
    count = int(students["count"])
    if count <= 1:
        return []
    guac = cfg["services"]["guacamole"]
    prefix = guac.get("student_user_prefix", "student-")
    pw_tmpl = guac.get("student_password_template", "Student!{n:02d}")
    name_fmt = students.get("name_format", "s{n:02d}")
    out = []
    for n in range(1, count + 1):
        sid = name_fmt.format(n=n)
        out.append({
            "student_id": sid,
            "username":   f"{prefix}{sid}",
            "password":   pw_tmpl.format(n=n),
        })
    return out


def expand_shared(cfg: dict) -> list[dict]:
    """Normalise shared_infrastructure entries; fill defaults."""
    defaults = cfg.get("default_credentials", {})
    out = []
    for s in cfg.get("shared_infrastructure") or []:
        out.append({
            "name":           s["name"],
            "role":           s["role"],
            "os":             s["os"],
            "size":           s.get("size", "small"),
            "linux_user":     s.get(
                "linux_user", defaults.get("linux_user", "ranger")),
            "linux_password": s.get(
                "linux_password",
                defaults.get("linux_password", "P@ssw0rd!Linux1")),
            # Optional per-entry public_ip toggle. Default true (existing
            # behavior). redteam-lab sets false on Ghost/SS/RedELK so they
            # are reachable only via Guacamole.
            "public_ip":      bool(s.get("public_ip", True)),
        })
    return out


def write_tfvars(provider: str, cfg: dict, machines: list[dict],
                 student_users: list[dict],
                 shared_machines: list[dict]) -> Path:
    # vm_priority: "Regular" (default) or "Spot". Reject anything else.
    priority = str(cfg.get("vm_priority", "Regular"))
    if priority not in ("Regular", "Spot"):
        fail(f"vm_priority must be 'Regular' or 'Spot' (got '{priority}')")

    # Geofence expansion: if scenario sets `guacamole_allow_countries:
    # [SG, AU, ...]`, replace any explicit guacamole_ingress_cidrs with
    # the merged country CIDR list. The explicit list still wins if both
    # are set (operator's CIDR list overrides countries).
    ingress_cidrs = cfg.get("guacamole_ingress_cidrs", ["0.0.0.0/0"])
    countries = cfg.get("guacamole_allow_countries") or []
    if countries:
        if not isinstance(countries, list):
            fail("guacamole_allow_countries must be a list of 2-letter codes")
        # Only expand if the operator hasn't already pinned to specific CIDRs.
        if cfg.get("guacamole_ingress_cidrs") in (None, ["0.0.0.0/0"]):
            ingress_cidrs = _expand_geofence(countries)
            print(f"INFO: guacamole_ingress_cidrs expanded from "
                  f"countries {sorted([c.upper() for c in countries])} "
                  f"to {len(ingress_cidrs)} CIDRs.", file=sys.stderr)

    # Auto-add operator's public IP. Default off; redteam-lab scenarios
    # set this to true so the apply-time IP is explicitly whitelisted on
    # top of the country geofence (covers VPN exits, mobile carrier
    # CIDRs that drift outside the geofence, etc.). Best-effort — if
    # we can't determine the IP, we warn and continue.
    if cfg.get("guacamole_auto_add_my_ip", False):
        ip = _fetch_operator_public_ip()
        if ip:
            import ipaddress
            my_addr  = ipaddress.ip_address(ip)
            my_cidr  = f"{ip}/32"
            # Azure NSG rejects source_address_prefixes that overlap.
            # If the operator's /32 is already inside any country block
            # (or any explicit operator-listed CIDR), skip the prepend
            # — the IP is already permitted via that broader range.
            covering = None
            for c in ingress_cidrs:
                try:
                    net = ipaddress.ip_network(c, strict=False)
                except ValueError:
                    continue
                if my_addr in net:
                    covering = c
                    break
            if covering is not None:
                print(f"INFO: operator public IP {ip} already covered by "
                      f"existing CIDR {covering}; skipping prepend "
                      f"(Azure NSG rejects overlapping prefixes).",
                      file=sys.stderr)
            elif my_cidr not in ingress_cidrs:
                ingress_cidrs = [my_cidr] + ingress_cidrs
                print(f"INFO: detected operator public IP {ip}; "
                      f"prepended {my_cidr} to guacamole_ingress_cidrs.",
                      file=sys.stderr)
            else:
                print(f"INFO: operator public IP {ip} already in "
                      f"guacamole_ingress_cidrs.", file=sys.stderr)
        else:
            print("WARN: guacamole_auto_add_my_ip: true but couldn't "
                  "auto-detect public IP (offline / firewalled?). "
                  "Skipping; you may need to add your IP manually to "
                  "guacamole_ingress_cidrs after apply.", file=sys.stderr)

    tfvars = {
        "range_name":               cfg["range_name"],
        "lockdown":                 bool(cfg.get("lockdown", False)),
        "vm_priority":              priority,
        "fast_windows":             bool(cfg.get("fast_windows", False)),
        "guacamole_ingress_cidrs":  ingress_cidrs,
        "domain": cfg.get("domain", {
            "enabled":           False,
            "fqdn":              "corp.local",
            "netbios":           "CORP",
            "admin_user":        "rangeadmin",
            "admin_password":    "P@ssw0rd!RangeAdmin1",
            "safemode_password": "P@ssw0rd!SafeMode1",
        }),
        "students":         cfg["students"],
        "machines":         machines,
        "student_users":    student_users,
        "shared_machines":  shared_machines,
        "advanced_c2":      _normalize_advanced_c2(cfg.get("advanced_c2") or {}, provider),
        "advanced_c2_validation_wait_minutes": int(
            cfg.get("advanced_c2_validation_wait_minutes", 20)
        ),
        "services":         cfg["services"],
    }
    # Only emit `goad` when the scenario actually configures it. Other
    # scenarios (redteam-lab, class, engagement, ...) don't have a
    # corresponding `variable "goad"` declared in the module and an
    # always-emitted goad block triggers a 'value for undeclared
    # variable' warning on every plan/apply.
    if cfg.get("goad"):
        tfvars["goad"] = _normalize_goad(cfg["goad"])
    # Only emit `baking` when the scenario configures it — same reason
    # as `goad` above: the AWS module doesn't declare a `baking`
    # variable, so an always-emitted block would trip a 'value for
    # undeclared variable' warning on every aws plan/apply. The azure
    # module declares `baking` with an enabled=false default, so
    # omitting it for azure scenarios that don't set it is fine too.
    if cfg.get("baking"):
        tfvars["baking"] = cfg["baking"]
    if provider == "aws":
        tfvars["region"] = cfg.get("region", "us-east-1")
    elif provider == "gcp":
        # Translate Azure region defaults to a GCP equivalent. Scenario
        # YAML can keep `azure_region: southeastasia` (legacy field name)
        # and the generator will map it to GCP's `asia-southeast1`; or
        # the scenario can use `gcp_region: ...` directly.
        AZURE_TO_GCP_REGION = {
            "southeastasia":     "asia-southeast1",
            "eastus":            "us-east4",
            "westus":            "us-west1",
            "westus2":           "us-west2",
            "westeurope":        "europe-west1",
            "northeurope":       "europe-west2",
            "uksouth":           "europe-west2",
            "australiaeast":     "australia-southeast1",
            "japaneast":         "asia-northeast1",
            "southcentralus":    "us-central1",
        }
        az_region = cfg.get("azure_region", "")
        gcp_region = (
            cfg.get("gcp_region")
            or AZURE_TO_GCP_REGION.get(az_region)
            or "asia-southeast1"
        )
        tfvars["gcp_region"] = gcp_region
        # Also pass azure_region for legacy var-name parity inside the module
        tfvars["azure_region"] = gcp_region

        # ----- One-project-per-range model -----
        # gcp_project_id: scenarios should NOT set this — leave empty so
        # envs/gcp/main.tf auto-derives a deterministic ID from
        # `range_name + sha256(range_name)[:6]`. Override only when the
        # operator has pre-created a specific project they want to use
        # (set gcp_create_project: false in YAML too, so terraform won't
        # try to re-create it).
        tfvars["gcp_project_id"] = (
            cfg.get("gcp_project_id")
            or os.environ.get("TERRARANGE_GCP_PROJECT_ID")
            or os.environ.get("GOOGLE_CLOUD_PROJECT")
            or ""   # empty = let env auto-generate from range_name
        )
        # gcp_create_project: terraform creates + owns the per-range project
        # by default. Set false to use a pre-existing project (operator's
        # gcp_project_id wins above).
        tfvars["gcp_create_project"] = bool(
            cfg.get("gcp_create_project",
                    not bool(tfvars["gcp_project_id"]))
        )

        # gcp_billing_account / gcp_parent_folder_id / gcp_parent_org_id:
        # required when gcp_create_project=true. Pull from YAML, then env
        # vars, then leave empty (will fail with actionable terraform error
        # if create_project=true).
        tfvars["gcp_billing_account"] = (
            cfg.get("gcp_billing_account")
            or os.environ.get("TERRARANGE_GCP_BILLING_ACCOUNT", "")
        )
        tfvars["gcp_parent_folder_id"] = (
            cfg.get("gcp_parent_folder_id")
            or os.environ.get("TERRARANGE_GCP_PARENT_FOLDER_ID", "")
        )
        tfvars["gcp_parent_org_id"] = (
            cfg.get("gcp_parent_org_id")
            or os.environ.get("TERRARANGE_GCP_PARENT_ORG_ID", "")
        )

        # gcp_host_project_id: long-lived shared project for baked images +
        # DNS zones. Empty = single-project mode (baked images live with
        # the per-range project; lost on destroy). RECOMMENDED for prod:
        # set this to a dedicated project like "terra-range-images".
        tfvars["gcp_host_project_id"] = (
            cfg.get("gcp_host_project_id")
            or os.environ.get("TERRARANGE_GCP_HOST_PROJECT_ID", "")
        )
    else:
        tfvars["azure_region"] = cfg.get("azure_region", "eastus")

    out_dir = REPO / "envs" / provider
    out_dir.mkdir(parents=True, exist_ok=True)
    out_path = out_dir / "terraform.tfvars.json"
    out_path.write_text(json.dumps(tfvars, indent=2))
    return out_path


def _normalize_advanced_c2(adv: dict, provider: str = "azure") -> dict:
    """Always emit a fully-populated object so Terraform vars typecheck.

    `provider` is consulted ONLY to swap the default fronting domain:
    Azure deploys default to the empty string (operator must set
    explicitly), AWS deploys default to Authrix.com (the CloudFront
    fronting zone provisioned for this project). Either way, an
    explicit `domain` in the scenario YAML always wins.
    """
    raw_domain = adv.get("domain", "")
    default_domain = "Authrix.com" if provider == "aws" else ""
    # Azure-default fronting domains shouldn't carry over into AWS plans.
    # If the YAML specifies a *.azure.com or known Azure-only zone and
    # we're rendering for AWS, fall back to Authrix.com. (Detection is
    # conservative — only swap when the domain string contains
    # "enterprisesstudio" which is the historical Azure default.)
    if provider == "aws" and ("enterprisesstudio" in raw_domain.lower()
                              or raw_domain == ""):
        effective_domain = default_domain
    else:
        effective_domain = raw_domain or default_domain
    return {
        "enabled":                  bool(adv.get("enabled", False)),
        "domain":                   effective_domain,
        "dns_zone_resource_group":  adv.get("dns_zone_resource_group", ""),
        # Subscription where the DNS zone lives. Empty = same sub as
        # the range deploy. Set when the registered domain is in a
        # separate Azure subscription (e.g. shared corporate zone).
        "dns_zone_subscription_id": adv.get("dns_zone_subscription_id", ""),
        "cover_url":                adv.get("cover_url",
                                            "https://www.microsoft.com"),
        "fdid_header_required":     bool(adv.get("fdid_header_required", True)),
        "student_subdomain_format": adv.get("student_subdomain_format", "{sid}"),
        # Optional operator-supplied AFD names. Empty = generator picks
        # from the curated pool with a numeric suffix for uniqueness.
        "endpoint_name":            adv.get("endpoint_name", ""),
        "profile_name":             adv.get("profile_name", ""),
    }


def _normalize_goad(g: dict) -> dict:
    """Fully-populated GOAD config. Every default below mirrors the upstream
    Orange-Cyberdefense/GOAD playbook so out-of-the-box deploys match the
    well-known walkthroughs; override any field in YAML to customise."""
    return {
        "enabled": bool(g.get("enabled", False)),

        # ---- domains (FQDN). All three are required when enabled. ----
        "root_domain":              g.get("root_domain", "sevenkingdoms.local"),
        "child_domain":             g.get("child_domain", "north.sevenkingdoms.local"),
        "separate_forest_domain":   g.get("separate_forest_domain", "essos.local"),

        # ---- NetBIOS names (≤15 chars). Used as Windows hostnames. ----
        "root_dc_name":             g.get("root_dc_name", "kingslanding"),
        "child_dc_name":            g.get("child_dc_name", "winterfell"),
        "separate_dc_name":         g.get("separate_dc_name", "meereen"),
        "member_name":              g.get("member_name", "castelblack"),

        # ---- Domain admin (one per domain). ----
        "root_admin_user":          g.get("root_admin_user", "robb.stark"),
        "root_admin_password":      g.get("root_admin_password", "Sevenkingdoms2024!"),
        "child_admin_user":         g.get("child_admin_user", "eddard.stark"),
        "child_admin_password":     g.get("child_admin_password", "Winterfell2024!"),
        "separate_admin_user":      g.get("separate_admin_user", "daenerys.targaryen"),
        "separate_admin_password":  g.get("separate_admin_password", "Targaryen2024!"),

        # ---- Domain user list. Each entry seeds a regular AD user with
        # specific attributes that drive the attack chain. The fields
        # match the upstream `users` ansible variable shape so the
        # bridge script feeds them straight into the playbook. ----
        "users": g.get("users", _default_goad_users()),

        # ---- Service accounts (Kerberoastable / ASREPRoastable / SPN
        # set / no-pre-auth flagged). Same shape as upstream. ----
        "service_accounts": g.get("service_accounts", _default_goad_svcs()),

        # ---- Optional services on top of the bare DC roles. ----
        "install_mssql_on_root":    bool(g.get("install_mssql_on_root",   True)),
        "install_mssql_on_member":  bool(g.get("install_mssql_on_member", True)),
        "install_iis_on_root":      bool(g.get("install_iis_on_root",     True)),

        # ---- Vulnerable-config seeding. Each toggle leaves the
        # upstream playbook free to vary (you can disable individual
        # paths so the lab gets harder for advanced students). ----
        "seed_kerberoast":          bool(g.get("seed_kerberoast",          True)),
        "seed_asreproast":          bool(g.get("seed_asreproast",          True)),
        "seed_acl_misconfigs":      bool(g.get("seed_acl_misconfigs",      True)),
        "seed_unconstrained_deleg": bool(g.get("seed_unconstrained_deleg", True)),
        "seed_constrained_deleg":   bool(g.get("seed_constrained_deleg",   True)),
        "seed_dnsadmins":           bool(g.get("seed_dnsadmins",           True)),
        "seed_smbv1":               bool(g.get("seed_smbv1",               True)),
    }


def _default_goad_users() -> list:
    """Default user roster — mirrors the GOAD walkthroughs that
    instructors and writeups reference. Override with your own roster
    in YAML to rename everyone for a custom client narrative."""
    return [
        # Root domain (sevenkingdoms.local)
        {"name": "brandon.stark",  "password": "iseedeadpeople", "domain": "root",     "groups": ["Domain Users"]},
        {"name": "rickon.stark",   "password": "WinterfellLittle1", "domain": "root", "groups": ["Domain Users"]},
        {"name": "hodor",          "password": "hodor",           "domain": "root",   "groups": ["Domain Users"]},
        {"name": "jeor.mormont",   "password": "_L0rdC0mander_",  "domain": "root",   "groups": ["Domain Users"]},
        {"name": "sansa.stark",    "password": "Sansa2024!",      "domain": "root",   "groups": ["Domain Users"]},
        # Child domain (north.sevenkingdoms.local)
        {"name": "arya.stark",     "password": "Needle1!",        "domain": "child",  "groups": ["Domain Users"]},
        {"name": "jon.snow",       "password": "iknownothing",    "domain": "child",  "groups": ["Domain Users"]},
        {"name": "samwell.tarly",  "password": "Heartsbane",      "domain": "child",  "groups": ["Domain Users"]},
        {"name": "sql_svc",        "password": "Tyene2024!",      "domain": "child",  "groups": ["Domain Users"]},
        # Separate forest (essos.local)
        {"name": "khal.drogo",     "password": "horse",           "domain": "separate", "groups": ["Domain Users"]},
        {"name": "viserys.targaryen", "password": "_Begg@r_",     "domain": "separate", "groups": ["Domain Users"]},
        {"name": "jorah.mormont", "password": "_L0rdC0mander_",   "domain": "separate", "groups": ["Domain Users"]},
    ]


def _default_goad_svcs() -> list:
    """Default service-account roster covering the canonical
    Kerberoast / ASREPRoast / unconstrained-delegation paths."""
    return [
        # Kerberoastable (SPN set, weak password)
        {"name": "sqlservice",  "password": "Sword123!",   "domain": "root",
         "kerberoastable": True,  "asreproastable": False,
         "spn": "MSSQLSvc/kingslanding.sevenkingdoms.local:1433"},
        # ASREPRoastable (DONT_REQ_PREAUTH set)
        {"name": "jaime.lannister", "password": "GoldenHand2024!", "domain": "root",
         "kerberoastable": False, "asreproastable": True, "spn": ""},
        # Both (rare in practice but present in GOAD)
        {"name": "vagrant",     "password": "vagrant",     "domain": "root",
         "kerberoastable": True,  "asreproastable": True,
         "spn": "HTTP/kingslanding.sevenkingdoms.local"},
    ]


def main() -> None:
    import os

    ap = argparse.ArgumentParser()
    ap.add_argument("yaml_path", help="Path to range YAML")
    ap.add_argument("--provider", choices=["aws", "azure", "gcp", "both"],
                    help="Override provider from YAML")
    ap.add_argument("--students", type=int,
                    help="Override students.count from YAML")
    ap.add_argument("--domain", type=str,
                    help="Override domain.fqdn from YAML (e.g. ian.local, "
                         "redteamlabs.dev). NetBIOS is auto-derived from the "
                         "first dotted label, uppercased, capped at 15 chars.")
    ap.add_argument("--admin-user", dest="admin_user", type=str,
                    help="Override domain.admin_user from YAML")
    ap.add_argument("--spot", action="store_true",
                    help="Set vm_priority=Spot for every VM in this range. "
                         "Saves ~80%% off PAYG but Azure can evict at any "
                         "time. Eviction policy is Deallocate so OS disk + "
                         "state survive. Default: Regular.")
    ap.add_argument("--fast-windows", dest="fast_windows", action="store_true",
                    help="Speed knob for lab deploys. Disables Windows Update "
                         "on first boot (saves ~10-15 min) and bumps DC VM "
                         "from D4s_v5 to D8s_v5 so AD promo runs faster. "
                         "Trades latest CVE patches for spin-up time; not "
                         "for production. Adds ~$280/mo per DC.")
    ap.add_argument("--no-afd-wait", dest="no_afd_wait", action="store_true",
                    help="Skip the 20-min AFD managed-cert validation block "
                         "during `terraform apply`. AFD still validates "
                         "async — poll with `./range afd-status` to see when "
                         "HTTPS to the custom domain comes alive. Saves "
                         "20-30 min of wall time per apply.")
    ap.add_argument("--title", dest="login_title", type=str,
                    help="Custom title for the Guacamole login page, replacing "
                         "the default 'APACHE GUACAMOLE' wordmark. The Ansible "
                         "guacamole role bakes this into a translation-override "
                         "inside cwr-branding.jar. Default: 'Guidem CWR'.")
    ap.add_argument("--acme-email", dest="acme_email", type=str,
                    help="ACME contact email for Let's Encrypt cert issuance "
                         "on the Guacamole VM. Must be a well-formed address — "
                         "certbot rejects raw usernames. LE only uses it to "
                         "send renewal-reminder mail; the address does NOT "
                         "have to receive challenge mail. Default placeholder "
                         "is 'admin@example.com' (well-formed, accepts a real "
                         "cert, but renewal warnings will go nowhere).")
    # ---- Guacamole custom DNS (branded URL) ----
    # When the operator owns a real domain in Azure DNS, these flags
    # bind Guacamole to <subdomain>.<domain> instead of the awkward
    # Azure-assigned cloudapp.azure.com hostname. terraform writes the
    # A record under the named zone; certbot issues the LE cert for it.
    ap.add_argument("--guac-subdomain", dest="guac_subdomain", type=str,
                    help="Subdomain label for Guacamole's custom hostname "
                         "(e.g. 'guac' -> guac.cyberwarrange.com). Requires "
                         "--guac-domain. Default: 'guac' when domain is set.")
    ap.add_argument("--guac-domain", dest="guac_domain", type=str,
                    help="Apex DNS zone name in Azure DNS to attach Guacamole "
                         "to (e.g. 'cyberwarrange.com'). Empty = use the "
                         "Azure-assigned cloudapp.azure.com FQDN.")
    ap.add_argument("--guac-dns-rg", dest="guac_dns_rg", type=str,
                    help="Azure resource group of the --guac-domain DNS zone.")
    ap.add_argument("--guac-dns-sub", dest="guac_dns_sub", type=str,
                    help="Azure subscription ID containing the --guac-domain "
                         "DNS zone. Leave blank if the zone is in the same "
                         "subscription as the deployment.")
    args = ap.parse_args()

    yaml_path = Path(args.yaml_path)
    if not yaml_path.exists():
        fail(f"file not found: {yaml_path}")

    cfg = yaml.safe_load(yaml_path.read_text())
    if args.students is not None:
        cfg.setdefault("students", {})["count"] = args.students

    if args.domain is not None:
        fqdn = args.domain.strip().lower()
        if "." not in fqdn or " " in fqdn:
            fail(f"--domain '{args.domain}' must be a dotted FQDN with no spaces")
        if not all(c.isalnum() or c in ".-" for c in fqdn):
            fail(f"--domain '{args.domain}' contains invalid characters "
                 f"(allowed: letters, digits, dot, hyphen)")
        # NetBIOS = first dotted label, case-preserved from --domain
        # input, capped at 15 chars. (Windows AD itself stores/displays
        # NetBIOS uppercase regardless of input case — but some Marketplace
        # Server 2022 images have a prereq verifier quirk that rejects
        # uppercase auto-generated names, so we leave the case alone and
        # let the operator's input drive it.)
        netbios = fqdn.split(".")[0][:15]
        if not netbios:
            fail(f"--domain '{args.domain}' has empty first label")
        if not all(c.isalnum() or c == "-" for c in netbios):
            fail(f"--domain '{args.domain}' first label '{netbios}' has "
                 f"invalid NetBIOS characters")
        cfg.setdefault("domain", {})["fqdn"] = fqdn
        cfg["domain"]["netbios"] = netbios
        cfg["domain"]["enabled"] = True

    if args.admin_user is not None:
        cfg.setdefault("domain", {})["admin_user"] = args.admin_user

    if args.spot:
        cfg["vm_priority"] = "Spot"

    if args.fast_windows:
        cfg["fast_windows"] = True

    if args.no_afd_wait:
        cfg["advanced_c2_validation_wait_minutes"] = 0

    # Guacamole login-page title. CLI flag wins over scenario YAML.
    # Default is "Guidem CWR" — applied if neither is set.
    guac_svc = cfg.setdefault("services", {}).setdefault("guacamole", {})
    if args.login_title:
        guac_svc["login_title"] = args.login_title
    guac_svc.setdefault("login_title", "Guidem CWR")

    # ACME contact email — CLI flag wins over scenario YAML. Default
    # is 'admin@example.com' (well-formed; well-trusted cert; renewal
    # warnings go nowhere — set a real address if you care).
    if args.acme_email:
        guac_svc["acme_email"] = args.acme_email
    guac_svc.setdefault("acme_email", "admin@example.com")

    # Guacamole custom DNS hostname. Each CLI flag wins over the
    # scenario YAML's corresponding field. Setting --guac-domain
    # without --guac-subdomain defaults the subdomain to "guac".
    if args.guac_domain:
        guac_svc["dns_zone_name"] = args.guac_domain
    if args.guac_subdomain:
        guac_svc["custom_hostname"] = args.guac_subdomain
    if args.guac_dns_rg:
        guac_svc["dns_zone_resource_group"] = args.guac_dns_rg
    if args.guac_dns_sub:
        guac_svc["dns_zone_subscription_id"] = args.guac_dns_sub
    # When the operator gives us a zone but no explicit subdomain, leave
    # custom_hostname EMPTY so terraform's random_shuffle + random_integer
    # produce a friendly auto-name (`cwr-guidem-<word>-<NNN>.<zone>`).
    # `--guac-subdomain <label>` (handled above) overrides this.

    # If the operator chose to skip BRC4 (no TF_VAR_brc4_license_id set
    # by the wrapper), drop the c2-brc4 machine and any c2-redirector
    # fronting it from the YAML before validation. Saves ~$150/mo for
    # an unused BRC4 VM that would have just exited cloud-init cleanly.
    brc4_license = os.environ.get("TF_VAR_brc4_license_id", "").strip()
    if not brc4_license and isinstance(cfg.get("machines"), list):
        before = len(cfg["machines"])
        cfg["machines"] = [
            m for m in cfg["machines"]
            if m.get("role") != "c2-brc4"
            and not (m.get("role") == "c2-redirector"
                     and m.get("fronts") == "c2-brc4")
        ]
        dropped = before - len(cfg["machines"])
        if dropped:
            print(f"INFO: BRC4 license not set; dropping {dropped} BRC4-related "
                  f"machine(s) from this generation.", file=sys.stderr)

    validate(cfg)
    machines = expand_machines(cfg)
    student_users = build_student_users(cfg)
    shared_machines = expand_shared(cfg)

    provider = args.provider or cfg["provider"]
    targets = ["aws", "azure"] if provider == "both" else [provider]

    written = []
    for p in targets:
        out = write_tfvars(p, cfg, machines, student_users, shared_machines)
        written.append(out)

    print(f"Generated {len(machines)} machines across "
          f"{cfg['students']['count']} student(s); "
          f"{len(shared_machines)} shared infra box(es); "
          f"advanced_c2={'on' if cfg['advanced_c2'].get('enabled') else 'off'}.")
    print("Files:")
    for w in written:
        print(f"  {w.relative_to(REPO)}")
    print()
    print("Next:")
    for w in written:
        env = w.parent
        print(f"  cd {env.relative_to(REPO)} && terraform init && "
              f"terraform apply")


if __name__ == "__main__":
    main()
