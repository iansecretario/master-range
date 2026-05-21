################################################################################
# Shared Image Gallery for pre-baked images.
#
# Lives in its OWN resource group (not the range RG) so the gallery
# survives `terraform destroy` of any specific range — you don't lose
# your baked images when you tear down a lab. The gallery is regional
# (single region) by default; add to `target_regions` in the image
# definition if you want cross-region replication.
#
# Created only when var.baking.enabled = true. When false (default),
# images.tf falls back to direct Marketplace references — current
# behavior unchanged for operators who haven't baked yet.
################################################################################

resource "azurerm_resource_group" "baking" {
  count    = var.baking.enabled ? 1 : 0
  name     = var.baking.resource_group_name
  location = var.azure_region

  tags = {
    Range = "shared-baking"
    Role  = "image-gallery"
  }

  # The gallery RG holds pre-baked images that take 30-45 min each to
  # rebuild — packer publishes versions OUT-OF-BAND of terraform, so a
  # `terraform destroy` would otherwise drop the RG, the gallery, and
  # every image definition (Azure refuses with 409 CannotDeleteResource
  # when there are nested versions terraform doesn't know about, which
  # would actually be the GOOD failure mode — silently destroying baked
  # artifacts would be worse). prevent_destroy lifts both concerns:
  # `./range destroy` first detaches these resources via `terraform
  # state rm` (see the destroy wrapper) and the Azure resources remain
  # alive for the next deploy.
  lifecycle { prevent_destroy = true }
}

resource "azurerm_shared_image_gallery" "main" {
  count               = var.baking.enabled ? 1 : 0
  name                = var.baking.gallery_name
  resource_group_name = azurerm_resource_group.baking[0].name
  location            = var.azure_region
  description         = "terra-range pre-baked images (DC + members + Kali). Populated by ./range bake."

  tags = {
    Range = "shared-baking"
  }

  # See the lifecycle comment on azurerm_resource_group.baking above for
  # the full rationale. The gallery itself is cheap (~$0.50/mo) but
  # rebuilding it requires re-baking every image (~30-45 min × image).
  lifecycle { prevent_destroy = true }
}

# Image definition: declares the OS family/spec slot in the gallery.
# Packer writes a VERSION into this slot; terraform's
# data.azurerm_shared_image_version reads the latest version back.
#
# We declare one per OS we plan to bake. Adding a new one is just a
# new resource block.

resource "azurerm_shared_image" "win_server_2022_ad" {
  count               = var.baking.enabled ? 1 : 0
  name                = "win-server-2022-ad"
  gallery_name        = azurerm_shared_image_gallery.main[0].name
  resource_group_name = azurerm_resource_group.baking[0].name
  location            = var.azure_region
  os_type             = "Windows"
  hyper_v_generation  = "V2"
  specialized         = false # sysprepped/generalized by packer

  identifier {
    publisher = "terra-range"
    offer     = "win-server-2022-ad"
    sku       = "datacenter-azure-edition"
  }

  # Image definitions parent the packer-published versions. Destroying
  # an image definition while a version exists fails with 409
  # CannotDeleteResource. prevent_destroy + the `./range destroy`
  # wrapper detaches this from state instead of trying to delete it.
  lifecycle { prevent_destroy = true }
}

# Read back the LATEST version of each image definition. Used by
# images.tf to resolve `source_image_id`. Returns nil/error if no
# version has been baked yet, so we wrap the lookup in `try()` in
# images.tf for graceful fallback to Marketplace.

data "azurerm_shared_image_version" "win_server_2022_ad" {
  # Only READ a version when the operator has opted in via
  # use_baked_win_server_2022 — this data source ERRORS the whole apply
  # if no version exists, so it must NOT fire just because the gallery
  # (enabled) exists. count is `enabled && use_baked_*` so the [0]
  # index in images.tf is always safe.
  count               = (var.baking.enabled && var.baking.use_baked_win_server_2022) ? 1 : 0
  name                = "latest"
  image_name          = azurerm_shared_image.win_server_2022_ad[0].name
  gallery_name        = azurerm_shared_image_gallery.main[0].name
  resource_group_name = azurerm_resource_group.baking[0].name
}

