################################################################################
# Packer template: Mythic C2 teamserver pre-baked on Debian 12 for the
# terra-range "mythic" role. GCP equivalent of mythic.pkr.hcl — same
# scripts/mythic-baseline.sh + shared linux-deprovision.sh; `googlecompute`
# source replaces `azure-arm`.
#
# Disk: 128 GB — larger than the other Debian images because Mythic pulls
# Docker images for every payload type (apollo, athena, freyja, ...). The
# bake pre-pulls the common set so first-boot doesn't have to.
#
# Usage:
#   packer init  packer/mythic/mythic.gcp.pkr.hcl
#   packer build -var gcp_project_id=$TERRARANGE_GCP_HOST_PROJECT_ID \
#                packer/mythic/mythic.gcp.pkr.hcl
################################################################################

packer {
  required_plugins {
    googlecompute = {
      source  = "github.com/hashicorp/googlecompute"
      version = "~> 1.1"
    }
  }
}

variable "gcp_project_id" {
  type = string
}
variable "gcp_region" {
  type    = string
  default = "asia-southeast1"
}
variable "vm_size" {
  type    = string
  default = "n2-standard-4"
}
variable "image_family" {
  type    = string
  default = "mythic"
}
variable "image_version" {
  type    = string
  default = ""
}
variable "os_disk_size_gb" {
  # 128 GB — Mythic pre-pulls Docker images (apollo/athena/freyja/etc.).
  type    = number
  default = 128
}

locals {
  image_name_suffix = var.image_version != "" ? var.image_version : formatdate("YYYYMMDD-hhmmss", timestamp())
}

source "googlecompute" "mythic" {
  project_id = var.gcp_project_id

  source_image_family     = "debian-12"
  source_image_project_id = ["debian-cloud"]

  zone         = "${var.gcp_region}-b"
  machine_type = var.vm_size
  disk_size    = var.os_disk_size_gb

  image_name        = "${var.image_family}-${local.image_name_suffix}"
  image_family      = var.image_family
  image_description = "terra-range baked ${var.image_family} — built ${formatdate("YYYY-MM-DD", timestamp())}"

  ssh_username = "packer"
  ssh_timeout  = "30m"

  labels = {
    builder = "packer"
    range   = "terra-range-bake"
    image   = "mythic"
  }
}

build {
  sources = ["source.googlecompute.mythic"]

  # Step 1: install Docker + clone Mythic + pre-pull payload-type images.
  provisioner "shell" {
    execute_command = "chmod +x {{ .Path }}; {{ .Vars }} sudo -E sh '{{ .Path }}'"
    script          = "${path.root}/scripts/mythic-baseline.sh"
    timeout         = "60m"
  }

  # Step 2: deprovision.
  provisioner "shell" {
    execute_command = "chmod +x {{ .Path }}; {{ .Vars }} sudo -E sh '{{ .Path }}'"
    script          = "${path.root}/../_shared/scripts/linux-deprovision.sh"
  }
}
