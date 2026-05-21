################################################################################
# Packer template: Windows Server 2025 pre-baked for terra-range.
#
# Bakes the same posture as win-server-2022 (DC role-ready) but on the
# 2025 base image:
#   - AD-DS + DNS + RSAT roles pre-installed (NOT promoted — per-deploy
#     domain name + creds drive the Install-ADDSForest call at first boot)
#   - WinRM + RDP firewall posture for lab use
#   - NetworkCategory defaulted to Private
#   - Latest cumulative update applied ONCE during build; wuauserv
#     disabled so cloned VMs don't re-patch on first boot
#   - Guidem CWR wallpaper + privacy/telemetry off + Defender
#     sample-submission off (shared
#     packer/_shared/scripts/windows-hardening.ps1)
#   - Sysprep /generalize so the image is reusable
#
# Why a separate 2025 template vs reusing 2022:
# - 2025's Marketplace SKU is `2025-datacenter-azure-edition` (different
#   from 2022's). Same publisher/offer (`MicrosoftWindowsServer`/`WindowsServer`).
# - AD-DS roles install the same way (Install-WindowsFeature works on
#   2025 with the same arg list). The baseline script is a direct clone.
# - Future 2025-specific tweaks (e.g. new ATA-style hardening or
#   feature gates) would land here without forking 2022.
#
# Usage:
#   ./range bake server-2025     # one-time, ~30 min
################################################################################

packer {
  required_plugins {
    azure = {
      source  = "github.com/hashicorp/azure"
      version = "~> 2.0"
    }
    windows-update = {
      source  = "github.com/rgl/windows-update"
      version = "~> 0.18"
    }
  }
}

variable "azure_subscription_id" { type = string }
variable "azure_region" {
  type    = string
  default = "southeastasia"
}
variable "sig_resource_group"    { type = string }
variable "sig_name"              { type = string }
variable "image_definition" {
  type    = string
  default = "win-server-2025"
}
variable "image_version" {
  type    = string
  default = "1.0.0"
}
variable "vm_size" {
  type    = string
  default = "Standard_D4s_v5"
}

source "azure-arm" "win25" {
  use_azure_cli_auth = true
  subscription_id    = var.azure_subscription_id

  # Server 2025 Marketplace base. SKU matches the deploy-side
  # image_map["windows-server-2025"] in modules/azure/images.tf.
  image_publisher = "MicrosoftWindowsServer"
  image_offer     = "WindowsServer"
  image_sku       = "2025-datacenter-azure-edition"
  image_version   = "latest"

  os_type        = "Windows"
  vm_size        = var.vm_size
  location       = var.azure_region

  communicator   = "winrm"
  winrm_use_ssl  = true
  winrm_insecure = true
  winrm_timeout  = "30m"
  winrm_username = "packer"

  shared_image_gallery_destination {
    subscription         = var.azure_subscription_id
    resource_group       = var.sig_resource_group
    gallery_name         = var.sig_name
    image_name           = var.image_definition
    image_version        = var.image_version
    replication_regions  = [var.azure_region]
    storage_account_type = "Standard_LRS"
  }

  managed_image_name                = "${var.image_definition}-${var.image_version}-tmp"
  managed_image_resource_group_name = var.sig_resource_group
}

build {
  sources = ["source.azure-arm.win25"]

  # Step 1: AD-DS + WinRM + RDP + firewall baseline.
  provisioner "powershell" {
    script = "${path.root}/scripts/win-server-2025-baseline.ps1"
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
  }

  # Step 3b: stage wallpaper.
  provisioner "file" {
    source      = "${path.root}/../_shared/files/desktop-wallpaper-CWR.png"
    destination = "C:\\ProgramData\\CWR\\wallpaper.png"
  }

  # Step 4: shared hardening (Guidem wallpaper + privacy/telemetry off +
  # Defender sample-submission off + OOBE suppression).
  provisioner "powershell" {
    script = "${path.root}/../_shared/scripts/windows-hardening.ps1"
  }

  # Step 5: finalize — disable wuauserv.
  provisioner "powershell" {
    script = "${path.root}/scripts/win-server-2025-finalize.ps1"
  }

  # Step 6: sysprep /generalize.
  provisioner "powershell" {
    inline = [
      "Write-Host 'Running sysprep...'",
      "& $env:SystemRoot\\System32\\Sysprep\\Sysprep.exe /oobe /generalize /quiet /quit",
      "while ((Get-ItemProperty -Path HKLM:\\SYSTEM\\Setup\\Status\\SysprepStatus -Name GeneralizationState).GeneralizationState -ne 7) { Start-Sleep -Seconds 5 }",
    ]
  }
}
