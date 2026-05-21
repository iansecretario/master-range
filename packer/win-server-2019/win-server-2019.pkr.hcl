################################################################################
# Packer template: Windows Server 2019 pre-baked for terra-range member-server
# role (srv01 in redteam-lab).
#
# Differences from win-server-2022:
#   - source image: 2019-Datacenter (not 2022-datacenter-azure-edition)
#   - no AD-DS role install (this image is a domain MEMBER server, not a DC;
#     DC stays on win-server-2022 with AD-DS roles pre-installed)
#   - shares everything else: Guidem wallpaper, hardening, OOBE suppression,
#     Defender sample-submission off, Windows Update applied once + disabled
#
# Usage:
#   ./range bake server-2019      # one-time, ~30 min, ~$0.20 of compute
#   ./range apply <scenario>      # subsequent applies skip the slow first-boot
#
# Time saved per deploy: ~8-10 min per srv01 (skip first-boot
# kali-linux-default-style WU + provisioning).
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

# ---- Same variable surface as the other Windows templates ------------------
variable "azure_subscription_id" { type = string }
variable "azure_region" {
  type    = string
  default = "southeastasia"
}
variable "sig_resource_group"    { type = string }
variable "sig_name"              { type = string }
variable "image_definition" {
  type    = string
  default = "win-server-2019"
}
variable "image_version" {
  type    = string
  default = "1.0.0"
}
variable "vm_size" {
  type    = string
  default = "Standard_D4s_v5"
}

source "azure-arm" "win19" {
  use_azure_cli_auth = true
  subscription_id    = var.azure_subscription_id

  # Server 2019 Marketplace base. MUST be the Gen2 SKU (`-g2` suffix) —
  # our SIG image-def `azurerm_shared_image.win_server_2019` declares
  # `hyper_v_generation = "V2"` (baking.tf:271), and Azure rejects
  # publishing a V1 managed image into a V2 image-def slot with:
  #   "Conflict: The resource ... has a different Hypervisor generation
  #    ['V1'] than the parent gallery image Hypervisor generation ['V2']."
  # The non-suffixed `2019-Datacenter` SKU produces Gen1 by default.
  #
  # SKU matches `modules/azure/images.tf:158` — the deploy-side
  # source_image_reference for windows-server-2019 uses
  # `2019-datacenter-gensecond` (a Gen2 alias). Keep both in lockstep
  # so the baked image and the marketplace-direct fallback are
  # bit-identical at the OS level.
  image_publisher = "MicrosoftWindowsServer"
  image_offer     = "WindowsServer"
  image_sku       = "2019-datacenter-gensecond"
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
  sources = ["source.azure-arm.win19"]

  # Step 1: baseline — RDP + WinRM + firewall posture. No AD-DS (this is
  # a member-server image; deploys join it to the per-range DC at
  # cloud-init time).
  provisioner "powershell" {
    script = "${path.root}/scripts/win-server-2019-baseline.ps1"
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
    script = "${path.root}/scripts/win-server-2019-finalize.ps1"
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
