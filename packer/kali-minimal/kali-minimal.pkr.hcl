################################################################################
# Packer template: Kali Linux MINIMAL (offensive-focused) pre-baked for the
# terra-range attacker role.
#
# Same operator workstation as the kali-redteam image — XFCE desktop, xrdp,
# AdaptixClient build deps — but a CURATED, lighter toolset instead of the
# full kali-linux-default kitchen sink.
#
# What this image has done for you BEFORE terraform sees it:
#   - kali-linux-core (the minimal Kali base — note: there is NO
#     "kali-linux-minimal" metapackage; core is the minimal one) + a
#     curated set of kali-tools-* groups focused on offensive security /
#     VAPT / red team:
#       top10, information-gathering, vulnerability, web, exploitation,
#       passwords, post-exploitation, windows-resources, sniffing-spoofing
#     Skips forensics / reverse-engineering / wireless / reporting / the
#     rest of the default kitchen sink — `apt install kali-tools-<grp>`
#     on demand if a given engagement needs them.
#   - XFCE desktop (kali-desktop-xfce) + dbus-x11
#   - TigerVNC (standalone-server / common / tools) + xrdp
#   - AdaptixClient's full Qt6 build-dependency stack (cmake, qt6-*-dev,
#     libssl-dev, ...) so the per-deploy `make` is the only AdaptixClient
#     cost left.
#   - apt cache cleaned + cloud-init/host-key/machine-id reset -> a
#     reusable GENERALIZED image.
#
# Why a separate image: lighter than kali-redteam (fewer tool groups ->
# smaller image, faster bake, comfortable on smaller VMs) while still a
# real, RDP-able operator box. The desktop / xrdp / AdaptixClient layer
# is byte-identical in intent to kali-redteam — only the Kali toolset
# tier differs.
#
# Usage:
#   ./range bake kali-minimal     # one-time, ~20-30 min, ~$0.15 of compute
#   ./range apply <scenario>      # subsequent applies skip the toolset
################################################################################

packer {
  required_plugins {
    azure = {
      source  = "github.com/hashicorp/azure"
      version = "~> 2.0"
    }
  }
}

# ---- Where the operator authenticates + where the SIG lives ---------------
# Variables are populated by `./range bake kali-minimal` so the operator
# doesn't maintain a second config surface. Keep the SIG name/RG in sync
# with modules/azure/baking.tf (azurerm_shared_image_gallery.main) and
# the image_definition in sync with azurerm_shared_image.kali_minimal.
variable "azure_subscription_id" { type = string }
variable "sig_resource_group"    { type = string }
variable "sig_name"              { type = string }
variable "azure_region" {
  type    = string
  default = "southeastasia"
}
variable "image_definition" {
  type    = string
  default = "kali-minimal"
}
variable "image_version" {
  type    = string
  default = "1.0.0"
}
variable "vm_size" {
  type    = string
  default = "Standard_D4s_v5"
}

source "azure-arm" "kali-minimal" {
  use_azure_cli_auth = true
  subscription_id    = var.azure_subscription_id

  # Base: the same Marketplace SKU as the non-baked path in
  # modules/azure/images.tf (local.image_map["kali"]). kali-minimal is
  # still built FROM the Kali Marketplace base — only the installed
  # toolset is trimmed.
  image_publisher = "kali-linux"
  image_offer     = "kali"
  image_sku       = "kali-2026-1"
  image_version   = "latest"

  # Kali's Marketplace offer is a third-party plan-required image. The
  # plan must be declared in THREE places, all kept in sync:
  #   1. here  (plan_info)                  — so Packer can boot the base
  #   2. baking.tf azurerm_shared_image     — purchase_plan {}
  #   3. vms.tf azurerm_linux_virtual_machine — plan {} (os == "kali")
  # Azure rejects the VM/image create if any is missing or mismatched.
  plan_info {
    plan_name      = "kali-2026-1"
    plan_product   = "kali"
    plan_publisher = "kali-linux"
  }

  os_type         = "Linux"
  vm_size         = var.vm_size
  location        = var.azure_region
  # 64 GB build disk: the curated toolset + desktop + Qt6 dev stack land
  # well under this; the headroom is for the apt unpack. Deployed VMs
  # expand this to their role-aware size (attacker = 128 GB, see vms.tf).
  os_disk_size_gb = 64

  # Linux build VM — Packer connects over SSH; azure-arm provisions the
  # temporary build user itself.
  communicator = "ssh"
  ssh_username = "packer"
  ssh_timeout  = "20m"

  # Publish straight into the Shared Image Gallery so terraform can
  # reference it by source_image_id.
  shared_image_gallery_destination {
    subscription         = var.azure_subscription_id
    resource_group       = var.sig_resource_group
    gallery_name         = var.sig_name
    image_name           = var.image_definition
    image_version        = var.image_version
    replication_regions  = [var.azure_region]
    storage_account_type = "Standard_LRS"
  }

  # No build_resource_group_name: with `location` set above, Packer
  # creates its OWN ephemeral resource group for the build VM and tears
  # it down when the build finishes. `location` and
  # build_resource_group_name are mutually exclusive — setting both is
  # the "specify either a location ... or an existing
  # build_resource_group_name, but not both" error.
  #
  # The throwaway managed image lands in the SIG's resource group
  # (terra-range-images-rg — it already exists; pointing at a dedicated
  # build RG would mean creating that RG first). It's version-suffixed
  # so re-bakes don't collide on the name. terraform never reads this
  # managed image — it reads the gallery version published by
  # shared_image_gallery_destination above.
  managed_image_name                = "${var.image_definition}-${var.image_version}-tmp"
  managed_image_resource_group_name = var.sig_resource_group
}

build {
  sources = ["source.azure-arm.kali-minimal"]

  # Step 1: the heavy lifting — kali-linux-core + the curated
  # kali-tools-* groups + desktop + VNC/xrdp + AdaptixClient build deps.
  # Lighter than kali-redteam's kali-linux-default, but still the bulk
  # of the bake — paid ONCE per quarterly rebake, not every deploy.
  provisioner "shell" {
    execute_command = "chmod +x {{ .Path }}; {{ .Vars }} sudo -E sh '{{ .Path }}'"
    script          = "${path.root}/scripts/kali-minimal-baseline.sh"
    # The kali-tools-* unpack on a fresh VM can still run long; give it room.
    timeout         = "60m"
  }

  # Step 2: deprovision so the captured image is GENERALIZED — resets
  # cloud-init (so it re-runs fresh on every deployed VM: creates
  # `ranger`, drops the operator key, etc.), strips SSH host keys,
  # machine-id, DHCP leases, logs/history, and schedules removal of the
  # temporary packer build user.
  #
  # NOT `waagent -deprovision`: Kali's Azure Marketplace image is
  # cloud-init-provisioned and ships no WALinuxAgent — /usr/sbin/waagent
  # does not exist. The script does the cloud-init-native equivalent,
  # which is the correct generalize path for this image anyway. (Same
  # script as the kali-redteam bake — copied into this template's
  # scripts/ dir since packer parses each template subdir in isolation.)
  provisioner "shell" {
    execute_command = "chmod +x {{ .Path }}; {{ .Vars }} sudo -E sh '{{ .Path }}'"
    script          = "${path.root}/scripts/kali-deprovision.sh"
  }
}
