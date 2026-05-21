################################################################################
# Packer template: Ghostwriter reporting/oplog server pre-baked on Debian 12.
#
# Ghostwriter (SpecterOps) is a Django + Hasura GraphQL + React + nginx +
# Postgres + Redis stack. Operator-side workflow: clone the repo, run
# `./ghostwriter-cli-linux install`, wait for `docker compose up`,
# browse https://<host>/. For the terra-range oplog pipeline this is
# the central reporting + API endpoint that ingests normalized C2 logs
# from Mythic / Sliver / Adaptix / BRC4.
#
# Bakes in:
#   - Docker + docker compose plugin (via get.docker.com — same path
#     as the deploy userdata uses)
#   - Ghostwriter source cloned at /opt/ghostwriter (depth=1)
#   - Pre-built `ghostwriter-cli-linux` binary (ships in the repo, no
#     Go build needed)
#   - Base FROM images pre-pulled: postgres:16.4, redis:6-alpine,
#     nginx:1.23.3-alpine, node:25.9.0-alpine3.23, python:3.10.20-alpine3.23,
#     hasura/graphql-engine:v2.39.1.cli-migrations-v3
#   - `docker compose build` already run — the seven ghostwriter_production_*
#     images (django, postgres, nginx, redis, graphql, queue, collab-server)
#     are layered into the docker cache
#   - Marker file /opt/ghostwriter/.baked so deploy-time ansible can
#     detect a baked image and skip the slow install phase
#
# What stays at deploy time:
#   - `ghostwriter-cli-linux install` — regenerates .env with per-deploy
#     secrets, runs migrations, brings the stack up
#   - DJANGO_ALLOWED_HOSTS patched to include the actual VM IP
#   - First-login admin password promotion + retrieval via
#     `ghostwriter-cli-linux config get ADMIN_PASSWORD`
#   - GraphQL `login` mutation to mint an API token for the oplog
#     pipeline (saved to /opt/ghostwriter/.api-token for downstream
#     terraform output)
#
# Time saved per deploy: ~12-18 min on the Ghostwriter box
#   (Docker install ~1-2 min + git clone ~30s + base-image pull ~2-3 min
#    + docker compose build ~10-15 min collapsed into a cache hit).
#
# Usage:
#   ./range bake ghostwriter      # one-time, ~30-40 min
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
  default = "ghostwriter"
}
variable "image_version" {
  type    = string
  default = "1.0.0"
}
variable "vm_size" {
  # `docker compose build` for Ghostwriter's django image is CPU-bound
  # (Python build deps + spaCy model download + frontend webpack).
  # 4 vCPU keeps the bake comfortably under 30 min.
  type    = string
  default = "Standard_D4s_v5"
}

source "azure-arm" "ghostwriter" {
  use_azure_cli_auth = true
  subscription_id    = var.azure_subscription_id

  image_publisher = "Debian"
  image_offer     = "debian-12"
  image_sku       = "12-gen2"
  image_version   = "latest"

  os_type  = "Linux"
  vm_size  = var.vm_size
  location = var.azure_region
  # 128 GB: built django + frontend images are heavy (~3 GB each),
  # postgres + nginx + redis + graphql add another ~1-2 GB, plus base
  # FROM image cache (~2 GB), plus the source tree. Mirror the Mythic
  # bake's 128 GB for the same reasons.
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
  sources = ["source.azure-arm.ghostwriter"]

  provisioner "shell" {
    execute_command = "chmod +x {{ .Path }}; {{ .Vars }} sudo -E sh '{{ .Path }}'"
    script          = "${path.root}/scripts/ghostwriter-baseline.sh"
    # `docker compose build` is the dominant cost (~10-15 min);
    # apt + git clone + base pulls add another 5-8 min; 40 min ceiling
    # leaves headroom for slow registry days.
    timeout = "40m"
  }

  provisioner "shell" {
    execute_command = "chmod +x {{ .Path }}; {{ .Vars }} sudo -E sh '{{ .Path }}'"
    script          = "${path.root}/../_shared/scripts/linux-deprovision.sh"
  }
}