# ---- Kali Linux (attacker workstation) ------------------------------------
# Pre-baked with kali-linux-default + XFCE + TigerVNC/xrdp + the
# AdaptixClient build-dependency stack (see packer/kali/kali-redteam.pkr.hcl).
# Cuts the attacker-box deploy from ~30-45 min to ~2-3 min and removes
# the long async metapackage-install task entirely.
#
# `purchase_plan` carries the Kali Marketplace plan through to any VM
# deployed from this image — Kali is a plan-required offer and Azure
# rejects the VM create without it. Kept in sync with the packer
# `plan_info` block and the vms.tf `plan {}` block (os == "kali").

resource "azurerm_shared_image" "kali_redteam" {
  count               = var.baking.enabled ? 1 : 0
  name                = "kali-redteam"
  gallery_name        = azurerm_shared_image_gallery.main[0].name
  resource_group_name = azurerm_resource_group.baking[0].name
  location            = var.azure_region
  os_type             = "Linux"
  hyper_v_generation  = "V2"
  specialized         = false # waagent-deprovisioned/generalized by packer

  identifier {
    publisher = "terra-range"
    offer     = "kali-redteam"
    sku       = "kali-rolling-xfce"
  }

  purchase_plan {
    name      = "kali-2026-1"
    publisher = "kali-linux"
    product   = "kali"
  }

  # See the win_server_2022_ad lifecycle comment. Kali takes ~30-45 min
  # to bake; protect it from accidental terraform destroy. The
  # `./range destroy` wrapper detaches this from state automatically.
  lifecycle { prevent_destroy = true }
}

data "azurerm_shared_image_version" "kali_redteam" {
  # See win_server_2022_ad above — only read once use_baked_kali is set,
  # so an un-baked gallery doesn't fail the apply.
  count               = (var.baking.enabled && var.baking.use_baked_kali) ? 1 : 0
  name                = "latest"
  image_name          = azurerm_shared_image.kali_redteam[0].name
  gallery_name        = azurerm_shared_image_gallery.main[0].name
  resource_group_name = azurerm_resource_group.baking[0].name
}

# ---- Kali Linux MINIMAL (offensive-focused attacker workstation) ----------
# Same operator workstation as kali_redteam (XFCE + xrdp + AdaptixClient
# build deps) but a CURATED, lighter toolset: kali-linux-core + a
# hand-picked set of kali-tools-* groups (top10, information-gathering,
# vulnerability, web, exploitation, passwords, post-exploitation,
# windows-resources, sniffing-spoofing) instead of the full
# kali-linux-default kitchen sink. See packer/kali-minimal/.
#
# `purchase_plan` is identical to kali_redteam: kali-minimal is still
# built FROM the Kali Marketplace base image, so the captured SIG image
# inherits the plan requirement.
#
# NOTE — deploy-side wiring is intentionally deferred. There is no
# `data.azurerm_shared_image_version.kali_minimal`, no
# `use_baked_kali_minimal` flag, and no images.tf image_map entry yet.
# This block ONLY gives `./range bake kali-minimal` an image definition
# to publish into. Wire the deploy path (so scenarios can set
# `os: kali-minimal`) once the image is baked + proven.
resource "azurerm_shared_image" "kali_minimal" {
  count               = var.baking.enabled ? 1 : 0
  name                = "kali-minimal"
  gallery_name        = azurerm_shared_image_gallery.main[0].name
  resource_group_name = azurerm_resource_group.baking[0].name
  location            = var.azure_region
  os_type             = "Linux"
  hyper_v_generation  = "V2"
  specialized         = false # cloud-init-deprovisioned/generalized by packer

  identifier {
    publisher = "terra-range"
    offer     = "kali-minimal"
    sku       = "kali-rolling-xfce"
  }

  purchase_plan {
    name      = "kali-2026-1"
    publisher = "kali-linux"
    product   = "kali"
  }

  # See the win_server_2022_ad lifecycle comment. Same protection
  # applies to every image-definition resource in this file.
  lifecycle { prevent_destroy = true }
}

# ---- Windows Server 2025 (DC-eligible image; AD-DS pre-installed) --------
# Same baked posture as win_server_2022_ad — AD-DS + DNS roles installed
# but NOT promoted (per-deploy domain creation), WinRM/RDP open,
# Guidem wallpaper + privacy/Defender hardening baked in.

resource "azurerm_shared_image" "win_server_2025" {
  count               = var.baking.enabled ? 1 : 0
  name                = "win-server-2025"
  gallery_name        = azurerm_shared_image_gallery.main[0].name
  resource_group_name = azurerm_resource_group.baking[0].name
  location            = var.azure_region
  os_type             = "Windows"
  hyper_v_generation  = "V2"
  specialized         = false

  identifier {
    publisher = "terra-range"
    offer     = "win-server-2025"
    sku       = "datacenter-azure-edition"
  }

  lifecycle { prevent_destroy = true }
}

