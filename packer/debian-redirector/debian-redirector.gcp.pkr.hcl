################################################################################
# Packer template: Debian 12 pre-baked for terra-range c2-redirector role.
# GCP equivalent of debian-redirector.pkr.hcl — same
# scripts/debian-redirector-baseline.sh + shared linux-deprovision.sh;
# `googlecompute` source replaces `azure-arm`.
#
# Usage:
#   packer init  packer/debian-redirector/debian-redirector.gcp.pkr.hcl
#   packer build -var gcp_project_id=$TERRARANGE_GCP_HOST_PROJECT_ID \
#                packer/debian-redirector/debian-redirector.gcp.pkr.hcl
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
  # Redirector is a light box — n2-standard-2 is the analog of Standard_B2s.
  type    = string
  default = "n2-standard-2"
}
variable "image_family" {
  type    = string
  default = "debian-redirector"
}
variable "image_version" {
  type    = string
  default = ""
}
variable "os_disk_size_gb" {
  # 32 GB is comfortable for nginx + base packages.
  type    = number
  default = 32
}

locals {
  image_name_suffix = var.image_version != "" ? var.image_version : formatdate("YYYYMMDD-hhmmss", timestamp())
}

source "googlecompute" "debian_redirector" {
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
    image   = "debian-redirector"
  }
}

build {
  sources = ["source.googlecompute.debian_redirector"]

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
