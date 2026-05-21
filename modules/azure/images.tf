################################################################################
# Image map. Marketplace images for Kali (and Windows desktop on some
# subscriptions) require terms acceptance once per subscription:
#
#   az vm image terms accept --urn kali-linux:kali:kali-2026:latest
#   az vm image terms accept --urn microsoftwindowsdesktop:windows-11:win11-25h2-pro:latest
#
# Or in bulk (and to refresh SKU pins to the latest published image):
#
#   ./range accept-marketplace                  # accept-only, list latest
#   ./range accept-marketplace --update-images  # accept + rewrite this file
#
# Windows 10/11 client SKUs in Azure additionally require Multi-tenant
# Hosting Rights or a qualifying Visual Studio subscription. See:
#   https://learn.microsoft.com/azure/virtual-machines/windows/windows-desktop-multitenant-hosting-deployment
################################################################################

locals {
  # source_image_id for the pre-baked Server 2022 (DC). Non-null ONLY
  # when baking.enabled (the gallery exists) AND use_baked_win_server_2022
  # (operator opted in, after `./range bake server-2022` published a
  # version). vms.tf uses it in a `source_image_id != null ? ...` check;
  # when null the Marketplace publisher/offer/sku path below is used.
  # NO try() here — it does NOT catch a data-source read failure, and
  # the data source's `count` matches this exact condition, so when
  # this is true the [0] index is valid. If use_baked_* is set but no
  # version was actually baked, the read fails LOUDLY — the correct,
  # actionable error ("bake first").
  baked_win_server_2022_id = (
    (var.baking.enabled && var.baking.use_baked_win_server_2022)
    ? data.azurerm_shared_image_version.win_server_2022_ad[0].id
    : null
  )

  # source_image_id for the pre-baked Kali attacker image — same gating
  # as baked_win_server_2022_id. Non-null only after `./range bake kali`
  # + baking.use_baked_kali:true; then it resolves to the SIG version's
  # id and every deploy skips the ~15-30 min kali-linux-default install.
  baked_kali_id = (
    (var.baking.enabled && var.baking.use_baked_kali)
    ? data.azurerm_shared_image_version.kali_redteam[0].id
    : null
  )

  # Same gating pattern as the two above for the remaining baked images.
  # Each one resolves to a SIG image version id when (a) baking.enabled
  # AND (b) the per-image use_baked_<x> flag is true. The corresponding
  # data.azurerm_shared_image_version block in baking.tf has `count`
  # matching the SAME condition, so the [0] index is always valid here.
  # If the operator sets use_baked_<x> = true BEFORE ever running
  # `./range bake <x>` (i.e. no version exists in the gallery yet), the
  # data-source read fails LOUDLY at plan time — the correct,
  # actionable error: "bake first".
  baked_win_server_2019_id = (
    (var.baking.enabled && var.baking.use_baked_win_server_2019)
    ? data.azurerm_shared_image_version.win_server_2019[0].id
    : null
  )
  baked_win_server_2025_id = (
    (var.baking.enabled && var.baking.use_baked_win_server_2025)
    ? data.azurerm_shared_image_version.win_server_2025[0].id
    : null
  )
  baked_win_10_id = (
    (var.baking.enabled && var.baking.use_baked_win_10)
    ? data.azurerm_shared_image_version.win_10[0].id
    : null
  )
  baked_win_11_id = (
    (var.baking.enabled && var.baking.use_baked_win_11)
    ? data.azurerm_shared_image_version.win_11[0].id
    : null
  )
  baked_elk_id = (
    (var.baking.enabled && var.baking.use_baked_elk)
    ? data.azurerm_shared_image_version.elk[0].id
    : null
  )
  baked_redelk_id = (
    (var.baking.enabled && var.baking.use_baked_redelk)
    ? data.azurerm_shared_image_version.redelk[0].id
    : null
  )
  baked_debian_redirector_id = (
    (var.baking.enabled && var.baking.use_baked_debian_redirector)
    ? data.azurerm_shared_image_version.debian_redirector[0].id
    : null
  )
  baked_guacamole_id = (
    (var.baking.enabled && var.baking.use_baked_guacamole)
    ? data.azurerm_shared_image_version.guacamole[0].id
    : null
  )
  baked_adaptix_id = (
    (var.baking.enabled && var.baking.use_baked_adaptix)
    ? data.azurerm_shared_image_version.adaptix[0].id
    : null
  )
  baked_mythic_id = (
    (var.baking.enabled && var.baking.use_baked_mythic)
    ? data.azurerm_shared_image_version.mythic[0].id
    : null
  )
  baked_sliver_id = (
    (var.baking.enabled && var.baking.use_baked_sliver)
    ? data.azurerm_shared_image_version.sliver[0].id
    : null
  )
  baked_ghostwriter_id = (
    (var.baking.enabled && var.baking.use_baked_ghostwriter)
    ? data.azurerm_shared_image_version.ghostwriter[0].id
    : null
  )
  baked_stepping_stones_id = (
    (var.baking.enabled && var.baking.use_baked_stepping_stones)
    ? data.azurerm_shared_image_version.stepping_stones[0].id
    : null
  )

  # Per-machine source_image_id resolution. Priority order:
  #   1. ROLE-specific baked image — elk / redelk / c2-redirector
  #      images carry pre-installed role-specific software (Elasticsearch
  #      / RedELK docker stack / nginx + base packages). The machine's
  #      `os` stays "debian-12" in the scenario YAML; the role dispatch
  #      here picks the baked image transparently at apply time. Operator
  #      opts in per-role via use_baked_elk / use_baked_redelk /
  #      use_baked_debian_redirector flags.
  #   2. OS-specific baked image — kali / windows-* images. Picked
  #      when the OS family matches AND the corresponding baked image
  #      exists. (Versus role: a Windows-* image is the SAME image
  #      regardless of role; the role determines what cloud-init does
  #      with it.)
  #   3. null — vms.tf falls back to the Marketplace publisher/offer/sku
  #      from local.image_map[m.os].
  #
  # Each row: if the predicate (role match / os match) is true AND the
  # baked image is actually present, use it. Otherwise fall through to
  # the next row. Null at the end = use Marketplace.
  # Per-shared-machine source_image_id resolution. Same priority shape
  # as machine_source_image_id but for var.shared_machines (the hub-tier
  # VMs like ghostwriter, stepping-stones, redelk that live in the hub
  # VNet instead of per-student VNets). Shared VMs don't have a `role`
  # vs `os` distinction the way per-student VMs do — every shared role
  # is one-of-a-kind, so dispatch is purely role-based.
  #
  # Returns null when no baked image applies, in which case
  # shared_infra.tf falls back to the dynamic source_image_reference
  # block (which renders Marketplace publisher/offer/sku from
  # local.image_map[s.os]).
  shared_source_image_id = {
    for s in var.shared_machines :
    s.name => (
      (s.role == "ghostwriter" && local.baked_ghostwriter_id != null) ? local.baked_ghostwriter_id :
      (s.role == "stepping-stones" && local.baked_stepping_stones_id != null) ? local.baked_stepping_stones_id :
      (s.role == "redelk" && local.baked_redelk_id != null) ? local.baked_redelk_id :
      null
    )
  }

  machine_source_image_id = {
    for m in var.machines :
    m.name => (
      (m.role == "elk" && local.baked_elk_id != null) ? local.baked_elk_id :
      (m.role == "redelk" && local.baked_redelk_id != null) ? local.baked_redelk_id :
      (m.role == "c2-redirector" && local.baked_debian_redirector_id != null) ? local.baked_debian_redirector_id :
      # C2 teamserver role-dispatch — each framework gets its own
      # baked image with the heavy install (Go toolchain + git clone +
      # compile / docker pulls / binary download) already done. Saves
      # ~10-15 min on adaptix/mythic, ~2-3 min on sliver. brc4 has no
      # bake target because BRC4's binary download is per-deploy
      # license-gated (operator's specific Azure Blob SAS URL).
      (m.role == "c2-server" && local.baked_adaptix_id != null) ? local.baked_adaptix_id :
      (m.role == "c2-mythic" && local.baked_mythic_id != null) ? local.baked_mythic_id :
      (m.role == "c2-sliver" && local.baked_sliver_id != null) ? local.baked_sliver_id :
      (m.os == "windows-server-2025" && local.baked_win_server_2025_id != null) ? local.baked_win_server_2025_id :
      (m.os == "windows-server-2022" && local.baked_win_server_2022_id != null) ? local.baked_win_server_2022_id :
      (m.os == "windows-server-2019" && local.baked_win_server_2019_id != null) ? local.baked_win_server_2019_id :
      (m.os == "windows-10" && local.baked_win_10_id != null) ? local.baked_win_10_id :
      (m.os == "windows-11" && local.baked_win_11_id != null) ? local.baked_win_11_id :
      (m.os == "kali" && local.baked_kali_id != null) ? local.baked_kali_id :
      null
    )
  }

  image_map = {
    "windows-server-2019" = {
      publisher = "MicrosoftWindowsServer"
      offer     = "WindowsServer"
      sku       = "2019-datacenter-gensecond"
      version   = "latest"
      # No baked version yet for 2019. Add an azurerm_shared_image
      # block + Packer template if you want to bake this one too.
      source_image_id = null
    }
    "windows-server-2022" = {
      publisher       = "MicrosoftWindowsServer"
      offer           = "WindowsServer"
      sku             = "2019-datacenter-gensecond"
      version         = "latest"
      source_image_id = local.baked_win_server_2022_id
    }
    "windows-server-2025" = {
      publisher = "MicrosoftWindowsServer"
      offer     = "WindowsServer"
      # Fixed: was pinned to "2019-datacenter-gensecond" (copy-paste
      # bug from when this entry was first added). 2025 ships under
      # the same publisher/offer with this SKU. Marketplace terms
      # need acceptance once per sub:
      #   az vm image terms accept --urn microsoftwindowsserver:WindowsServer:2025-datacenter-azure-edition:latest
      sku             = "2025-datacenter-azure-edition"
      version         = "latest"
      source_image_id = local.baked_win_server_2025_id
    }
    "windows-10" = {
      publisher       = "MicrosoftWindowsDesktop"
      offer           = "Windows-10"
      sku             = "win10-22h2-pro-g2"
      version         = "latest"
      source_image_id = null
    }
    "windows-11" = {
      publisher       = "MicrosoftWindowsDesktop"
      offer           = "windows-11"
      sku             = "win11-25h2-pro"
      version         = "latest"
      source_image_id = null
    }
    "ubuntu-22" = {
      publisher       = "Canonical"
      offer           = "0001-com-ubuntu-server-jammy"
      sku             = "22_04-lts-gen2"
      version         = "latest"
      source_image_id = null
    }
    "ubuntu-24" = {
      publisher       = "Canonical"
      offer           = "ubuntu-24_04-lts"
      sku             = "server"
      version         = "latest"
      source_image_id = null
    }
    "debian-12" = {
      publisher       = "Debian"
      offer           = "debian-12"
      sku             = "12-gen2"
      version         = "latest"
      source_image_id = null
    }
    "kali" = {
      publisher = "kali-linux"
      offer     = "kali"
      # Kali uses YYYY-N quarterly format. Run
      # `./range accept-marketplace --update-images` to auto-bump to the
      # freshest *stable* SKU available in YOUR subscription's market.
      # NOTE: publisher/offer/sku stay populated even when a baked image
      # is used — vms.tf still needs them for the marketplace `plan`
      # block (Kali is a plan-required Marketplace offer; the SIG image
      # inherits the plan requirement) and for the Marketplace fallback
      # when nothing has been baked yet.
      sku     = "kali-2026-1"
      version = "latest"
      # Pre-baked SIG image when `./range bake kali` has run + baking is
      # enabled; null otherwise → vms.tf falls back to the Marketplace
      # source_image_reference above.
      source_image_id = local.baked_kali_id
    }
  }

  # Generic size hint map (used for attacker/c2-* and shared-infra VMs).
  size_map = {
    small  = "Standard_B2s"  # 2 vCPU, 4 GB
    medium = "Standard_B4ms" # 4 vCPU, 16 GB
    large  = "Standard_B8ms" # 8 vCPU, 32 GB
  }

  # Role-aware effective VM size per machine. Enforces minimums:
  #   - windows-dc gets D8s_v5 (8 vCPU) when fast_windows=true to halve
  #     the Windows-Update + AD-promo phase; D4s_v5 (4 vCPU) otherwise.
  #   - other windows-* always get 16 GB (Standard_D4s_v5)
  #   - linux-target always gets 8 GB+ (Standard_D2s_v5)
  #   - attacker / c2-* honour YAML `size:` via size_map
  #   - windows-blank (GOAD nodes) gets 16 GB to match member capacity
  vm_size = {
    for m in var.machines :
    m.name => (
      m.role == "windows-dc" ? (var.fast_windows ? "Standard_D8s_v5" : "Standard_D4s_v5") :
      contains([
        "windows-member", "windows-workstation", "windows-blank"
      ], m.role) ? "Standard_D4s_v5" : # 4 vCPU / 16 GB
      # windows-analyst (FLARE-VM): 4 vCPU / 16 GB. The user-stated
      # minimum is 4 GB RAM, but Ghidra + IDA + dnSpy + a few VMware
      # samples eat RAM fast; 16 GB is the realistic floor. Bump to
      # D8s_v5 (32 GB) in the YAML via size: large if you do heavy
      # multi-sample work.
      m.role == "windows-analyst" ? "Standard_D4s_v5" :
      m.role == "linux-target" ? "Standard_D2s_v5" : # 2 vCPU / 8 GB
      local.size_map[m.size]                         # default per size hint
    )
  }

  is_windows = {
    for m in var.machines :
    m.name => can(regex("^windows", m.os))
  }

  # Critical-infrastructure roles that stay Regular priority even when
  # --spot is set globally (var.vm_priority == "Spot"). Eviction of any
  # of these mid-bootstrap or mid-validation breaks the range:
  #
  #   - windows-dc      → mid-promotion eviction = corrupt forest;
  #                       AD cannot recover from partial state.
  #   - c2-redirector   → eviction during AFD's cert-validation poll
  #                       leaves the custom domain in Rejected state;
  #                       requires `terraform taint` + reapply.
  #
  # Cost of this safety on redteam-lab: ~4 VMs (DC + 3 redirectors)
  # stay PAYG (~$230/mo) while the other 11 boxes ride Spot. Net is
  # still 60-70% off PAYG for the whole range.
  spot_pinned_roles = ["windows-dc", "c2-redirector"]
}
