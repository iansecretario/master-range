################################################################################
# Packer template: Stepping-Stones (operator log collator) pre-baked on
# Debian 12 for the terra-range "stepping-stones" role. GCP equivalent of
# stepping-stones.pkr.hcl — same scripts/stepping-stones-baseline.sh +
# shared linux-deprovision.sh; `googlecompute` source replaces `azure-arm`.
#
# Usage:
#   packer init  packer/stepping-stones/stepping-stones.gcp.pkr.hcl
#   packer build -var gcp_project_id=$TERRARANGE_GCP_HOST_PROJECT_ID \
#                packer/stepping-stones/stepping-stones.gcp.pkr.hcl
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
  default = "n2-standard-2"
}
variable "image_family" {
  type    = string
  default = "stepping-stones"
}
variable "image_version" {
  type    = string
  default = ""
}
variable "os_disk_size_gb" {
  type    = number
  default = 64
}

locals {
  image_name_suffix = var.image_version != "" ? var.image_version : formatdate("YYYYMMDD-hhmmss", timestamp())
}

source "googlecompute" "stepping-stones" {
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
    image   = "stepping-stones"
  }
}

build {
  sources = ["source.googlecompute.stepping-stones"]

  # Step 1: install Stepping-Stones (python, deps, web frontend).
  provisioner "shell" {
    execute_command = "chmod +x {{ .Path }}; {{ .Vars }} sudo -E sh '{{ .Path }}'"
    script          = "${path.root}/scripts/stepping-stones-baseline.sh"
    timeout         = "30m"
  }

  # Step 2: deprovision.
  provisioner "shell" {
    execute_command = "chmod +x {{ .Path }}; {{ .Vars }} sudo -E sh '{{ .Path }}'"
    script          = "${path.root}/../_shared/scripts/linux-deprovision.sh"
  }
}
