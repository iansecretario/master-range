################################################################################
# Packer template: Windows "11-equivalent" workstation — GCP variant.
#
# GCP equivalent of win-11.pkr.hcl. Same posture as win-10.gcp.pkr.hcl
# (they share the same base image — Server 2022 Desktop — because GCP
# publishes no client Windows SKU at all).
#
# ┌─────────────────────────────────────────────────────────────────────┐
# │ Important: GCP DOES NOT publish a Windows 11 client SKU.            │
# │   See the matching narrative in win-10.gcp.pkr.hcl. We fall back    │
# │   to `windows-2022-dc-desktop` (Server 2022 + Desktop Experience).  │
# │                                                                     │
# │   Win11-specific curriculum surfaces NOT present here:              │
# │   - Win11 21H2+ TPM 2.0-enforced features (BitLocker auto-unlock,   │
# │     Pluton attestation, Windows Hello PIN-as-MFA flows).            │
# │   - Win11 Insider channel telemetry / Diagnostic Data Viewer.       │
# │   - Win11 22H2+ Smart App Control, MDAC integration.                │
# │   - The Win11 Settings-app surface differs significantly from       │
# │     Server's; UI-driven labs that walk through Settings need        │
# │     either a screenshot supplement or to run on Azure.              │
# │                                                                     │
# │   What IS available: cmd, powershell, registry, winget (if          │
# │   installed via the bootstrap), all C2 / RAT tradecraft, FLARE-VM,  │
# │   AD member-join, the full red-team-relevant tool surface.          │
# └─────────────────────────────────────────────────────────────────────┘
#
# See win-server-2022-ad.gcp.pkr.hcl for the full narrative on
# Windows-on-GCP specifics.
#
# Usage:
#   gcloud auth application-default login
#   packer init  packer/win-11/win-11.gcp.pkr.hcl
#   packer build -var gcp_project_id=$TERRARANGE_GCP_HOST_PROJECT_ID \
#                packer/win-11/win-11.gcp.pkr.hcl
################################################################################

packer {
  required_plugins {
    googlecompute = {
      source  = "github.com/hashicorp/googlecompute"
      version = "~> 1.1"
    }
    windows-update = {
      source  = "github.com/rgl/windows-update"
      version = "~> 0.18"
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
  default = "win-11"
}
variable "image_version" {
  type    = string
  default = ""
}
variable "os_disk_size_gb" {
  type    = number
  default = 128
}

locals {
  image_name_suffix = var.image_version != "" ? var.image_version : formatdate("YYYYMMDD-hhmmss", timestamp())
}

source "googlecompute" "win11" {
  project_id = var.gcp_project_id

  # Fallback to Server 2022 with Desktop Experience — GCP has no Win11
  # client SKU.
  source_image_family     = "windows-2022-dc-desktop"
  source_image_project_id = ["windows-cloud"]

  zone         = "${var.gcp_region}-b"
  machine_type = var.vm_size
  disk_size    = var.os_disk_size_gb

  image_name        = "${var.image_family}-${local.image_name_suffix}"
  image_family      = var.image_family
  image_description = "terra-range baked ${var.image_family} (Server-2022-Desktop substitute) — built ${formatdate("YYYY-MM-DD", timestamp())}"

  communicator   = "winrm"
  winrm_username = "packer_user"
  winrm_use_ssl  = true
  winrm_insecure = true
  winrm_timeout  = "30m"

  labels = {
    builder = "packer"
    range   = "terra-range-bake"
    image   = "win-11"
    base_os = "windows-2022-dc-desktop"
  }
}

build {
  sources = ["source.googlecompute.win11"]

  # Step 1: workstation baseline.
  provisioner "powershell" {
    script            = "${path.root}/scripts/win-11-baseline.ps1"
    elevated_user     = "packer_user"
    elevated_password = build.WinRMPassword
    timeout           = "60m"
  }

  # Step 2: Windows Update once during bake.
  provisioner "windows-update" {
    search_criteria = "IsInstalled=0 and Type='Software' and IsHidden=0"
    filters = [
      "exclude:$_.Title -like '*Preview*'",
      "include:$true",
    ]
    update_limit = 25
  }

  provisioner "windows-restart" {
    restart_timeout = "30m"
  }

  # Step 3a: create wallpaper target dir.
  provisioner "powershell" {
    inline = [
      "New-Item -ItemType Directory -Path C:\\ProgramData\\CWR -Force | Out-Null",
    ]
    elevated_user     = "packer_user"
    elevated_password = build.WinRMPassword
  }

  # Step 3b: stage wallpaper.
  provisioner "file" {
    source      = "${path.root}/../_shared/files/desktop-wallpaper-CWR.png"
    destination = "C:\\ProgramData\\CWR\\wallpaper.png"
  }

  # Step 4: shared hardening.
  provisioner "powershell" {
    script            = "${path.root}/../_shared/scripts/windows-hardening.ps1"
    elevated_user     = "packer_user"
    elevated_password = build.WinRMPassword
    timeout           = "30m"
  }

  # Step 5: finalize — disable wuauserv.
  provisioner "powershell" {
    script            = "${path.root}/scripts/win-11-finalize.ps1"
    elevated_user     = "packer_user"
    elevated_password = build.WinRMPassword
    timeout           = "20m"
  }

  # Step 6: sysprep /generalize.
  provisioner "powershell" {
    inline = [
      "Write-Host 'Running sysprep...'",
      "& $env:SystemRoot\\System32\\Sysprep\\Sysprep.exe /oobe /generalize /quiet /quit",
      "while ((Get-ItemProperty -Path HKLM:\\SYSTEM\\Setup\\Status\\SysprepStatus -Name GeneralizationState).GeneralizationState -ne 7) { Start-Sleep -Seconds 5 }",
    ]
    elevated_user     = "packer_user"
    elevated_password = build.WinRMPassword
  }
}
