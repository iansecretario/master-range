################################################################################
# Packer template: Windows "10-equivalent" workstation — GCP variant.
#
# GCP equivalent of win-10.pkr.hcl. Same provisioner pipeline (baseline →
# hardening → finalize → sysprep) and the same shared scripts; output is
# a GCE custom image rather than a SIG version.
#
# ┌─────────────────────────────────────────────────────────────────────┐
# │ Important: GCP DOES NOT publish a Windows 10 client SKU.            │
# │   Microsoft + Google only offer Windows *Server* in the public      │
# │   `windows-cloud` project. Windows 10 / 11 client editions are not  │
# │   available via Marketplace and are not redistributable as GCE      │
# │   custom images without a BYOL Software Assurance / VLSC license.   │
# │                                                                     │
# │   For lab/curriculum continuity we use the                          │
# │   `windows-2022-dc-desktop` family — Server 2022 Datacenter with    │
# │   the Desktop Experience installed — as the closest analog. It      │
# │   ships with explorer.exe + the modern Windows shell, can run all   │
# │   the same offensive tooling and FLARE-VM bootstraps that the       │
# │   Azure win-10 image runs, and accepts the same hardening posture.  │
# │                                                                     │
# │ What this image is NOT:                                             │
# │   - Not Win10-22H2-Pro (no Microsoft Store, no Tiles, no S-mode,    │
# │     no Edge-as-client tracking signals).                            │
# │   - Telemetry endpoints differ slightly (Server-side                │
# │     v10.events.data.microsoft.com vs Win10-client equivalents).     │
# │   - SmartScreen / WDAG / Family Safety surfaces are absent.         │
# │     These matter if the curriculum specifically tests against       │
# │     Win10 client telemetry; either pivot the lesson to Azure for    │
# │     those weeks or document the gap in the scenario YAML.           │
# └─────────────────────────────────────────────────────────────────────┘
#
# See win-server-2022-ad.gcp.pkr.hcl for the full narrative on
# Windows-on-GCP specifics.
#
# Usage:
#   gcloud auth application-default login
#   packer init  packer/win-10/win-10.gcp.pkr.hcl
#   packer build -var gcp_project_id=$TERRARANGE_GCP_HOST_PROJECT_ID \
#                packer/win-10/win-10.gcp.pkr.hcl
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
  default = "win-10"
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

source "googlecompute" "win10" {
  project_id = var.gcp_project_id

  # Fallback to Server 2022 with Desktop Experience — GCP has no Win10
  # client SKU. The `-desktop` suffix on the family pulls the full GUI
  # shell, not just Server Core.
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
    image   = "win-10"
    # Tag the underlying base so deploy-side audits can spot the fallback.
    base_os = "windows-2022-dc-desktop"
  }
}

build {
  sources = ["source.googlecompute.win10"]

  # Step 1: workstation baseline — RDP + WinRM + firewall posture.
  # win-10-baseline.ps1 is cloud-agnostic; it doesn't care that the
  # underlying OS is Server-2022-Desktop, just configures the registry
  # / firewall / WinRM state.
  provisioner "powershell" {
    script            = "${path.root}/scripts/win-10-baseline.ps1"
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

  # Step 5: finalize — disable wuauserv so deploys don't re-patch.
  provisioner "powershell" {
    script            = "${path.root}/scripts/win-10-finalize.ps1"
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
