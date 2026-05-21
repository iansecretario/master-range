################################################################################
# Packer template: RedELK (red-team SIEM) pre-baked on Debian 12 for the
# terra-range "redelk" role. GCP equivalent of redelk.pkr.hcl — same
# scripts/redelk-baseline.sh + shared linux-deprovision.sh; `googlecompute`
# source replaces `azure-arm`.
#
# Disk: 200 GB — larger than ELK (64 GB) because RedELK ingests c2 channel
# data + redirector access logs and indices grow quickly even in single-
# range scenarios. The deployed VM inherits the image's disk size.
#
# Usage:
#   packer init  packer/redelk/redelk.gcp.pkr.hcl
#   packer build -var gcp_project_id=$TERRARANGE_GCP_HOST_PROJECT_ID \
#                packer/redelk/redelk.gcp.pkr.hcl
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
  default = "redelk"
}
variable "image_version" {
  type    = string
  default = ""
}
variable "os_disk_size_gb" {
  # 200 GB for Elasticsearch indices headroom — RedELK + ingested c2 logs
  # outgrow the ELK image's 64 GB quickly.
  type    = number
  default = 200
}

locals {
  image_name_suffix = var.image_version != "" ? var.image_version : formatdate("YYYYMMDD-hhmmss", timestamp())
}

source "googlecompute" "redelk" {
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
    image   = "redelk"
  }
}

build {
  sources = ["source.googlecompute.redelk"]

  # Step 1: install RedELK (Elastic + parsers + dashboards + agents).
  provisioner "shell" {
    execute_command = "chmod +x {{ .Path }}; {{ .Vars }} sudo -E sh '{{ .Path }}'"
    script          = "${path.root}/scripts/redelk-baseline.sh"
    timeout         = "45m"
  }

  # Step 2: deprovision.
  provisioner "shell" {
    execute_command = "chmod +x {{ .Path }}; {{ .Vars }} sudo -E sh '{{ .Path }}'"
    script          = "${path.root}/../_shared/scripts/linux-deprovision.sh"
  }
}
