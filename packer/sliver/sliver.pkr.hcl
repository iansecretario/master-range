################################################################################
# Packer template: Sliver C2 teamserver pre-baked on Debian 12.
#
# Bakes in:
#   - Base packages (curl, openssl, sshd, jq, ca-certificates)
#   - sliver-server binary downloaded from the latest GitHub release
#     and placed at /root/sliver-server, chmod +x. Saves the ~50 MB
#     download + the GitHub API lookup on every deploy.
#   - filebeat .deb pre-installed
#   - Marker /root/.sliver-baked so deploy-time userdata can detect
#     the baked image and skip the binary download.
#
# What stays at deploy time:
#   - systemd unit for sliver-server daemon
#   - operator.cfg generation (sliver-server operator)
#   - Listener registration via `sliver-server console` (per-deploy
#     callback addresses, per-CDN profiles)
#
# Time saved per deploy: ~2-3 min (small compared to adaptix/mythic
# because Sliver ships a pre-built binary — no compile step).
#
# Usage:
#   ./range bake sliver       # one-time, ~15-20 min
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
  default = "sliver"
}
variable "image_version" {
  type    = string
  default = "1.0.0"
}
variable "vm_size" {
  type    = string
  default = "Standard_B2s"
}

source "azure-arm" "sliver" {
  use_azure_cli_auth = true
  subscription_id    = var.azure_subscription_id

  image_publisher = "Debian"
  image_offer     = "debian-12"
  image_sku       = "12-gen2"
  image_version   = "latest"

  os_type         = "Linux"
  vm_size         = var.vm_size
  location        = var.azure_region
  os_disk_size_gb = 30

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
  sources = ["source.azure-arm.sliver"]

  provisioner "shell" {
    execute_command = "chmod +x {{ .Path }}; {{ .Vars }} sudo -E sh '{{ .Path }}'"
    script          = "${path.root}/scripts/sliver-baseline.sh"
    timeout         = "20m"
  }

  provisioner "shell" {
    execute_command = "chmod +x {{ .Path }}; {{ .Vars }} sudo -E sh '{{ .Path }}'"
    script          = "${path.root}/../_shared/scripts/linux-deprovision.sh"
  }
}
