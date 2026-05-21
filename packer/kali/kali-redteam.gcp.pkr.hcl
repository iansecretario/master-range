################################################################################
# Packer template: Kali Linux pre-baked for the terra-range attacker role.
# GCP equivalent of kali-redteam.pkr.hcl — same baseline + deprovision scripts,
# `googlecompute` source replaces `azure-arm`, and the output is a custom image
# (with image_family) in the host project instead of a Shared Image Gallery
# version.
#
# What this image has done for you BEFORE terraform sees it: identical to the
# Azure variant — kali-linux-default metapackage, XFCE + xrdp + TigerVNC,
# AdaptixClient Qt6 build deps, apt cache cleaned, cloud-init/host-key/
# machine-id reset for a GENERALIZED image. See kali-redteam.pkr.hcl for the
# full narrative; both templates share scripts/kali-baseline.sh and
# scripts/kali-deprovision.sh verbatim.
#
# Auth model: the operator runs `gcloud auth application-default login` once
# before invoking `./range bake kali`. Packer's googlecompute builder picks up
# the ADC token automatically — no service-account JSON key is created or
# checked in. The host project (var.gcp_project_id, normally
# $TERRARANGE_GCP_HOST_PROJECT_ID) owns the baked image; deployment scenarios
# read it cross-project by family.
#
# Usage:
#   gcloud auth application-default login                # once per workstation
#   packer init  packer/kali/kali-redteam.gcp.pkr.hcl
#   packer build -var gcp_project_id=$TERRARANGE_GCP_HOST_PROJECT_ID \
#                packer/kali/kali-redteam.gcp.pkr.hcl
################################################################################

packer {
  required_plugins {
    googlecompute = {
      source  = "github.com/hashicorp/googlecompute"
      version = "~> 1.1"
    }
  }
}

# ---- Where the operator authenticates + where the image lands -------------
# Variables are populated by `./range bake kali` so the operator doesn't
# maintain a second config surface.
variable "gcp_project_id" {
  # Host project that owns baked images (mirrors sig_resource_group/sig_name
  # on the Azure side). Required — no default; operator passes via env.
  type = string
}
variable "gcp_region" {
  type    = string
  default = "asia-southeast1"
}
variable "vm_size" {
  # n2-standard-4 is the GCP equivalent of Standard_D4s_v5 — 4 vCPU, 16 GB
  # RAM is enough for the kali-linux-default unpack.
  type    = string
  default = "n2-standard-4"
}
variable "image_family" {
  # Image family lets terraform pin to "latest non-deprecated" without
  # tracking individual versions. Equivalent to the Azure SIG image_definition.
  type    = string
  default = "kali-redteam"
}
variable "image_version" {
  # GCP image names are unique per-project, so we date-stamp by default.
  # Override at bake time with a semver if you want stable references.
  type    = string
  default = ""
}
variable "os_disk_size_gb" {
  # 64 GB build disk: kali-linux-default + the Qt6 dev stack land around
  # ~20 GB; this leaves headroom for the apt unpack. Deployed VMs expand
  # this to their role-aware size via terraform.
  type    = number
  default = 64
}
variable "kali_marketplace_project" {
  # The Kali team publishes images into the `kali-linux-public` project on
  # GCP Marketplace; image_family is `kali-rolling`. Override if Offensive
  # Security changes the project name.
  # TODO(operator): verify with
  #   gcloud compute images list --project=kali-linux-public --filter="family:kali-rolling"
  # before the first bake — Kali's GCP Marketplace project name has shifted
  # historically (kali-linux, kali-linux-public). If the family lookup
  # returns nothing, fall back to debian-12 and run the kali-rolling
  # install steps inside scripts/kali-baseline.sh.
  type    = string
  default = "kali-linux-public"
}

# Computed name: use the user-provided version if set, else date-stamp.
locals {
  image_name_suffix = var.image_version != "" ? var.image_version : formatdate("YYYYMMDD-hhmmss", timestamp())
}

source "googlecompute" "kali" {
  project_id = var.gcp_project_id

  # Base: Kali rolling from the Kali-published Marketplace project. This is
  # the GCP equivalent of the (kali-linux, kali, kali-2026-1) Azure
  # Marketplace SKU. Unlike Azure, GCP Marketplace images don't have a
  # separate "plan_info" surface — accept-eula is per-project and a one-time
  # operator action via the Console.
  source_image_family     = "kali-rolling"
  source_image_project_id = [var.kali_marketplace_project]

  zone         = "${var.gcp_region}-b"
  machine_type = var.vm_size
  disk_size    = var.os_disk_size_gb

  # Output image: published into the HOST project, organized by family so
  # terraform can reference "latest non-deprecated" without bumping versions.
  image_name        = "${var.image_family}-${local.image_name_suffix}"
  image_family      = var.image_family
  image_description = "terra-range baked ${var.image_family} — built ${formatdate("YYYY-MM-DD", timestamp())}"

  # SSH config — Packer creates a temporary user on the build VM and tears
  # the key down at the end.
  ssh_username = "packer"
  ssh_timeout  = "30m"

  # Tag the ephemeral build VM so it's visible in cost reports / billing.
  labels = {
    builder = "packer"
    range   = "terra-range-bake"
    image   = "kali-redteam"
  }
}

build {
  sources = ["source.googlecompute.kali"]

  # Step 0: upload the CWR wallpaper PNG — same as Azure variant. The
  # baseline script moves it to /usr/share/backgrounds/cwr-wallpaper.png.
  provisioner "file" {
    source      = "${path.root}/../_shared/files/desktop-wallpaper-CWR.png"
    destination = "/tmp/cwr-wallpaper.png"
  }

  # Step 1: the heavy lifting — kali-linux-default + desktop + VNC/xrdp +
  # AdaptixClient build deps. Same script as the Azure bake. Times out at
  # 60m to absorb the kali-linux-default unpack on a fresh VM.
  provisioner "shell" {
    execute_command = "chmod +x {{ .Path }}; {{ .Vars }} sudo -E sh '{{ .Path }}'"
    script          = "${path.root}/scripts/kali-baseline.sh"
    timeout         = "60m"
  }

  # Step 2: deprovision — resets cloud-init (re-runs fresh on every deployed
  # VM: creates `ranger`, drops the operator key), strips SSH host keys,
  # machine-id, DHCP leases, logs/history. Same script as the Azure bake;
  # cloud-init-native, not waagent — works identically on GCP because the
  # Kali image is cloud-init-provisioned on both clouds.
  provisioner "shell" {
    execute_command = "chmod +x {{ .Path }}; {{ .Vars }} sudo -E sh '{{ .Path }}'"
    script          = "${path.root}/scripts/kali-deprovision.sh"
  }
}
