################################################################################
# Packer template: Guacamole pre-baked on Ubuntu 22.04 for terra-range.
#
# Bakes in:
#   - Docker + docker compose plugin (saves ~1-2 min apt + ~30 sec config)
#   - Pre-pulled docker images: guacamole/guacd, guacamole/guacamole,
#     postgres:14, nginx:alpine (or whatever the docker-compose.yml
#     references). Saves ~2-4 min of image-pull on first boot.
#   - nginx + certbot + python3-certbot-* + python3-certbot-dns-azure
#     so LE acquisition is just `certbot certonly --webroot ...` —
#     no apt install during the first-boot LE bootstrap.
#   - Java prereqs (Guacamole's client/connection ProxyEvent uses some
#     reflection that pulls in JDK runtime — keeps `apt install
#     openjdk-17-jre-headless` out of the first-boot path).
#
# What stays at deploy time:
#   - manifest.json + register.py invocation (per-deploy connection set)
#   - LE cert acquisition (per-deploy hostname; the cert itself can't
#     be baked in because the hostname is per-deploy)
#   - nginx vhost config (per-deploy hostname)
#   - cwr-branding.jar generation (per-deploy login_title)
#
# Time saved per deploy: ~5-8 min (docker install + nginx install +
# image pulls). On the SHARED Guac (envs/shared-guac-azure/) this drops
# the spin-up from ~10-12 min to ~3-5 min.
#
# Usage:
#   ./range bake guacamole       # one-time, ~20-25 min
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
  default = "guacamole"
}
variable "image_version" {
  type    = string
  default = "1.0.0"
}
variable "vm_size" {
  type    = string
  default = "Standard_B4ms"
}

source "azure-arm" "guacamole" {
  use_azure_cli_auth = true
  subscription_id    = var.azure_subscription_id

  # Ubuntu 22.04 matches the per-range Guac VM (services.tf:443) and
  # the shared-guac module (modules/shared-guac/main.tf).
  image_publisher = "Canonical"
  image_offer     = "0001-com-ubuntu-server-jammy"
  image_sku       = "22_04-lts-gen2"
  image_version   = "latest"

  os_type         = "Linux"
  vm_size         = var.vm_size
  location        = var.azure_region
  # 64 GB build disk to fit apt + docker images + a bit of headroom.
  # Deployed VMs use 50-128 GB (per-range vs shared) — disks resize on
  # deploy via vms.tf / shared-guac module.
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
  sources = ["source.azure-arm.guacamole"]

  # Step 1: install docker + nginx + certbot + pre-pull guac images.
  provisioner "shell" {
    execute_command = "chmod +x {{ .Path }}; {{ .Vars }} sudo -E sh '{{ .Path }}'"
    script          = "${path.root}/scripts/guacamole-baseline.sh"
    timeout         = "30m"
  }

  # Step 2: deprovision (cloud-init clean, host keys, logs).
  provisioner "shell" {
    execute_command = "chmod +x {{ .Path }}; {{ .Vars }} sudo -E sh '{{ .Path }}'"
    script          = "${path.root}/../_shared/scripts/linux-deprovision.sh"
  }
}
