################################################################################
# Packer template: AdaptixC2 teamserver pre-baked on Debian 12.
#
# Bakes in:
#   - Build toolchain (cmake, build-essential, the AdaptixClient Qt6 deps
#     that the Adaptix make target chains through)
#   - Go 1.25.4 under /usr/local/go (AdaptixC2's `make` target requires
#     Go 1.21+)
#   - AdaptixC2 source cloned at /opt/adaptix/AdaptixC2
#   - `make` already run — server binary + extender plugins all built
#   - Marker file /opt/adaptix/.baked so deploy-time userdata can
#     detect a baked image and skip the apt/go/git/make path
#
# What stays at deploy time:
#   - profile.yaml render (per-deploy random teamserver password,
#     operator account creation)
#   - systemd unit drop + start
#   - Listener registration (per-CDN + per-student callback addresses)
#   - Filebeat shipping config (ELK endpoint)
#
# Time saved per deploy: ~10-15 min (apt + ~150 MB Go tarball + git
# clone + ~5-10 min `make` compile = the bulk of c2-server.sh runtime).
#
# Usage:
#   ./range bake adaptix       # one-time, ~25-30 min
################################################################################

packer {
  required_plugins {
    azure = {
      source  = "github.com/hashicorp/azure"
      version = "~> 2.0"
    }
  }
}

variable "azure_subscription_id" { type = string }
variable "sig_resource_group"    { type = string }
variable "sig_name"              { type = string }
variable "azure_region" {
  type    = string
  default = "southeastasia"
}
variable "image_definition" {
  type    = string
  default = "adaptix"
}
variable "image_version" {
  type    = string
  default = "1.0.0"
}
variable "vm_size" {
  # Compile is CPU-bound; 4 vCPU keeps the bake under 30 min.
  type    = string
  default = "Standard_D4s_v5"
}

source "azure-arm" "adaptix" {
  use_azure_cli_auth = true
  subscription_id    = var.azure_subscription_id

  image_publisher = "Debian"
  image_offer     = "debian-12"
  image_sku       = "12-gen2"
  image_version   = "latest"

  os_type         = "Linux"
  vm_size         = var.vm_size
  location        = var.azure_region
  # 64 GB: Go toolchain + AdaptixC2 build artefacts fit comfortably.
  os_disk_size_gb = 64

  communicator = "ssh"
  ssh_username = "packer"
  ssh_timeout  = "20m"

  shared_image_gallery_destination {
    subscription         = var.azure_subscription_id
    resource_group       = var.sig_resource_group
    gallery_name         = var.sig_name
    image_name           = var.image_definition
    image_version        = var.image_version
    replication_regions  = [var.azure_region]
    storage_account_type = "Standard_LRS"
  }

  managed_image_name                = "${var.image_definition}-${var.image_version}-tmp"
  managed_image_resource_group_name = var.sig_resource_group
}

build {
  sources = ["source.azure-arm.adaptix"]

  provisioner "shell" {
    execute_command = "chmod +x {{ .Path }}; {{ .Vars }} sudo -E sh '{{ .Path }}'"
    script          = "${path.root}/scripts/adaptix-baseline.sh"
    timeout         = "30m"
  }

  provisioner "shell" {
    execute_command = "chmod +x {{ .Path }}; {{ .Vars }} sudo -E sh '{{ .Path }}'"
    script          = "${path.root}/../_shared/scripts/linux-deprovision.sh"
  }
}
