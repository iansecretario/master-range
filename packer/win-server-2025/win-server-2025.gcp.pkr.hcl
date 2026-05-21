################################################################################
# Packer template: Windows Server 2025 — GCP variant.
#
# GCP equivalent of win-server-2025.pkr.hcl. Same provisioner pipeline
# and shared scripts; source/communicator/destination differ.
#
# See win-server-2022-ad.gcp.pkr.hcl for the full narrative on
# Windows-on-GCP specifics (cloud-init not used, WinRM password
# randomization, sysprep requirement, image_family output).
#
# Usage:
#   gcloud auth application-default login
#   packer init  packer/win-server-2025/win-server-2025.gcp.pkr.hcl
#   packer build -var gcp_project_id=$TERRARANGE_GCP_HOST_PROJECT_ID \
#                packer/win-server-2025/win-server-2025.gcp.pkr.hcl
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
  default = "win-server-2025"
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

source "googlecompute" "win25" {
  project_id = var.gcp_project_id

  # Microsoft's published Server 2025 Datacenter family in
  # `windows-cloud`. (https://cloud.google.com/compute/docs/images#windows)
  source_image_family     = "windows-2025-dc"
  source_image_project_id = ["windows-cloud"]

  zone         = "${var.gcp_region}-b"
  machine_type = var.vm_size
  disk_size    = var.os_disk_size_gb

  image_name        = "${var.image_family}-${local.image_name_suffix}"
  image_family      = var.image_family
  image_description = "terra-range baked ${var.image_family} — built ${formatdate("YYYY-MM-DD", timestamp())}"

  communicator   = "winrm"
  winrm_username = "packer_user"
  winrm_use_ssl  = true
  winrm_insecure = true
  winrm_timeout  = "30m"

  labels = {
    builder = "packer"
    range   = "terra-range-bake"
    image   = "win-server-2025"
  }
}

build {
  sources = ["source.googlecompute.win25"]

  # Step 1: AD-DS + WinRM + RDP + firewall baseline (cloud-agnostic).
  provisioner "powershell" {
    script            = "${path.root}/scripts/win-server-2025-baseline.ps1"
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
    script            = "${path.root}/scripts/win-server-2025-finalize.ps1"
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