data "azurerm_shared_image_version" "win_server_2025" {
  count               = (var.baking.enabled && var.baking.use_baked_win_server_2025) ? 1 : 0
  name                = "latest"
  image_name          = azurerm_shared_image.win_server_2025[0].name
  gallery_name        = azurerm_shared_image_gallery.main[0].name
  resource_group_name = azurerm_resource_group.baking[0].name
}

# ---- Windows Server 2019 (member-server role; srv01) ----------------------
# Same posture as win_server_2022_ad but without AD-DS pre-installed.
# Hardening (Guidem wallpaper + privacy off + Defender sample-submission
# off + OOBE suppression) is baked in via the shared
# packer/_shared/scripts/windows-hardening.ps1 provisioner.

resource "azurerm_shared_image" "win_server_2019" {
  count               = var.baking.enabled ? 1 : 0
  name                = "win-server-2019"
  gallery_name        = azurerm_shared_image_gallery.main[0].name
  resource_group_name = azurerm_resource_group.baking[0].name
  location            = var.azure_region
  os_type             = "Windows"
  hyper_v_generation  = "V2"
  specialized         = false

  identifier {
    publisher = "terra-range"
    offer     = "win-server-2019"
    sku       = "datacenter"
  }

  lifecycle { prevent_destroy = true }
}

data "azurerm_shared_image_version" "win_server_2019" {
  count               = (var.baking.enabled && var.baking.use_baked_win_server_2019) ? 1 : 0
  name                = "latest"
  image_name          = azurerm_shared_image.win_server_2019[0].name
  gallery_name        = azurerm_shared_image_gallery.main[0].name
  resource_group_name = azurerm_resource_group.baking[0].name
}

# ---- Windows 10 (workstation role; ws10, analyst pool) --------------------

resource "azurerm_shared_image" "win_10" {
  count               = var.baking.enabled ? 1 : 0
  name                = "win-10"
  gallery_name        = azurerm_shared_image_gallery.main[0].name
  resource_group_name = azurerm_resource_group.baking[0].name
  location            = var.azure_region
  os_type             = "Windows"
  hyper_v_generation  = "V2"
  specialized         = false

  identifier {
    publisher = "terra-range"
    offer     = "win-10"
    sku       = "pro-22h2"
  }

  lifecycle { prevent_destroy = true }
}

data "azurerm_shared_image_version" "win_10" {
  count               = (var.baking.enabled && var.baking.use_baked_win_10) ? 1 : 0
  name                = "latest"
  image_name          = azurerm_shared_image.win_10[0].name
  gallery_name        = azurerm_shared_image_gallery.main[0].name
  resource_group_name = azurerm_resource_group.baking[0].name
}

# ---- Windows 11 (workstation role; ws11) ----------------------------------

resource "azurerm_shared_image" "win_11" {
  count               = var.baking.enabled ? 1 : 0
  name                = "win-11"
  gallery_name        = azurerm_shared_image_gallery.main[0].name
  resource_group_name = azurerm_resource_group.baking[0].name
  location            = var.azure_region
  os_type             = "Windows"
  hyper_v_generation  = "V2"
  specialized         = false

  identifier {
    publisher = "terra-range"
    offer     = "win-11"
    sku       = "pro-25h2"
  }

  lifecycle { prevent_destroy = true }
}

data "azurerm_shared_image_version" "win_11" {
  count               = (var.baking.enabled && var.baking.use_baked_win_11) ? 1 : 0
  name                = "latest"
  image_name          = azurerm_shared_image.win_11[0].name
  gallery_name        = azurerm_shared_image_gallery.main[0].name
  resource_group_name = azurerm_resource_group.baking[0].name
}

# ---- ELK (elastic + kibana + logstash + agent staging) --------------------

resource "azurerm_shared_image" "elk" {
  count               = var.baking.enabled ? 1 : 0
  name                = "elk"
  gallery_name        = azurerm_shared_image_gallery.main[0].name
  resource_group_name = azurerm_resource_group.baking[0].name
  location            = var.azure_region
  os_type             = "Linux"
  hyper_v_generation  = "V2"
  specialized         = false

  identifier {
    publisher = "terra-range"
    offer     = "elk"
    sku       = "debian-12-elastic-8"
  }

  lifecycle { prevent_destroy = true }
}

