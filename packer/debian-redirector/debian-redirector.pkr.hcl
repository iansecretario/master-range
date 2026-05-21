################################################################################
# Packer template: Debian 12 pre-baked for terra-range c2-redirector role.
#
# Bakes in:
#   - apt index updated + base packages (nginx, ca-certificates, curl,
#     jq, openssl, python3 — everything the redirector role's nginx
#     conf-render needs)
#   - nginx installed but NOT started/configured (deploy-time tasks
#     drop the per-stack conf into /etc/nginx/conf.d/ and reload)
#   - logrotate baseline for nginx access/error logs
#   - cloud-init-native deprovision (re-runs fresh on every deployed VM)
#
# What stays at deploy time:
#   - per-redirector cert (LE or self-signed from terraform)
#   - per-stack upstream config (adaptix / mythic / sliver / brc4)
#   - operator SSH key install via cloud-init users:
#
# Time saved per deploy: ~3-5 min per redirector. Multiplied across
# 3-4 redirectors per range (per student in shared mode), this is a
# real chunk: a 10-student cohort with 3 redirectors each = 30
# redirectors × 4 min ≈ 2 hours saved in parallel wall-clock time
# (which translates to maybe 10-15 min faster Phase 2 since Azure
# parallelizes — but it removes one MORE box from "slowest first-boot
# wins" Phase 2 bound).
#
# Usage:
#   ./range bake debian-redirector       # one-time, ~15-20 min
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
  default = "debian-redirector"
}
variable "image_version" {
  type    = string
  default = "1.0.0"
}
variable "vm_size" {
  type    = string
  default = "Standard_B2s"
}

source "azure-arm" "debian_redirector" {
  use_azure_cli_auth = true
  subscription_id    = var.azure_subscription_id

  # Mirror modules/azure/images.tf "debian-12".
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
  sources = ["source.azure-arm.debian_redirector"]

  # Step 1: install nginx + base packages.
  provisioner "shell" {
    execute_command = "chmod +x {{ .Path }}; {{ .Vars }} sudo -E sh '{{ .Path }}'"
    script          = "${path.root}/scripts/debian-redirector-baseline.sh"
    timeout         = "20m"
  }

  # Step 2: deprovision (cloud-init clean, host keys, logs).
  provisioner "shell" {
    execute_command = "chmod +x {{ .Path }}; {{ .Vars }} sudo -E sh '{{ .Path }}'"
    script          = "${path.root}/../_shared/scripts/linux-deprovision.sh"
  }
}
