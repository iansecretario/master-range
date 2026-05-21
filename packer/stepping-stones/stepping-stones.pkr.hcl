################################################################################
# Packer template: Stepping Stones (Cyberveiligheid) pre-baked on Debian 12.
#
# Upstream: https://github.com/stepping-stones-cyberveiligheid/Stepping-Stones
# A Django-based red-team activity logger that ships as a docker-compose
# stack (web + postgres + a couple of helper services).
#
# Bakes in:
#   - Docker engine + docker compose plugin (apt — no extra repo needed)
#   - nginx + certbot + curl + git + jq (so the deploy-time role can
#     drop a reverse-proxy config / fetch a TLS cert without an apt
#     round-trip)
#   - Stepping-Stones source cloned at /opt/stepping-stones
#   - Every container image referenced by the upstream docker-compose.yml
#     pre-pulled (postgres, redis, the web app's base image, etc.)
#   - Any locally-built compose services pre-built (`docker compose build`)
#   - Marker file /opt/stepping-stones/.baked so the deploy-time Ansible
#     role can detect a baked image and skip Docker install / clone /
#     image pull.
#
# What stays at deploy time:
#   - .env render (per-deploy Django SECRET_KEY, Postgres password,
#     ALLOWED_HOSTS pinned to this VM's private IP)
#   - `docker compose up -d` start
#   - manage.py migrate + createsuperuser (per-deploy admin password
#     from `stepping_stones_admin_password`)
#   - Systemd unit for auto-restart on reboot
#
# Time saved per deploy: ~5-8 min (Docker install ~1-2 min + git clone
# ~10 s + image pulls ~3-5 min depending on egress).
#
# Usage:
#   ./range bake stepping-stones        # one-time, ~15-25 min
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
variable "sig_resource_group" { type = string }
variable "sig_name" { type = string }
variable "azure_region" {
  type    = string
  default = "southeastasia"
}
variable "image_definition" {
  type    = string
  default = "stepping-stones"
}
variable "image_version" {
  type    = string
  default = "1.0.0"
}
variable "vm_size" {
  # Stepping-Stones is a small Django+Postgres stack; 4 vCPU is plenty
  # for the bake phase (the slow steps are apt + image pulls, both
  # network-bound). The deployed VM uses its own sizing per scenario.
  type    = string
  default = "Standard_D4s_v5"
}

source "azure-arm" "stepping_stones" {
  use_azure_cli_auth = true
  subscription_id    = var.azure_subscription_id

  image_publisher = "Debian"
  image_offer     = "debian-12"
  image_sku       = "12-gen2"
  image_version   = "latest"

  os_type  = "Linux"
  vm_size  = var.vm_size
  location = var.azure_region
  # 64 GB: docker images for a Django + postgres stack are < 2 GB; the
  # extra headroom is for apt unpack + the cloned source + room to grow
  # if the upstream stack adds heavier services. Matches the ELK bake
  # disk size — cheap and avoids "no space left on device" surprises.
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
  sources = ["source.azure-arm.stepping_stones"]

  # Step 1: install Docker + clone repo + pre-pull every compose image.
  provisioner "shell" {
    execute_command = "chmod +x {{ .Path }}; {{ .Vars }} sudo -E sh '{{ .Path }}'"
    script          = "${path.root}/scripts/stepping-stones-baseline.sh"
    timeout         = "30m"
  }

  # Step 2: generic Debian deprovision (cloud-init reset, host-key
  # wipe, defer packer-user removal). Same shared script every Linux
  # bake uses.
  provisioner "shell" {
    execute_command = "chmod +x {{ .Path }}; {{ .Vars }} sudo -E sh '{{ .Path }}'"
    script          = "${path.root}/../_shared/scripts/linux-deprovision.sh"
  }
}
