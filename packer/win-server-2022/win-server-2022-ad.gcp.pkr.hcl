################################################################################
# Packer template: Windows Server 2022 (AD-DS ready) — GCP variant.
#
# GCP equivalent of win-server-2022-ad.pkr.hcl. Same provisioner pipeline
# (baseline → hardening → finalize → sysprep) and the same shared scripts;
# only the source/communicator/destination differ.
#
# Why a parallel `.gcp.pkr.hcl` instead of multi-source on the Azure file:
#   - Builder-specific knobs (image_publisher vs source_image_family,
#     SIG-destination vs image_family output, WinRM bootstrap via metadata
#     vs azure-arm's automatic agent install) drift far enough that a
#     single template becomes a maze of conditionals. One file per cloud
#     keeps each readable in isolation.
#   - `packer build` selects sources by name; the operator picks
#     `.pkr.hcl` (Azure) vs `.gcp.pkr.hcl` (GCP) by which file they pass.
#
# Windows-on-GCP notes worth being explicit about:
#   1. Cloud-init isn't used for Windows on GCE — first-boot bootstrap
#      is via `windows-startup-script-ps1` instance metadata. Packer's
#      googlecompute builder injects that automatically when the
#      communicator is `winrm`.
#   2. The Packer-built WinRM user gets a randomized password at build
#      time; we reference it via `{{ .WinRMPassword }}` for `elevated_*`
#      so nothing is hardcoded.
#   3. Sysprep /generalize is still required: GCE's reset-windows-password
#      flow (and the agent's metadata-driven user creation) depends on a
#      generalized image. `win-server-2022-finalize.ps1` + the inline
#      Sysprep block at the bottom handle this.
#   4. Output is a GCE custom image in the host project — terraform on
#      GCP reads it by `image_family` (newest version) or by image name.
#      No Shared Image Gallery equivalent needed.
#
# Usage:
#   gcloud auth application-default login                                # once
#   packer init  packer/win-server-2022/win-server-2022-ad.gcp.pkr.hcl
#   packer build -var gcp_project_id=$TERRARANGE_GCP_HOST_PROJECT_ID \
#                packer/win-server-2022/win-server-2022-ad.gcp.pkr.hcl
################################################################################

packer {
  required_plugins {
    googlecompute = {
      source  = "github.com/hashicorp/googlecompute"
      version = "~> 1.1"
    }
    # Same community plugin used on the Azure side; `windows-update`
    # provisioner is not built in. `packer init` will pull it.
    windows-update = {
      source  = "github.com/rgl/windows-update"
      version = "~> 0.18"
    }
  }
}

# ---- Variables --------------------------------------------------------------
# Same shape as the other Windows GCP templates so `./range bake` can drive
# any image with the same tfvars-derived inputs.
variable "gcp_project_id" {
  type = string
}
variable "gcp_region" {
  type    = string
  default = "asia-southeast1"
}
variable "vm_size" {
  # n2-standard-4 mirrors the Azure Standard_D4s_v5 baseline — 4 vCPU
  # / 16 GB RAM is plenty for the AD-DS install + WU pass.
  type    = string
  default = "n2-standard-4"
}
variable "image_family" {
  type    = string
  default = "win-server-2022-ad"
}
variable "image_version" {
  # Empty default → timestamp suffix. Pass an explicit value for
  # reproducible image names.
  type    = string
  default = ""
}
variable "os_disk_size_gb" {
  # Server SKUs want headroom for WU + roles staging. 128 GB matches
  # the Azure-side default and gives the cumulative-update pass room
  # to expand the component store.
  type    = number
  default = 128
}

locals {
  image_name_suffix = var.image_version != "" ? var.image_version : formatdate("YYYYMMDD-hhmmss", timestamp())
}

source "googlecompute" "win22-ad" {
  project_id = var.gcp_project_id

  # Source: Microsoft's published Server 2022 Datacenter image family in
  # the `windows-cloud` publisher project. Always-latest by family.
  source_image_family     = "windows-2022-dc"
  source_image_project_id = ["windows-cloud"]

  zone         = "${var.gcp_region}-b"
  machine_type = var.vm_size
  disk_size    = var.os_disk_size_gb

  # Output image — terraform reads by image_family for newest-version
  # selection, or by full image_name for pin-to-version.
  image_name        = "${var.image_family}-${local.image_name_suffix}"
  image_family      = var.image_family
  image_description = "terra-range baked ${var.image_family} — built ${formatdate("YYYY-MM-DD", timestamp())}"

  # Communicator: googlecompute generates a random WinRM password,
  # resets it via the GCE Windows-password protocol, and exposes it
  # to provisioners as {{ .WinRMPassword }}. We DO NOT hardcode a
  # password anywhere.
  communicator   = "winrm"
  winrm_username = "packer_user"
  winrm_use_ssl  = true
  winrm_insecure = true
  winrm_timeout  = "30m"

  labels = {
    builder = "packer"
    range   = "terra-range-bake"
    image   = "win-server-2022-ad"
  }
}

build {
  sources = ["source.googlecompute.win22-ad"]

  # Step 1: baseline + AD-DS install. Reuses the Azure-side script
  # verbatim — it only touches OS-level posture (WinRM, RDP, firewall,
  # AD-DS feature install) so it's cloud-agnostic.
  provisioner "powershell" {
    script            = "${path.root}/scripts/win-server-2022-baseline.ps1"
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

  # Step 3a: create wallpaper target dir (Packer's file provisioner
  # doesn't auto-create parent dirs on Windows).
  provisioner "powershell" {
    inline = [
      "New-Item -ItemType Directory -Path C:\\ProgramData\\CWR -Force | Out-Null",
    ]
    elevated_user     = "packer_user"
    elevated_password = build.WinRMPassword
  }

  # Step 3b: stage wallpaper — same shared asset as the Azure bake.
  provisioner "file" {
    source      = "${path.root}/../_shared/files/desktop-wallpaper-CWR.png"
    destination = "C:\\ProgramData\\CWR\\wallpaper.png"
  }

  # Step 4: shared Windows hardening — same posture for every baked
  # Windows image (wallpaper policy + privacy/telemetry off + Defender
  # sample submission off + OOBE suppression).
  provisioner "powershell" {
    script            = "${path.root}/../_shared/scripts/windows-hardening.ps1"
    elevated_user     = "packer_user"
    elevated_password = build.WinRMPassword
    timeout           = "30m"
  }

  # Step 5: finalize — disable wuauserv so deploys don't re-patch.
  provisioner "powershell" {
    script            = "${path.root}/scripts/win-server-2022-finalize.ps1"
    elevated_user     = "packer_user"
    elevated_password = build.WinRMPassword
    timeout           = "20m"
  }

  # Step 6: sysprep /generalize. GCE's reset-windows-password
  # workflow on cloned VMs requires a generalized image.
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
