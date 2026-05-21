################################################################################
# Image map for the GCP module — marketplace fallback + per-machine baked-image
# resolution. The GCP equivalent of modules/azure/images.tf.
#
# How GCP image addressing differs from Azure (read this BEFORE editing):
#
#   - Azure has a Shared Image Gallery with image DEFINITIONS (slots) and image
#     VERSIONS (publishings). terraform owns the slots; packer publishes the
#     versions; data.azurerm_shared_image_version reads the latest back.
#
#   - GCP has NO gallery resource. Images live flat in
#     `projects/<proj>/global/images/<name>` and are grouped by an
#     `image_family` STRING. The first packer build that publishes with
#     `family = "kali-redteam"` creates the family conceptually; subsequent
#     bakes append new images, and `data.google_compute_image` with
#     `family = "kali-redteam"` returns the latest non-deprecated one. So:
#       Azure SIG image definition    →  a packer-side `image_family` string
#       Azure SIG image version       →  `data.google_compute_image { family = ... }`
#       Azure `purchase_plan`         →  N/A on GCP (no marketplace plan)
#       Azure `hyper_v_generation`    →  N/A; use `guest_os_features` UEFI flag
#
#   - Marketplace images on GCP are PUBLIC `google_compute_image` resources
#     in publisher projects (e.g. `windows-cloud`, `debian-cloud`,
#     `kali-linux-public`). No terms acceptance, no per-subscription plan
#     ritual — just reference them by family or self-link.
#
# Contract this file exports (matched 1:1 with modules/azure/images.tf so the
# vms.tf agent's call sites look the same on both clouds):
#
#   local.baked_<image>_id          – non-null self-link when baking.enabled
#                                     AND baking.use_baked_<image>; null otherwise
#   local.machine_source_image_id   – per-machine resolved image: role-first,
#                                     then OS-first, then null (= marketplace
#                                     fallback via local.image_map[m.os])
#   local.shared_source_image_id    – same shape for var.shared_machines
#   local.image_map                 – marketplace family path keyed by OS
#                                     (consumed by vms.tf when the baked id
#                                     resolves to null)
################################################################################

