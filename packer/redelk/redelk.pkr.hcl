################################################################################
# Packer template: RedELK pre-baked on Debian 12 for the terra-range
# "redelk" role (red-team-focused ELK distribution from Outflank).
#
# Bakes in:
#   - Docker + docker compose plugin
#   - RedELK repo cloned at /opt/redelk (the install path the userdata
#     expects)
#   - Docker images pre-pulled (elasticsearch, kibana, logstash,
#     nginx, jupyter — the docker-compose stack contents) so first
#     boot doesn't have to fetch ~3 GB of images.
#   - Base packages (curl, jq, git, openssl)
#
# What stays at deploy time:
#   - .env file generation (passwords, cluster name, beat-input certs)
#   - install-elkserver.sh wrapper run (it self-detects already-fetched
#     resources and does the per-deploy config + docker-compose up)
#
# Time saved per deploy: ~8-12 min on the RedELK box (docker pulls +
# git clone + apt are the slow parts; pre-baking them shifts the cost
# to image-time and the deploy just runs the config wrapper).
#
# Usage:
#   ./range bake redelk     # one-time, ~30-40 min (docker pulls)
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
  default = "redelk"
}
variable "image_version" {
  type    = string
  default = "1.0.0"
}
variable "vm_size" {
  type    = string
  default = "Standard_D4s_v5"
}

source "azure-arm" "redelk" {
  use_azure_cli_auth = true
  subscription_id    = var.azure_subscription_id

  image_publisher = "Debian"
  image_offer     = "debian-12"
  image_sku       = "12-gen2"
  image_version   = "latest"

  os_type         = "Linux"
  vm_size         = var.vm_size
  location        = var.azure_region
  # 64 GB: docker images + RedELK clone + apt fit comfortably.
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
  sources = ["source.azure-arm.redelk"]

  # Step 1: install docker + git + pre-fetch RedELK repo + docker images.
  provisioner "shell" {
    execute_command = "chmod +x {{ .Path }}; {{ .Vars }} sudo -E sh '{{ .Path }}'"
    script          = "${path.root}/scripts/redelk-baseline.sh"
    timeout         = "40m"
  }

  # Step 2: deprovision.
  provisioner "shell" {
    execute_command = "chmod +x {{ .Path }}; {{ .Vars }} sudo -E sh '{{ .Path }}'"
    script          = "${path.root}/../_shared/scripts/linux-deprovision.sh"
  }
}