data "azurerm_shared_image_version" "elk" {
  count               = (var.baking.enabled && var.baking.use_baked_elk) ? 1 : 0
  name                = "latest"
  image_name          = azurerm_shared_image.elk[0].name
  gallery_name        = azurerm_shared_image_gallery.main[0].name
  resource_group_name = azurerm_resource_group.baking[0].name
}

# ---- RedELK (docker + RedELK repo + pre-pulled images) --------------------

resource "azurerm_shared_image" "redelk" {
  count               = var.baking.enabled ? 1 : 0
  name                = "redelk"
  gallery_name        = azurerm_shared_image_gallery.main[0].name
  resource_group_name = azurerm_resource_group.baking[0].name
  location            = var.azure_region
  os_type             = "Linux"
  hyper_v_generation  = "V2"
  specialized         = false

  identifier {
    publisher = "terra-range"
    offer     = "redelk"
    sku       = "debian-12-docker"
  }

  lifecycle { prevent_destroy = true }
}

data "azurerm_shared_image_version" "redelk" {
  count               = (var.baking.enabled && var.baking.use_baked_redelk) ? 1 : 0
  name                = "latest"
  image_name          = azurerm_shared_image.redelk[0].name
  gallery_name        = azurerm_shared_image_gallery.main[0].name
  resource_group_name = azurerm_resource_group.baking[0].name
}

# ---- Guacamole (Ubuntu 22.04 + docker + pre-pulled guac images + nginx) ----

resource "azurerm_shared_image" "guacamole" {
  count               = var.baking.enabled ? 1 : 0
  name                = "guacamole"
  gallery_name        = azurerm_shared_image_gallery.main[0].name
  resource_group_name = azurerm_resource_group.baking[0].name
  location            = var.azure_region
  os_type             = "Linux"
  hyper_v_generation  = "V2"
  specialized         = false

  identifier {
    publisher = "terra-range"
    offer     = "guacamole"
    sku       = "ubuntu-22-docker"
  }

  lifecycle { prevent_destroy = true }
}

data "azurerm_shared_image_version" "guacamole" {
  count               = (var.baking.enabled && var.baking.use_baked_guacamole) ? 1 : 0
  name                = "latest"
  image_name          = azurerm_shared_image.guacamole[0].name
  gallery_name        = azurerm_shared_image_gallery.main[0].name
  resource_group_name = azurerm_resource_group.baking[0].name
}

# ---- Debian redirector (nginx + base packages) ----------------------------

resource "azurerm_shared_image" "debian_redirector" {
  count               = var.baking.enabled ? 1 : 0
  name                = "debian-redirector"
  gallery_name        = azurerm_shared_image_gallery.main[0].name
  resource_group_name = azurerm_resource_group.baking[0].name
  location            = var.azure_region
  os_type             = "Linux"
  hyper_v_generation  = "V2"
  specialized         = false

  identifier {
    publisher = "terra-range"
    offer     = "debian-redirector"
    sku       = "debian-12-nginx"
  }

  lifecycle { prevent_destroy = true }
}

data "azurerm_shared_image_version" "debian_redirector" {
  count               = (var.baking.enabled && var.baking.use_baked_debian_redirector) ? 1 : 0
  name                = "latest"
  image_name          = azurerm_shared_image.debian_redirector[0].name
  gallery_name        = azurerm_shared_image_gallery.main[0].name
  resource_group_name = azurerm_resource_group.baking[0].name
}

# ---- AdaptixC2 teamserver (Debian 12 + Go + AdaptixC2 pre-compiled) -------

resource "azurerm_shared_image" "adaptix" {
  count               = var.baking.enabled ? 1 : 0
  name                = "adaptix"
  gallery_name        = azurerm_shared_image_gallery.main[0].name
  resource_group_name = azurerm_resource_group.baking[0].name
  location            = var.azure_region
  os_type             = "Linux"
  hyper_v_generation  = "V2"
  specialized         = false

  identifier {
    publisher = "terra-range"
    offer     = "adaptix"
    sku       = "debian-12-go"
  }

  lifecycle { prevent_destroy = true }
}

data "azurerm_shared_image_version" "adaptix" {
  count               = (var.baking.enabled && var.baking.use_baked_adaptix) ? 1 : 0
  name                = "latest"
  image_name          = azurerm_shared_image.adaptix[0].name
  gallery_name        = azurerm_shared_image_gallery.main[0].name
  resource_group_name = azurerm_resource_group.baking[0].name
}