locals {
  # ──────────────────────────────────────────────────────────────────────────
  # Per-baked-image self-link. Non-null ONLY when baking.enabled (the family
  # slot has been declared via packer) AND use_baked_<image> (operator opted
  # in, after `./range bake <image>` published an image into the family).
  # vms.tf uses these in `source_image_id != null ? ...` checks; when null
  # the local.image_map[m.os] marketplace family path below is used instead.
  #
  # Same loud-failure pattern as the Azure module: if use_baked_<x> is set
  # but no image has actually been baked into the family yet, the
  # data.google_compute_image lookup in baking.tf FAILS at plan time —
  # the correct, actionable error ("bake first"). No try() wrapping;
  # try() does not catch data-source read failures on either cloud, and
  # the data source's `count` matches this exact condition so the [0]
  # index is always safe when the predicate is true.
  # ──────────────────────────────────────────────────────────────────────────

  baked_win_server_2022_id = (
    (var.baking.enabled && var.baking.use_baked_win_server_2022)
    ? data.google_compute_image.win_server_2022_ad[0].self_link
    : null
  )

  # Same gating as baked_win_server_2022_id. Non-null only after
  # `./range bake kali` + baking.use_baked_kali:true; then it resolves to
  # the kali-redteam family's latest image self-link and every deploy
  # skips the ~15-30 min kali-linux-default install.
  baked_kali_id = (
    (var.baking.enabled && var.baking.use_baked_kali)
    ? data.google_compute_image.kali_redteam[0].self_link
    : null
  )

  # Remaining baked images — same gating pattern.
  baked_win_server_2019_id = (
    (var.baking.enabled && var.baking.use_baked_win_server_2019)
    ? data.google_compute_image.win_server_2019[0].self_link
    : null
  )
  baked_win_server_2025_id = (
    (var.baking.enabled && var.baking.use_baked_win_server_2025)
    ? data.google_compute_image.win_server_2025[0].self_link
    : null
  )
  baked_win_10_id = (
    (var.baking.enabled && var.baking.use_baked_win_10)
    ? data.google_compute_image.win_10[0].self_link
    : null
  )
  baked_win_11_id = (
    (var.baking.enabled && var.baking.use_baked_win_11)
    ? data.google_compute_image.win_11[0].self_link
    : null
  )
  baked_elk_id = (
    (var.baking.enabled && var.baking.use_baked_elk)
    ? data.google_compute_image.elk[0].self_link
    : null
  )
  baked_redelk_id = (
    (var.baking.enabled && var.baking.use_baked_redelk)
    ? data.google_compute_image.redelk[0].self_link
    : null
  )
  baked_debian_redirector_id = (
    (var.baking.enabled && var.baking.use_baked_debian_redirector)
    ? data.google_compute_image.debian_redirector[0].self_link
    : null
  )
  baked_guacamole_id = (
    (var.baking.enabled && var.baking.use_baked_guacamole)
    ? data.google_compute_image.guacamole[0].self_link
    : null
  )
  baked_adaptix_id = (
    (var.baking.enabled && var.baking.use_baked_adaptix)
    ? data.google_compute_image.adaptix[0].self_link
    : null
  )
  baked_mythic_id = (
    (var.baking.enabled && var.baking.use_baked_mythic)
    ? data.google_compute_image.mythic[0].self_link
    : null
  )
  baked_sliver_id = (
    (var.baking.enabled && var.baking.use_baked_sliver)
    ? data.google_compute_image.sliver[0].self_link
    : null
  )
  baked_ghostwriter_id = (
    (var.baking.enabled && var.baking.use_baked_ghostwriter)
    ? data.google_compute_image.ghostwriter[0].self_link
    : null
  )
  baked_stepping_stones_id = (
    (var.baking.enabled && var.baking.use_baked_stepping_stones)
    ? data.google_compute_image.stepping_stones[0].self_link
    : null
  )

  # ──────────────────────────────────────────────────────────────────────────
  # Per-shared-machine source_image_id resolution. Same priority shape as
  # machine_source_image_id but for var.shared_machines (the hub-tier VMs
  # like ghostwriter / stepping-stones / redelk that live in the hub VPC
  # instead of per-student VPCs). Shared VMs don't have a `role` vs `os`
  # distinction the way per-student VMs do — every shared role is
  # one-of-a-kind, so dispatch is purely role-based.
  #
  # Returns null when no baked image applies, in which case shared_infra.tf
  # falls back to the marketplace family path via local.image_map[s.os].
  # ──────────────────────────────────────────────────────────────────────────
  shared_source_image_id = {
    for s in var.shared_machines :
    s.name => (
      (s.role == "ghostwriter" && local.baked_ghostwriter_id != null) ? local.baked_ghostwriter_id :
      (s.role == "stepping-stones" && local.baked_stepping_stones_id != null) ? local.baked_stepping_stones_id :
      (s.role == "redelk" && local.baked_redelk_id != null) ? local.baked_redelk_id :
      null
    )
  }

  # ──────────────────────────────────────────────────────────────────────────
  # Per-machine source_image_id resolution. Priority order (matches Azure):
  #   1. ROLE-specific baked image — elk / redelk / c2-redirector images carry
  #      pre-installed role-specific software (Elasticsearch / RedELK docker
  #      stack / nginx + base packages). The machine's `os` stays "debian-12"
  #      in the scenario YAML; the role dispatch here picks the baked image
  #      transparently at apply time.
  #   2. OS-specific baked image — kali / windows-* images. Picked when the
  #      OS family matches AND the corresponding baked image exists.
  #   3. null — vms.tf falls back to local.image_map[m.os] (marketplace family).
  #
  # The C2-teamserver roles (c2-server / c2-mythic / c2-sliver) each get
  # their own baked image because the heavy install (Go toolchain + git
  # clone + compile / docker pulls / binary download) saves ~10-15 min on
  # adaptix/mythic, ~2-3 min on sliver. brc4 has no bake target (license-
  # gated per-deploy binary download).
  # ──────────────────────────────────────────────────────────────────────────
  machine_source_image_id = {
    for m in var.machines :
    m.name => (
      (m.role == "elk" && local.baked_elk_id != null) ? local.baked_elk_id :
      (m.role == "redelk" && local.baked_redelk_id != null) ? local.baked_redelk_id :
      (m.role == "c2-redirector" && local.baked_debian_redirector_id != null) ? local.baked_debian_redirector_id :
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

  # ──────────────────────────────────────────────────────────────────────────
  # Marketplace fallback map keyed by OS. Equivalent of Azure's image_map but
  # GCP-flavoured: each value is a fully-qualified family path string
  # (`projects/<publisher-project>/global/images/family/<family-name>`). VMs
  # consume this via `boot_disk.initialize_params.image` when the per-machine
  # baked source_image_id resolves to null.
  #
  # ─── Windows 10/11 gotcha ────────────────────────────────────────────────
  # GCP does NOT publish Windows client SKUs (Win10 / Win11) on Cloud
  # Marketplace — only Windows SERVER images. The Azure-side scenarios that
  # asked for `os: windows-10` or `os: windows-11` are remapped here to the
  # closest equivalent:
  #
  #   windows-10  →  windows-2022-dc          (Server 2022, no Desktop Experience)
  #   windows-11  →  windows-2022-dc-desktop  (Server 2022, Desktop Experience)
  #
  # ⚠ OPERATOR NOTE: workstation-themed scenarios (FLARE-VM analysts,
  # student workstations, etc.) WILL appear as a Server SKU on GCP. If the
  # scenario genuinely needs a Win10/11 client OS, the only paths are:
  #   (a) BYOL — upload your own Windows client VHD as a custom image and
  #       point baking.use_baked_win_{10,11} at it, or
  #   (b) keep that scenario Azure-only.
  # ─────────────────────────────────────────────────────────────────────────
  image_map = {
    # ── Windows Server (Datacenter) ────────────────────────────────────────
    "windows-server-2025" = "projects/windows-cloud/global/images/family/windows-2025"
    "windows-server-2022" = "projects/windows-cloud/global/images/family/windows-2022"
    "windows-server-2019" = "projects/windows-cloud/global/images/family/windows-2019"

    # ── Windows client SKUs (substituted with Server SKUs — see note above)
    # win10 → Server 2022 Core (no GUI). Run the "Desktop Experience" SKU
    # if a tester needs a graphical session; for headless/automated work
    # the Core image is leaner.
    "windows-10" = "projects/windows-cloud/global/images/family/windows-2022"
    # win11 → Server 2022 with Desktop Experience. This is the GUI-bearing
    # Server SKU; closest visual approximation of a Win11 workstation that
    # GCP publishes.
    "windows-11" = "projects/windows-cloud/global/images/family/windows-2022-dc-desktop"

    # ── Debian / Ubuntu ────────────────────────────────────────────────────
    "debian-12" = "projects/debian-cloud/global/images/family/debian-12"
    "ubuntu-22" = "projects/ubuntu-os-cloud/global/images/family/ubuntu-2204-lts"
    "ubuntu-24" = "projects/ubuntu-os-cloud/global/images/family/ubuntu-2404-lts-amd64"

    # ── Kali Linux ─────────────────────────────────────────────────────────
    # Project name `kali-linux-public` is the current name of the Kali
    # Cloud Marketplace publisher (was `kali-linux-cloud` historically;
    # vendor renamed it in the kali-2022.x era). Overridable via
    # var.kali_marketplace_project if Kali moves it again.
    # TODO(operator): verify against the current GCP marketplace listing
    # at https://console.cloud.google.com/marketplace/product/kali-linux-public/kali-linux
    # — if the publisher project name has shifted, set
    # var.kali_marketplace_project in your tfvars.
    "kali" = "projects/${var.kali_marketplace_project}/global/images/family/kali-rolling"
  }

  # ──────────────────────────────────────────────────────────────────────────
  # GCP machine-type size hints. Maps roughly to Azure Standard_B/D-series:
  #   small   ≈ Standard_B2s     (2 vCPU / 8 GB)   →  e2-standard-2
  #   medium  ≈ Standard_B4ms    (4 vCPU / 16 GB)  →  e2-standard-4
  #   large   ≈ Standard_B8ms    (8 vCPU / 32 GB)  →  e2-standard-8
  # E2 is GCP's cost-optimised family (shared-core to N2D-class blend),
  # comparable to Azure B-series burstables for lab use.
  # ──────────────────────────────────────────────────────────────────────────
  size_map = {
    small  = "e2-standard-2"
    medium = "e2-standard-4"
    large  = "e2-standard-8"
  }

  # Role-aware effective machine type per machine. Enforces minimums:
  #   - windows-dc gets n2-standard-8 (8 vCPU / 32 GB) when fast_windows=true
  #     to halve Windows-Update + AD-promo phase; n2-standard-4 (4 vCPU /
  #     16 GB) otherwise. N2 over E2 here because AD promo is steady-CPU,
  #     not bursty — E2's shared-core boundaries can starve DCPROMO.
  #   - other windows-* always get 16 GB (n2-standard-4)
  #   - linux-target always gets 8 GB+ (e2-standard-2)
  #   - attacker / c2-* honour YAML `size:` via size_map
  #   - windows-blank (GOAD nodes) gets 16 GB to match member capacity
  vm_size = {
    for m in var.machines :
    m.name => (
      m.role == "windows-dc" ? (var.fast_windows ? "n2-standard-8" : "n2-standard-4") :
      contains([
        "windows-member", "windows-workstation", "windows-blank"
      ], m.role) ? "n2-standard-4" : # 4 vCPU / 16 GB
      # windows-analyst (FLARE-VM equivalent): 4 vCPU / 16 GB.
      m.role == "windows-analyst" ? "n2-standard-4" :
      m.role == "linux-target" ? "e2-standard-2" : # 2 vCPU / 8 GB
      local.size_map[m.size]                       # default per size hint
    )
  }

  is_windows = {
    for m in var.machines :
    m.name => can(regex("^windows", m.os))
  }

  # `local.spot_pinned_roles` is defined in modules/gcp/passwords.tf
  # (passwords.tf is the file vms.tf reads it from, and was ported
  # directly from modules/azure/passwords.tf where the same local
  # already existed). Re-declaring it here would cause a "Duplicate
  # local value" error at plan time.
}
