################################################################################
# Packer template: Mythic teamserver pre-baked on Debian 12.
#
# Bakes in:
#   - Docker + docker compose plugin (via get.docker.com — same path
#     as the deploy userdata uses)
#   - Go 1.22.7 under /usr/local/go (mythic-cli's `make` target needs
#     it; Debian's apt golang is too old)
#   - Mythic source cloned at /opt/mythic
#   - `make mythic-cli` already run — /opt/mythic/mythic-cli in place
#   - Mythic's full docker image stack pre-pulled (postgres,
#     mythic_server, mythic_react, mythic_documentation, mythic_nginx,
#     mythic_rabbitmq, mythic_graphql + each installed C2 profile /
#     agent image enumerated from /opt/mythic/InstalledServices/)
#   - filebeat .deb pre-installed (saves ~30 sec apt + ~30 sec download)
#   - Marker file /opt/mythic/.baked so deploy userdata can detect a
#     baked image and skip the slow install phase
#
# What stays at deploy time:
#   - .env render (per-deploy Hasura secret, postgres password)
#   - mythic-cli config (operator account, listener registration)
#   - `docker compose up -d` start
#   - httpx C2 profile config drop (per-deploy callback host)
#
# Time saved per deploy: ~10-15 min (Docker install ~1-2 min + Go
# install ~1 min + git clone ~30s + mythic-cli build ~3-5 min + docker
# pulls ~3-5 min).
#
# Usage:
#   ./range bake mythic       # one-time, ~30-40 min
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
  default = "mythic"
}
variable "image_version" {
  type    = string
  default = "1.0.0"
}
variable "vm_size" {
  type    = string
  default = "Standard_D4s_v5"
}

source "azure-arm" "mythic" {
  use_azure_cli_auth = true
  subscription_id    = var.azure_subscription_id

  image_publisher = "Debian"
  image_offer     = "debian-12"
  image_sku       = "12-gen2"
  image_version   = "latest"

  os_type         = "Linux"
  vm_size         = var.vm_size
  location        = var.azure_region
  # 128 GB: docker images for Mythic stack are ~5-8 GB; add Go
  # toolchain + Mythic source + headroom for image pulls.
  os_disk_size_gb = 128

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
  sources = ["source.azure-arm.mythic"]

  provisioner "shell" {
    execute_command = "chmod +x {{ .Path }}; {{ .Vars }} sudo -E sh '{{ .Path }}'"
    script          = "${path.root}/scripts/mythic-baseline.sh"
    timeout         = "40m"
  }

  provisioner "shell" {
    execute_command = "chmod +x {{ .Path }}; {{ .Vars }} sudo -E sh '{{ .Path }}'"
    script          = "${path.root}/../_shared/scripts/linux-deprovision.sh"
  }
}
