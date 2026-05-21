################################################################################
# Packer template: Ghostwriter reporting platform pre-baked on Debian 12 for
# the terra-range "ghostwriter" role. GCP equivalent of ghostwriter.pkr.hcl —
# same scripts/ghostwriter-baseline.sh + shared linux-deprovision.sh;
# `googlecompute` source replaces `azure-arm`.
#
# Disk: 128 GB — Ghostwriter ships as a Docker-compose stack (nginx, django,
# postgres, redis, graphql, ...); pre-pulling the image set + dependencies
# saves substantial first-boot time.
#
# Usage:
#   packer init  packer/ghostwriter/ghostwriter.gcp.pkr.hcl
#   packer build -var gcp_project_id=$TERRARANGE_GCP_HOST_PROJECT_ID \
#                packer/ghostwriter/ghostwriter.gcp.pkr.hcl
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
  default = "ghostwriter"
}
variable "image_version" {
  type    = string
  default = ""
}
variable "os_disk_size_gb" {
  # 128 GB — Ghostwriter pulls a multi-service Docker stack + has document
  # generation deps (pandoc, libreoffice, ...).
  type    = number
  default = 128
}

locals {
  image_name_suffix = var.image_version != "" ? var.image_version : formatdate("YYYYMMDD-hhmmss", timestamp())
}

source "googlecompute" "ghostwriter" {
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
    image   = "ghostwriter"
  }
}

build {
  sources = ["source.googlecompute.ghostwriter"]

  # Step 1: install Docker + clone Ghostwriter + pre-pull container images.
  provisioner "shell" {
    execute_command = "chmod +x {{ .Path }}; {{ .Vars }} sudo -E sh '{{ .Path }}'"
    script          = "${path.root}/scripts/ghostwriter-baseline.sh"
    timeout         = "60m"
  }

  # Step 2: deprovision.
  provisioner "shell" {
    execute_command = "chmod +x {{ .Path }}; {{ .Vars }} sudo -E sh '{{ .Path }}'"
    script          = "${path.root}/../_shared/scripts/linux-deprovision.sh"
  }
}
