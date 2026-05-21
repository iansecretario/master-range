################################################################################
# Packer template: ELK stack (Elastic + Kibana + Logstash) pre-baked on
# Debian 12 for the terra-range "elk" role. GCP equivalent of elk.pkr.hcl —
# same scripts/elk-baseline.sh + shared linux-deprovision.sh; `googlecompute`
# source replaces `azure-arm`.
#
# Auth: `gcloud auth application-default login` once before bake. See
# elk.pkr.hcl for the install / time-saved narrative.
#
# Usage:
#   packer init  packer/elk/elk.gcp.pkr.hcl
#   packer build -var gcp_project_id=$TERRARANGE_GCP_HOST_PROJECT_ID \
#                packer/elk/elk.gcp.pkr.hcl
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
  # n2-standard-4 = 4 vCPU, 16 GB RAM — comfortable for ELK install + JVM.
  type    = string
  default = "n2-standard-4"
}
variable "image_family" {
  type    = string
  default = "elk"
}
variable "image_version" {
  type    = string
  default = ""
}
variable "os_disk_size_gb" {
  # 64 GB build disk for apt unpack + agent staging in /opt/beat-pkgs/.
  type    = number
  default = 64
}

locals {
  image_name_suffix = var.image_version != "" ? var.image_version : formatdate("YYYYMMDD-hhmmss", timestamp())
}

source "googlecompute" "elk" {
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
    image   = "elk"
  }
}

build {
  sources = ["source.googlecompute.elk"]

  # Step 1: install Elastic + Kibana + Logstash + agents.
  provisioner "shell" {
    execute_command = "chmod +x {{ .Path }}; {{ .Vars }} sudo -E sh '{{ .Path }}'"
    script          = "${path.root}/scripts/elk-baseline.sh"
    timeout         = "30m"
  }

  # Step 2: deprovision (cloud-init clean, host keys, logs).
  provisioner "shell" {
    execute_command = "chmod +x {{ .Path }}; {{ .Vars }} sudo -E sh '{{ .Path }}'"
    script          = "${path.root}/../_shared/scripts/linux-deprovision.sh"
  }
}
