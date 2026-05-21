#!/usr/bin/env python3
"""
quota-cost.py — terra-range pre-flight quota + cost report.

Reads envs/azure/terraform.tfvars.json (must be freshly generated),
mirrors the modules/azure/images.tf vm_size logic to compute per-family
core requirements, and produces:

  1. Per-SKU VM count + cores + price
  2. Per-family core total (matches Azure quota names)
  3. A monthly cost estimate (rough PAYG, varies by region)
  4. A quota check via `az vm list-usage` if the CLI is available

Exit codes:
  0  = report only / quota fine
  2  = quota would be exceeded for at least one family
  1  = bad input
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
from collections import defaultdict
from pathlib import Path


# -----------------------------------------------------------------------------
# Pricing table — rough USD/month, PAYG, varies by region, Linux. Treat as
# order-of-magnitude. Update when Azure publishes new prices.
# Reference: https://azure.microsoft.com/en-us/pricing/details/virtual-machines/linux/
# -----------------------------------------------------------------------------
SKU_PRICE_USD_MO = {
    "Standard_B2s":    30,    # 2 vCPU /  4 GB
    "Standard_B2ms":   60,    # 2 vCPU /  8 GB  (Guacamole)
    "Standard_B4ms":   120,   # 4 vCPU / 16 GB  (ELK + medium operator boxes)
    "Standard_B8ms":   240,   # 8 vCPU / 32 GB  (RedELK)
    "Standard_D2s_v5": 70,    # 2 vCPU /  8 GB  (linux-target)
    "Standard_D4s_v5": 140,   # 4 vCPU / 16 GB  (windows-* roles)
}

SKU_CORES = {
    "Standard_B2s":    2,
    "Standard_B2ms":   2,
    "Standard_B4ms":   4,
    "Standard_B8ms":   8,
    "Standard_D2s_v5": 2,
    "Standard_D4s_v5": 4,
}

# SKU → quota family name. These must match `az vm list-usage --query
# "[].localName"` exactly. Both BS and B-family share "Standard BS".
SKU_FAMILY = {
    "Standard_B2s":    "Standard BS Family vCPUs",
    "Standard_B2ms":   "Standard BS Family vCPUs",
    "Standard_B4ms":   "Standard BS Family vCPUs",
    "Standard_B8ms":   "Standard BS Family vCPUs",
    "Standard_D2s_v5": "Standard DSv5 Family vCPUs",
    "Standard_D4s_v5": "Standard DSv5 Family vCPUs",
}

# -----------------------------------------------------------------------------
# vm_size logic — mirrors modules/azure/images.tf vm_size local. Keep in sync.
# -----------------------------------------------------------------------------
SIZE_MAP = {
    "small":  "Standard_B2s",
    "medium": "Standard_B4ms",
    "large":  "Standard_B8ms",
}


def vm_size_for_machine(m: dict) -> str:
    """Per-student VM size derivation."""
    role = m["role"]
    if role in ("windows-dc", "windows-member", "windows-workstation", "windows-blank"):
        return "Standard_D4s_v5"
    if role == "linux-target":
        return "Standard_D2s_v5"
    return SIZE_MAP[m["size"]]


def vm_size_for_shared(s: dict) -> str:
    """Shared infra always honours YAML size:."""
    return SIZE_MAP[s["size"]]


# Hub-tier services with hardcoded sizes in modules/azure/services.tf.
# Update if those resources change.
HUB_SERVICES_SKU = {
    "guacamole": "Standard_B2ms",   # services.tf:159
    "elk":       "Standard_B4ms",   # services.tf:94
}

# -----------------------------------------------------------------------------
# Az CLI quota lookup
# -----------------------------------------------------------------------------

def query_quota(region: str, family: str) -> tuple[int, int] | tuple[None, None]:
    """Return (used, limit) or (None, None) if az failed."""
    if not shutil.which("az"):
        return None, None
    try:
        proc = subprocess.run(
            [
                "az", "vm", "list-usage", "--location", region,
                "--query",
                f"[?localName=='{family}'].{{used:currentValue,limit:limit}}",
                "-o", "json",
            ],
            capture_output=True, text=True, timeout=30,
        )
        data = json.loads(proc.stdout or "[]")
        if data:
            return int(data[0]["used"]), int(data[0]["limit"])
    except (subprocess.SubprocessError, json.JSONDecodeError, KeyError, ValueError):
        pass
    return None, None


# Network-namespace quota families that terra-range touches. The
# `name.value` field returned by `az network list-usages` is the
# canonical identifier; localName is the display string.
#
# Azure returns DIFFERENT canonical names in different regions for the
# same logical quota — e.g. southeastasia reports
# "IPv4StandardSkuPublicIpAddresses", while older regions still report
# "StandardSkuPublicIPAddresses", and the umbrella "PublicIPAddresses"
# is present almost everywhere. We try each candidate in order and
# pick the first one that resolves.
NETWORK_QUOTA_CANDIDATES = {
    # Public IP, Standard SKU, IPv4 (terra-range's PIPs are all v4/Std).
    "public_ips_standard": (
        "IPv4StandardSkuPublicIpAddresses",
        "StandardSkuPublicIPAddresses",
        "PublicIPAddresses",   # umbrella — least specific, last resort
    ),
    "vnets":         ("VirtualNetworks",),
    "nsgs":          ("NetworkSecurityGroups",),
    "nat_gateways":  ("NatGateways",),
}


def query_network_quotas(region: str) -> dict[str, tuple[str, int, int]]:
    """Return {short_key: (canonical_name, used, limit)} for every
    NETWORK_QUOTA_CANDIDATES entry we can resolve. Missing entries
    (region doesn't track them) are omitted.

    One az call serves every family — much cheaper than per-family.
    The canonical_name is returned alongside used/limit so the auto-
    request path can use the exact name Azure expects in that region.
    """
    out: dict[str, tuple[str, int, int]] = {}
    if not shutil.which("az"):
        return out
    try:
        proc = subprocess.run(
            ["az", "network", "list-usages", "--location", region, "-o", "json"],
            capture_output=True, text=True, timeout=30,
        )
        data = json.loads(proc.stdout or "[]")
    except (subprocess.SubprocessError, json.JSONDecodeError):
        return out

    # Build name.value → (used, limit) lookup.
    by_name: dict[str, tuple[int, int]] = {}
    for it in data:
        try:
            n = (it.get("name") or {}).get("value")
            if not n:
                continue
            by_name[n] = (int(it.get("currentValue", 0)), int(it.get("limit", 0)))
        except (TypeError, ValueError):
            continue

    for short, candidates in NETWORK_QUOTA_CANDIDATES.items():
        for canonical in candidates:
            if canonical in by_name:
                used, limit = by_name[canonical]
                out[short] = (canonical, used, limit)
                break
    return out


# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

# ============================================================================
# GCP pricing + quota check
# ============================================================================
# Rough USD/month estimates for asia-southeast1, on-demand. Sustained-use
# discount (auto-applied by GCP for >25%-of-month usage) is NOT factored
# in — actual bills are typically 5-30% lower than these numbers.
# Windows VMs carry a per-vCPU license premium (~$0.046/vCPU-hour for
# 2 vCPU+) bundled into the price below.
GCP_MACHINE_PRICE_USD_MO = {
    "e2-small":       8,    # 2 vCPU / 2  GB — bursty
    "e2-medium":      24,   # 2 vCPU / 4  GB
    "e2-standard-2":  48,   # 2 vCPU / 8  GB
    "e2-standard-4":  98,   # 4 vCPU / 16 GB — default workhorse
    "e2-standard-8":  196,  # 8 vCPU / 32 GB
    "n2-standard-2":  70,   # 2 vCPU / 8  GB — for AD targets
    "n2-standard-4":  140,  # 4 vCPU / 16 GB — DC/members
    "n2-standard-8":  280,  # 8 vCPU / 32 GB — fast windows / large
}
# Windows VMs on GCP carry an additional ~$25-50/mo per vCPU. Approximate.
GCP_WINDOWS_LICENSE_ADD = {
    "n2-standard-2": 45,
    "n2-standard-4": 90,
    "n2-standard-8": 180,
    "e2-medium":     22,
    "e2-standard-4": 90,
}
GCP_MACHINE_CORES = {
    "e2-small": 2, "e2-medium": 2, "e2-standard-2": 2,
    "e2-standard-4": 4, "e2-standard-8": 8,
    "n2-standard-2": 2, "n2-standard-4": 4, "n2-standard-8": 8,
}
# GCP machine_type → quota family (matches `gcloud compute project-info
# describe` metric names). E2 + N2 share the "CPUS" regional quota.
GCP_REGIONAL_QUOTAS = {
    "CPUS":                  "all vCPU (regional)",
    "IN_USE_ADDRESSES":      "Static public IPs",
    "STATIC_ADDRESSES":      "Reserved public IPs",
    "NETWORKS":              "VPCs",
    "FIREWALLS":             "Firewall rules per VPC",
    "SUBNETWORKS":           "Subnets",
}

GCP_SIZE_MAP = {
    "small":  "e2-small",
    "medium": "e2-standard-4",
    "large":  "e2-standard-8",
}

GCP_SPOT_PINNED_ROLES = {"windows-dc", "c2-redirector"}


def _gcp_vm_size(m: dict) -> str:
    """Replicate modules/gcp/images.tf:local.vm_size logic."""
    role = m["role"]
    if role == "windows-dc":
        return "n2-standard-4"   # ignoring fast_windows for simplicity
    if role in ("windows-member", "windows-workstation", "windows-blank", "windows-analyst"):
        return "n2-standard-4"
    if role == "linux-target":
        return "n2-standard-2"
    return GCP_SIZE_MAP[m["size"]]


def _gcp_is_windows(m: dict) -> bool:
    return m.get("os", "").startswith("windows")


def _main_gcp(cfg: dict, tfvars_path: Path) -> int:
    machines = cfg.get("machines", [])
    shared   = cfg.get("shared_machines", [])
    region   = cfg.get("gcp_region") or cfg.get("azure_region", "asia-southeast1")
    project  = cfg.get("gcp_project_id", "")
    create_project = cfg.get("gcp_create_project", True)
    lockdown = cfg.get("lockdown", False)
    range_name = cfg.get("range_name", "<unknown>")
    services = cfg.get("services", {})
    advanced_c2 = cfg.get("advanced_c2", {}).get("enabled", False)
    vm_priority = cfg.get("vm_priority", "Regular")
    spot_multiplier = 0.30 if vm_priority == "Spot" else 1.0
    # GCP Spot is typically 60-91% off — we use 70% off as conservative.

    # ---- bucket VMs by machine_type ---------------------------------------
    type_count = defaultdict(int)
    type_count_spot = defaultdict(int)
    type_count_pinned = defaultdict(int)
    type_is_windows = {}
    total_cores = 0

    def add(mt: str, is_win: bool, eligible_for_spot: bool) -> None:
        nonlocal total_cores
        type_count[mt] += 1
        type_is_windows[mt] = type_is_windows.get(mt, False) or is_win
        total_cores += GCP_MACHINE_CORES.get(mt, 2)
        if vm_priority == "Spot":
            if eligible_for_spot:
                type_count_spot[mt] += 1
            else:
                type_count_pinned[mt] += 1

    for m in machines:
        mt = _gcp_vm_size(m)
        add(mt, _gcp_is_windows(m),
            eligible_for_spot=m["role"] not in GCP_SPOT_PINNED_ROLES)
    for s in shared:
        mt = GCP_SIZE_MAP[s["size"]]
        add(mt, False, eligible_for_spot=True)

    # Hub services — same sizing as Azure side
    if services.get("guacamole", {}).get("enabled"):
        add("e2-medium", False, eligible_for_spot=True)
    if services.get("elk", {}).get("enabled"):
        add("e2-standard-4", False, eligible_for_spot=True)

    # ---- compute cost -----------------------------------------------------
    def vm_cost(mt: str, count: int, with_spot: bool) -> int:
        base = GCP_MACHINE_PRICE_USD_MO.get(mt, 100)
        if type_is_windows.get(mt):
            base += GCP_WINDOWS_LICENSE_ADD.get(mt, 0)
        if with_spot:
            base = base * spot_multiplier
        return round(base * count)

    vm_total = 0
    for mt, count in type_count.items():
        if vm_priority == "Spot":
            sp = type_count_spot.get(mt, 0)
            pn = type_count_pinned.get(mt, 0)
            vm_total += vm_cost(mt, sp, with_spot=True)
            vm_total += vm_cost(mt, pn, with_spot=False)
        else:
            vm_total += vm_cost(mt, count, with_spot=False)

    # ---- non-VM costs -----------------------------------------------------
    n_disks = len(machines) + len(shared) + (1 if services.get("elk", {}).get("enabled") else 0) + (1 if services.get("guacamole", {}).get("enabled") else 0)
    disk_cost = n_disks * 5  # pd-balanced ~$5/mo for 64-200GB

    n_pip = 0
    if services.get("guacamole", {}).get("enabled"):
        n_pip += 1
    n_pip += sum(1 for s in shared if s.get("public_ip", True))
    if advanced_c2:
        n_pip += 1  # single global anycast IP for the LB (cheaper than Azure AFD's per-endpoint)
    pip_cost = n_pip * 3  # GCP static external IP ~$3-4/mo when in use

    nat_cost = 0 if lockdown else 15  # Cloud NAT ~$15/mo for the gateway + ~$0.045/GB processed
    cdn_cost = 25 if advanced_c2 else 0  # External HTTPS LB + Cloud CDN; rough

    total = vm_total + disk_cost + pip_cost + nat_cost + cdn_cost

    # ---- report -----------------------------------------------------------
    print(f"Range: {range_name}   provider: GCP   region: {region}")
    print(f"Project: {project or '(auto-derived at apply time)'}   create_project: {create_project}")
    print()
    pinned_total = sum(type_count_pinned.values())
    spot_total = sum(type_count_spot.values())
    if vm_priority == "Spot":
        header = (f"VMs by machine_type ({sum(type_count.values())} total — "
                  f"{spot_total} Spot, {pinned_total} pinned to Regular [DC + redirectors])")
    else:
        header = f"VMs by machine_type ({sum(type_count.values())} total)"
    print(header)
    for mt, count in sorted(type_count.items()):
        win_tag = "  (Win+license)" if type_is_windows.get(mt) else ""
        if vm_priority == "Spot":
            sp = type_count_spot.get(mt, 0)
            pn = type_count_pinned.get(mt, 0)
            price = vm_cost(mt, sp, True) + vm_cost(mt, pn, False)
            print(f"  {mt:18s}  count={count:<3d}  ~${price}/mo  (Spot×{sp}+Reg×{pn}){win_tag}")
        else:
            price = vm_cost(mt, count, False)
            print(f"  {mt:18s}  count={count:<3d}  ~${price}/mo{win_tag}")
    print()
    print(f"Cost estimate (rough on-demand, USD/month — sustained-use discount NOT factored):")
    print(f"  VMs               ${vm_total:>5}")
    print(f"  Disks ({n_disks:<2d})       ${disk_cost:>5}")
    print(f"  Public IPs ({n_pip:<2d}) ${pip_cost:>5}")
    print(f"  Cloud NAT         ${nat_cost:>5}  ({'lockdown=true → no NAT' if lockdown else 'lockdown=false'})")
    print(f"  Cloud CDN+LB      ${cdn_cost:>5}  ({'enabled' if advanced_c2 else 'disabled'})")
    print(f"  ----- ")
    print(f"  TOTAL          ~${total:>4}/mo")
    print()
    print("  (List price; sustained-use auto-discount typically saves 5-30%.")
    print("   Run `gcloud beta billing` for actual billed amounts.)")
    print()

    # ---- quota probe via gcloud ------------------------------------------
    print(f"GCP regional quota check (region: {region})")
    if not shutil.which("gcloud"):
        print("  [?] gcloud not on PATH — quota check skipped")
        return 0
    if not project:
        print("  [?] no project ID yet (auto-derived at terraform apply time)")
        print("  [?]   Re-run quota-cost.py AFTER terraform apply to use the live project.")
        return 0

    try:
        proc = subprocess.run(
            ["gcloud", "compute", "regions", "describe", region,
             "--project=" + project, "--format=json"],
            capture_output=True, text=True, timeout=30,
        )
        if proc.returncode != 0:
            err = (proc.stderr or "").strip()[:200]
            print(f"  [?] gcloud describe failed: {err}")
            return 0
        region_data = json.loads(proc.stdout or "{}")
        quotas = {q["metric"]: q for q in region_data.get("quotas", [])}
    except (subprocess.SubprocessError, json.JSONDecodeError, KeyError) as e:
        print(f"  [?] quota lookup failed: {e}")
        return 0

    needed = {
        "CPUS":             total_cores,
        "IN_USE_ADDRESSES": n_pip,
        "FIREWALLS":        max(10, len(machines) // 2),  # conservative — see modules/gcp/firewall.tf
        "SUBNETWORKS":      max(3, len({m.get("student_id", "") for m in machines})),
    }
    over_quota = False
    for metric, want in needed.items():
        q = quotas.get(metric)
        if not q:
            print(f"  [?] {metric}: not found in regional quota list")
            continue
        used = q.get("usage", 0)
        limit = q.get("limit", 0)
        available = limit - used
        projected = used + want
        pct = (projected / limit) if limit else 1.0
        bar = f"{projected:.0f}/{limit:.0f} ({pct:.0%} projected)"
        if available >= want:
            print(f"  [+] {metric}: need {want}, available {available:.0f}  {bar}")
        else:
            shortfall = want - available
            print(f"  [!] {metric}: NEED {want}, AVAILABLE {available:.0f}  {bar} — short by {shortfall:.0f}")
            over_quota = True

    if over_quota:
        print()
        print("  Auto-request via `gcloud alpha services quota update` is NOT yet wired.")
        print("  Request increases via: https://console.cloud.google.com/iam-admin/quotas")
        print("  Filter by service = 'Compute Engine API' and the metric above.")
        return 2
    return 0


def main() -> int:
    # Provider auto-detect: if envs/gcp/terraform.tfvars.json exists AND
    # is newer than envs/azure/, use it. Operator can override with the
    # positional arg pointing at a specific tfvars file.
    if len(sys.argv) > 1:
        tfvars_path = Path(sys.argv[1])
    else:
        az_p = Path("envs/azure/terraform.tfvars.json")
        gcp_p = Path("envs/gcp/terraform.tfvars.json")
        if gcp_p.exists() and (not az_p.exists() or gcp_p.stat().st_mtime > az_p.stat().st_mtime):
            tfvars_path = gcp_p
        else:
            tfvars_path = az_p

    if not tfvars_path.exists():
        print(f"ERROR: {tfvars_path} not found. "
              f"Run `./range gen <scenario>` first.", file=sys.stderr)
        return 1

    cfg = json.loads(tfvars_path.read_text())
    # Detect provider from tfvars shape: GCP variants have gcp_project_id,
    # Azure variants don't. AWS not yet wired into this script.
    is_gcp = "gcp_project_id" in cfg
    if is_gcp:
        return _main_gcp(cfg, tfvars_path)
    # Falls through to the Azure pricing path below.
    machines = cfg.get("machines", [])
    shared   = cfg.get("shared_machines", [])
    region   = cfg.get("azure_region", "eastus")
    advanced_c2 = cfg.get("advanced_c2", {}).get("enabled", False)
    lockdown    = cfg.get("lockdown", False)
    range_name  = cfg.get("range_name", "<unknown>")
    services    = cfg.get("services", {})
    vm_priority = cfg.get("vm_priority", "Regular")

    # Spot pricing in Azure typically runs 60–90% off PAYG. We use a
    # conservative 80% discount so the cost line is realistic-low rather
    # than wildly optimistic. Actual spot price floats with capacity.
    spot_multiplier = 0.20 if vm_priority == "Spot" else 1.0

    # Roles that are PINNED to Regular even when --spot is set globally
    # (matches local.spot_pinned_roles in modules/azure/images.tf).
    # Eviction during their bootstrap or steady-state breaks the range,
    # so they stay PAYG. Cost reflects this.
    SPOT_PINNED_ROLES = {"windows-dc", "c2-redirector"}

    # ---- bucket VMs by SKU ------------------------------------------------
    sku_count = defaultdict(int)        # all VMs by SKU
    family_cores = defaultdict(int)     # quota math, always all VMs
    sku_count_spot = defaultdict(int)   # subset that gets the Spot discount
    sku_count_pinned = defaultdict(int) # subset pinned to Regular even under --spot

    def add(sku: str, eligible_for_spot: bool) -> None:
        sku_count[sku] += 1
        family_cores[SKU_FAMILY[sku]] += SKU_CORES[sku]
        if vm_priority == "Spot":
            if eligible_for_spot:
                sku_count_spot[sku] += 1
            else:
                sku_count_pinned[sku] += 1

    for m in machines:
        add(vm_size_for_machine(m),
            eligible_for_spot=m["role"] not in SPOT_PINNED_ROLES)
    for s in shared:
        add(vm_size_for_shared(s), eligible_for_spot=True)

    # Hub services (always present when services.elk.enabled / .guacamole.enabled)
    if services.get("elk", {}).get("enabled"):
        add(HUB_SERVICES_SKU["elk"], eligible_for_spot=True)
    if services.get("guacamole", {}).get("enabled"):
        add(HUB_SERVICES_SKU["guacamole"], eligible_for_spot=True)

    # ---- cost components --------------------------------------------------
    vm_cost_payg = sum(SKU_PRICE_USD_MO[sku] * count
                       for sku, count in sku_count.items())
    if vm_priority == "Spot":
        # Pinned roles stay PAYG; the rest get the Spot discount.
        vm_cost = round(
            sum(SKU_PRICE_USD_MO[sku] * count for sku, count in sku_count_pinned.items())
            + sum(SKU_PRICE_USD_MO[sku] * count * spot_multiplier
                  for sku, count in sku_count_spot.items())
        )
    else:
        vm_cost = vm_cost_payg

    n_students = len({m["student_id"] for m in machines})

    # Public IPs (Standard ≈ $3.65/mo). Honours the per-resource
    # public_ip toggles introduced for redteam-lab.
    pip_count = 0
    if services.get("guacamole", {}).get("enabled"):
        pip_count += 1                               # Guacamole always has PIP
    if services.get("elk", {}).get("enabled") and services.get("elk", {}).get("public_ip", True):
        pip_count += 1
    pip_count += sum(1 for s in shared if s.get("public_ip", True))
    if advanced_c2:
        pip_count += sum(1 for m in machines if m["role"] == "c2-redirector")
    if not lockdown:
        pip_count += n_students                      # NAT gateway PIP per VNet

    # NAT gateway (one per student VNet, ~$32/mo each, only when not lockdown).
    nat_cost = 0 if lockdown else n_students * 32

    pip_cost     = pip_count * 4   # PIP + minimal data egress
    afd_cost     = 35 if advanced_c2 else 0
    n_disks      = len(machines) + len(shared)
    if services.get("elk", {}).get("enabled"):       n_disks += 1
    if services.get("guacamole", {}).get("enabled"): n_disks += 1
    storage_cost = n_disks * 5    # OS disks ~$5/mo each (Standard SSD 30-200GB)

    total = vm_cost + pip_cost + nat_cost + afd_cost + storage_cost

    # ---- print report -----------------------------------------------------
    print(f"Range: {range_name}   region: {region}")
    print()
    pinned_total = sum(sku_count_pinned.values())
    spot_total   = sum(sku_count_spot.values())
    if vm_priority == "Spot":
        header = (f"VMs by SKU ({sum(sku_count.values())} total — "
                  f"{spot_total} Spot, {pinned_total} pinned to Regular "
                  f"[DC + redirectors])")
    else:
        header = f"VMs by SKU ({sum(sku_count.values())} total)"
    print(header)

    for sku, count in sorted(sku_count.items()):
        cores_total = SKU_CORES[sku] * count
        if vm_priority == "Spot":
            sp = sku_count_spot.get(sku, 0)
            pn = sku_count_pinned.get(sku, 0)
            price_total = round(
                SKU_PRICE_USD_MO[sku] * sp * spot_multiplier
                + SKU_PRICE_USD_MO[sku] * pn
            )
            mix = (f" (Spot×{sp}+Reg×{pn})"
                   if pn > 0 and sp > 0 else
                   "" if (pn == 0 or sp == 0) else "")
        else:
            price_total = SKU_PRICE_USD_MO[sku] * count
            mix = ""
        print(f"  {sku:20s}  count={count:<3d}  cores={cores_total:<3d}  "
              f"~${price_total}/mo{mix}")
    print()

    print(f"Cost estimate (rough PAYG, USD/month — varies ±15% by region):")
    print(f"  VMs               ${vm_cost:>5}")
    print(f"  Public IPs ({pip_count:<2d})    ${pip_cost:>5}")
    print(f"  NAT gateways ({n_students if not lockdown else 0:<2d})  ${nat_cost:>5}"
          f"  ({'lockdown=true → no NAT' if lockdown else 'lockdown=false'})")
    print(f"  AFD               ${afd_cost:>5}  ({'enabled' if advanced_c2 else 'disabled'})")
    print(f"  OS disks          ${storage_cost:>5}")
    print(f"  ----- ")
    print(f"  TOTAL          ~${total:>4}/mo")
    print()
    print("  (Public-list pricing; ignores reservations, savings plans, data")
    print("   egress, and per-region variations. Lock down after first build")
    print("   to drop the NAT cost: ./range lock)")
    print()

    # ---- quota check ------------------------------------------------------
    # Threshold-driven auto-request: if post-deploy projected usage on
    # any quota family exceeds HEADROOM_THRESHOLD of the current limit,
    # we file a quota-increase request via the Microsoft.Quota REST API
    # (via `az rest`) without waiting for the apply to fail. Disable
    # with TERRARANGE_AUTO_QUOTA=0; tune the threshold via
    # TERRARANGE_QUOTA_THRESHOLD (default 0.30 = 30%).
    HEADROOM_THRESHOLD = float(os.environ.get("TERRARANGE_QUOTA_THRESHOLD", "0.30"))
    AUTO_QUOTA         = os.environ.get("TERRARANGE_AUTO_QUOTA", "1") == "1"

    print(f"Azure quota check (region: {region})")
    if not shutil.which("az"):
        print("  [?] az CLI not on PATH — quota check skipped")
        return 0

    sub_id = ""
    try:
        sub_id = subprocess.run(
            ["az", "account", "show", "--query", "id", "-o", "tsv"],
            capture_output=True, text=True, timeout=15, check=False
        ).stdout.strip()
    except Exception:
        pass

    over_quota = False
    over_threshold = []  # families where projected/limit >= threshold
    for family, needed in sorted(family_cores.items()):
        used, limit = query_quota(region, family)
        if limit is None:
            print(f"  [?] {family}: couldn't query (not logged in? wrong sub?)")
            continue
        available = limit - used
        projected = used + needed
        pct = (projected / limit) if limit else 1.0
        bar = f"{projected}/{limit} ({pct:.0%} projected)"
        if available >= needed:
            print(f"  [+] {family}: need {needed}, available {available}  {bar}")
        else:
            shortfall = needed - available
            print(f"  [!] {family}: NEED {needed}, AVAILABLE {available}  {bar} — short by {shortfall}")
            over_quota = True
        if pct >= HEADROOM_THRESHOLD:
            over_threshold.append((family, used, limit, projected))

    # ---- non-vCPU network-namespace quotas --------------------------------
    # Public IP quota is the #1 quota terra-range hits after vCPU on a
    # fresh subscription. Default limit on a new sub is often 10 Standard
    # PIPs per region; an 8-student isolated apply easily projects ~25-40.
    # Add VNet / NAT-gateway / NSG checks for completeness — they share
    # the same namespace, so listing them is free.
    print()
    print("Network-namespace quota check (non-vCPU resources)")
    needed_network: dict[str, int] = {
        "public_ips_standard": pip_count,
        # One VNet per student in isolated, plus shared-guac/elk hub VNet
        # collapses to part of the same VNets so n_students is a tight
        # upper bound. NSGs roughly track 1:1 with VNets (one per VNet
        # subnet, terra-range uses ~3 subnets per VNet → multiplied).
        "vnets":         max(1, n_students),
        "nsgs":          max(1, n_students * 3),
        "nat_gateways":  0 if lockdown else n_students,
    }
    network_quotas = query_network_quotas(region)
    if not network_quotas:
        print("  [?] az network list-usages returned nothing — region not logged in?")
    else:
        for short, needed in needed_network.items():
            if needed <= 0 or short not in network_quotas:
                continue
            canonical, used, limit = network_quotas[short]
            available = limit - used
            projected = used + needed
            pct = (projected / limit) if limit else 1.0
            bar = f"{projected}/{limit} ({pct:.0%} projected)"
            label = f"{canonical} ({short})"
            if available >= needed:
                print(f"  [+] {label}: need {needed}, available {available}  {bar}")
            else:
                shortfall = needed - available
                print(f"  [!] {label}: NEED {needed}, AVAILABLE {available}  {bar} — short by {shortfall}")
                over_quota = True
            if pct >= HEADROOM_THRESHOLD:
                # Tag network quotas distinctly so the auto-request path
                # routes them to Microsoft.Network rather than
                # Microsoft.Compute.
                over_threshold.append((f"NET:{canonical}", used, limit, projected))

    if over_threshold:
        print()
        thr_pct = int(HEADROOM_THRESHOLD * 100)
        print(f"  [⤴] {len(over_threshold)} family/families ≥ {thr_pct}% projected usage")
        if AUTO_QUOTA and sub_id:
            print(f"  [⤴] auto-requesting quota increase (TERRARANGE_AUTO_QUOTA=1)")
            for family, used, limit, projected in over_threshold:
                # Aim for 4× projected post-deploy usage so we don't have
                # to come back. Floor at 2× current limit so micro-bumps
                # don't waste the request slot.
                new_limit = max(limit * 2, projected * 4)
                # NET:* prefix means a network-namespace family — route
                # the REST PUT through Microsoft.Network rather than
                # Microsoft.Compute. Both share the same Microsoft.Quota
                # API shape, only the parent provider in the scope URL
                # differs.
                if family.startswith("NET:"):
                    canonical = family[len("NET:"):]
                    ok, msg = _request_quota_increase(
                        sub_id, region, canonical, new_limit,
                        provider="Microsoft.Network",
                        canonical_name=canonical,
                    )
                else:
                    ok, msg = _request_quota_increase(sub_id, region, family, new_limit)
                marker = "[+]" if ok else "[!]"
                print(f"    {marker} {family}: {limit} -> {new_limit}  ({msg})")
            print()
            print("  Quota requests are queued by Azure; approval is async.")
            print("  Track them: az rest --method get --url \\")
            print("    \"https://management.azure.com/subscriptions/$(az account show "
                  "--query id -o tsv)/providers/Microsoft.Quota/quotaRequests"
                  "?api-version=2023-02-01\"")
        else:
            print("  Auto-request disabled (TERRARANGE_AUTO_QUOTA=0 or not logged in).")
            print("  Request a quota increase in Azure Portal:")
            print("    Subscriptions → <your sub> → Usage + quotas → Request increase")

    if over_quota:
        return 2

    return 0


def _request_quota_increase(sub_id: str, region: str, family: str,
                            new_limit: int,
                            provider: str = "Microsoft.Compute",
                            canonical_name: str | None = None,
                            ) -> tuple[bool, str]:
    """Best-effort Microsoft.Quota REST PUT. Returns (ok, message).

    Resolves the canonical resource name (e.g. "standardDSv5Family") by
    listing current quotas, matching the localizedValue, and using its
    name.value. Falls back gracefully if any step fails — the operator
    can always file the request via the portal.

    Pass `provider="Microsoft.Network"` for network-namespace quotas
    (Public IPs, VNets, NSGs, NAT gateways). Pass `canonical_name` to
    skip the localizedValue lookup when you already know the canonical
    `name.value` (network quotas use the canonical name directly,
    e.g. "StandardSkuPublicIPAddresses").
    """
    scope = f"subscriptions/{sub_id}/providers/{provider}/locations/{region}"
    try:
        resource_name = canonical_name
        if not resource_name:
            # Resolve display name -> canonical name via list.
            list_url = (f"https://management.azure.com/{scope}/providers/"
                        f"Microsoft.Quota/quotas?api-version=2023-02-01")
            r = subprocess.run(
                ["az", "rest", "--method", "get", "--url", list_url],
                capture_output=True, text=True, timeout=30, check=False)
            if r.returncode != 0:
                return False, f"list failed: {r.stderr.strip()[:120]}"
            items = json.loads(r.stdout or "{}").get("value", [])
            for it in items:
                n = it.get("properties", {}).get("name", {}) or {}
                if n.get("localizedValue") == family:
                    resource_name = n.get("value")
                    break
        if not resource_name:
            return False, "couldn't resolve resource name from family"

        put_url = (f"https://management.azure.com/{scope}/providers/"
                   f"Microsoft.Quota/quotas/{resource_name}"
                   f"?api-version=2023-02-01")
        body = {
            "properties": {
                "limit": {
                    "limitObjectType": "LimitValue",
                    "value": int(new_limit),
                },
                "name": {"value": resource_name},
                "resourceType": "dedicated",
            }
        }
        r = subprocess.run(
            ["az", "rest", "--method", "put", "--url", put_url,
             "--body", json.dumps(body),
             "--headers", "Content-Type=application/json"],
            capture_output=True, text=True, timeout=60, check=False)
        if r.returncode == 0:
            return True, "queued"
        # Common failure modes: support plan required, role missing, etc.
        msg = (r.stderr or r.stdout).strip()
        # Tighten to a single useful line.
        for line in msg.splitlines():
            line = line.strip()
            if line and not line.startswith(("{", "}", '"')):
                msg = line
                break
        return False, msg[:140]
    except Exception as e:
        return False, str(e)[:120]


if __name__ == "__main__":
    sys.exit(main())