# ---- Mythic teamserver (Debian 12 + Docker + Mythic + mythic-cli) ---------

resource "azurerm_shared_image" "mythic" {
  count               = var.baking.enabled ? 1 : 0
  name                = "mythic"
  gallery_name        = azurerm_shared_image_gallery.main[0].name
  resource_group_name = azurerm_resource_group.baking[0].name
  location            = var.azure_region
  os_type             = "Linux"
  hyper_v_generation  = "V2"
  specialized         = false

  identifier {
    publisher = "terra-range"
    offer     = "mythic"
    sku       = "debian-12-docker-go"
  }

  lifecycle { prevent_destroy = true }
}

data "azurerm_shared_image_version" "mythic" {
  count               = (var.baking.enabled && var.baking.use_baked_mythic) ? 1 : 0
  name                = "latest"
  image_name          = azurerm_shared_image.mythic[0].name
  gallery_name        = azurerm_shared_image_gallery.main[0].name
  resource_group_name = azurerm_resource_group.baking[0].name
}

# ---- Sliver teamserver (Debian 12 + sliver-server binary pre-staged) -----

resource "azurerm_shared_image" "sliver" {
  count               = var.baking.enabled ? 1 : 0
  name                = "sliver"
  gallery_name        = azurerm_shared_image_gallery.main[0].name
  resource_group_name = azurerm_resource_group.baking[0].name
  location            = var.azure_region
  os_type             = "Linux"
  hyper_v_generation  = "V2"
  specialized         = false

  identifier {
    publisher = "terra-range"
    offer     = "sliver"
    sku       = "debian-12-sliver"
  }

  lifecycle { prevent_destroy = true }
}

data "azurerm_shared_image_version" "sliver" {
  count               = (var.baking.enabled && var.baking.use_baked_sliver) ? 1 : 0
  name                = "latest"
  image_name          = azurerm_shared_image.sliver[0].name
  gallery_name        = azurerm_shared_image_gallery.main[0].name
  resource_group_name = azurerm_resource_group.baking[0].name
}

# ---- Ghostwriter reporting platform (Debian 12 + Docker + docker-compose + Ghostwriter repo + ghostwriter-cli compiled + production images pre-built) -----

resource "azurerm_shared_image" "ghostwriter" {
  count               = var.baking.enabled ? 1 : 0
  name                = "ghostwriter"
  gallery_name        = azurerm_shared_image_gallery.main[0].name
  resource_group_name = azurerm_resource_group.baking[0].name
  location            = var.azure_region
  os_type             = "Linux"
  hyper_v_generation  = "V2"
  specialized         = false

  identifier {
    publisher = "terra-range"
    offer     = "ghostwriter"
    sku       = "debian-12-docker-ghostwriter"
  }

  lifecycle { prevent_destroy = true }
}

data "azurerm_shared_image_version" "ghostwriter" {
  count               = (var.baking.enabled && var.baking.use_baked_ghostwriter) ? 1 : 0
  name                = "latest"
  image_name          = azurerm_shared_image.ghostwriter[0].name
  gallery_name        = azurerm_shared_image_gallery.main[0].name
  resource_group_name = azurerm_resource_group.baking[0].name
}

# ---- Stepping Stones activity logger (Debian 12 + Docker + Stepping-Stones repo + images pre-pulled) -----

resource "azurerm_shared_image" "stepping_stones" {
  count               = var.baking.enabled ? 1 : 0
  name                = "stepping-stones"
  gallery_name        = azurerm_shared_image_gallery.main[0].name
  resource_group_name = azurerm_resource_group.baking[0].name
  location            = var.azure_region
  os_type             = "Linux"
  hyper_v_generation  = "V2"
  specialized         = false

  identifier {
    publisher = "terra-range"
    offer     = "stepping-stones"
    sku       = "debian-12-docker-stepping-stones"
  }

  lifecycle { prevent_destroy = true }
}

data "azurerm_shared_image_version" "stepping_stones" {
  count               = (var.baking.enabled && var.baking.use_baked_stepping_stones) ? 1 : 0
  name                = "latest"
  image_name          = azurerm_shared_image.stepping_stones[0].name
  gallery_name        = azurerm_shared_image_gallery.main[0].name
  resource_group_name = azurerm_resource_group.baking[0].name
}
