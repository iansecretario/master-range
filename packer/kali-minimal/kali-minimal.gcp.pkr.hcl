################################################################################
# Packer template: Kali Linux MINIMAL (offensive-focused) pre-baked for the
# terra-range attacker role. GCP equivalent of kali-minimal.pkr.hcl — same
# baseline + deprovision scripts; `googlecompute` source replaces `azure-arm`.
#
# Curated, lighter toolset compared to kali-redteam (kali-linux-core +
# selected kali-tools-* groups instead of kali-linux-default). See
# kali-minimal.pkr.hcl for the full narrative; both templates share
# scripts/kali-minimal-baseline.sh and scripts/kali-deprovision.sh verbatim.
#
# Usage:
#   gcloud auth application-default login                # once per workstation
#   packer init  packer/kali-minimal/kali-minimal.gcp.pkr.hcl
#   packer build -var gcp_project_id=$TERRARANGE_GCP_HOST_PROJECT_ID \
#                packer/kali-minimal/kali-minimal.gcp.pkr.hcl
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
  # n2-standard-2 is enough for the curated toolset bake.
  type    = string
  default = "n2-standard-2"
}
variable "image_family" {
  type    = string
  default = "kali-minimal"
}
variable "image_version" {
  type    = string
  default = ""
}
variable "os_disk_size_gb" {
  # 32 GB build disk: curated toolset + desktop + Qt6 dev stack fit
  # comfortably; tighter than kali-redteam (which carries kali-linux-default).
  type    = number
  default = 32
}
variable "kali_marketplace_project" {
  # See kali-redteam.gcp.pkr.hcl for the verification one-liner. Same caveat
  # applies: confirm Kali's Marketplace project name before first bake.
  type    = string
  default = "kali-linux-public"
}

locals {
  image_name_suffix = var.image_version != "" ? var.image_version : formatdate("YYYYMMDD-hhmmss", timestamp())
}

source "googlecompute" "kali-minimal" {
  project_id = var.gcp_project_id

  source_image_family     = "kali-rolling"
  source_image_project_id = [var.kali_marketplace_project]

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
    image   = "kali-minimal"
  }
}

build {
  sources = ["source.googlecompute.kali-minimal"]

  # Step 1: kali-linux-core + curated kali-tools-* groups + desktop +
  # VNC/xrdp + AdaptixClient build deps. Same script as the Azure bake.
  provisioner "shell" {
    execute_command = "chmod +x {{ .Path }}; {{ .Vars }} sudo -E sh '{{ .Path }}'"
    script          = "${path.root}/scripts/kali-minimal-baseline.sh"
    timeout         = "60m"
  }

  # Step 2: deprovision (cloud-init clean, host keys, machine-id, logs).
  # Same script as the Azure bake; cloud-init-native works on GCP.
  provisioner "shell" {
    execute_command = "chmod +x {{ .Path }}; {{ .Vars }} sudo -E sh '{{ .Path }}'"
    script          = "${path.root}/scripts/kali-deprovision.sh"
  }
}
