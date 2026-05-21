################################################################################
# Packer template: Kali Linux pre-baked for the terra-range attacker role.
#
# What this image has done for you BEFORE terraform sees it:
#   - kali-linux-default metapackage installed (~2.5 GB of offensive
#     tooling: Burp, Metasploit, nmap, the whole kit). On a raw
#     Marketplace VM this single apt task runs ~15-30 min and is the
#     slowest thing in the entire deploy.
#   - XFCE desktop (kali-desktop-xfce) + dbus-x11
#   - TigerVNC (standalone-server / common / tools) + xrdp
#   - AdaptixClient's full Qt6 build-dependency stack (cmake, qt6-*-dev,
#     libssl-dev, ...) so the per-deploy `make` is the only AdaptixClient
#     cost left — not the apt churn for its ~12 dev packages.
#   - apt cache cleaned + cloud-init/host-key/machine-id reset -> a
#     reusable GENERALIZED image.
#
# What's left to do at deploy time (~2-3 min, vs ~30-45 from raw
# Marketplace) — only the kali ansible role's FAST, deploy-specific
# tasks:
#   - xrdp.ini / sesman.ini patches, autorun=Xvnc
#   - ~/.xsession + screensaver-prevention dotfiles
#   - ~/Desktop/payloads scaffold, C2-client launchers + storage seed
#   - AdaptixClient `make` (deps already present from this bake)
# The role's `apt ... state=present` for kali-linux-default becomes a
# sub-30s idempotent no-op against this image — and there's no longer a
# long async task to wedge on.
#
# Usage:
#   ./range bake kali            # one-time, ~30-40 min, ~$0.20 of compute
#   ./range apply <scenario>     # subsequent applies skip the metapackage
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
# Variables are populated by `./range bake kali` so the operator doesn't
# maintain a second config surface. Keep the SIG name/RG in sync with
# modules/azure/baking.tf (azurerm_shared_image_gallery.main) and the
# image_definition in sync with azurerm_shared_image.kali_redteam.
variable "azure_subscription_id" { type = string }
variable "sig_resource_group"    { type = string }
variable "sig_name"              { type = string }
variable "azure_region" {
  type    = string
  default = "southeastasia"
}
variable "image_definition" {
  type    = string
  default = "kali-redteam"
}
variable "image_version" {
  type    = string
  default = "1.0.0"
}
variable "vm_size" {
  type    = string
  default = "Standard_D4s_v5"
}

source "azure-arm" "kali" {
  use_azure_cli_auth = true
  subscription_id    = var.azure_subscription_id

  # Base: the same Marketplace SKU as the non-baked path in
  # modules/azure/images.tf (local.image_map["kali"]).
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
  # 64 GB build disk: kali-linux-default + the Qt6 dev stack land around
  # ~20 GB; this leaves headroom for the apt unpack. Deployed VMs expand
  # this to their role-aware size (attacker = 128 GB, see vms.tf).
  os_disk_size_gb = 64

  # Linux build VM — Packer connects over SSH; azure-arm provisions the
  # temporary build user itself.
  communicator = "ssh"
  ssh_username = "packer"
  ssh_timeout  = "20m"

  # Publish straight into the Shared Image Gallery so terraform can
  # reference it by source_image_id (see images.tf local.baked_kali_id).
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
  sources = ["source.azure-arm.kali"]

  # Step 0: upload the CWR wallpaper PNG to a known path. The baseline
  # script below moves it to /usr/share/backgrounds/cwr-wallpaper.png +
  # references it from system-wide xfce4-desktop.xml + lightdm-greeter
  # configs. Uploaded as the SSH user (packer); baseline runs as sudo
  # and `mv`s into place with proper ownership.
  provisioner "file" {
    source      = "${path.root}/../_shared/files/desktop-wallpaper-CWR.png"
    destination = "/tmp/cwr-wallpaper.png"
  }

  # Step 1: the heavy lifting — kali-linux-default + desktop + VNC/xrdp
  # + AdaptixClient build deps. This is the ~15-30 min the operator pays
  # ONCE per quarterly rebake instead of on every single deploy. Also
  # bakes in: system-wide wallpaper, lightdm autologin for ranger,
  # XFCE screensaver/lock OFF.
  provisioner "shell" {
    execute_command = "chmod +x {{ .Path }}; {{ .Vars }} sudo -E sh '{{ .Path }}'"
    script          = "${path.root}/scripts/kali-baseline.sh"
    # kali-linux-default unpack on a fresh VM can run long; give it room.
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
  # does not exist (the build used to die here, exit 127). The script
  # does the cloud-init-native equivalent, which is the correct
  # generalize path for this image anyway.
  provisioner "shell" {
    execute_command = "chmod +x {{ .Path }}; {{ .Vars }} sudo -E sh '{{ .Path }}'"
    script          = "${path.root}/scripts/kali-deprovision.sh"
  }
}
