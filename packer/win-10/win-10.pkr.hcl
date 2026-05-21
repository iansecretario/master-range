################################################################################
# Packer template: Windows 10 (workstation tier) pre-baked for terra-range.
#
# Used for: ws10 in redteam-lab, the analyst FLARE-VM box (until we split
# that into its own template), and any future windows-workstation entry
# in a scenario.
#
# Bakes in:
#   - RDP + WinRM open (lab posture; same as server images)
#   - Guidem CWR wallpaper as machine-wide HKLM policy
#   - Privacy/telemetry off, Defender sample-submission forced off
#   - OOBE wizard suppressed; first interactive logon → desktop
#   - Latest cumulative update applied ONCE during build; wuauserv disabled
#     so deployed VMs don't re-patch on first boot
#   - Sysprepped /generalize so the image is reusable
#
# Domain join, persona scripts, FLARE-VM bootstrap, etc. stay at deploy
# time — those are per-deploy/per-machine concerns.
#
# Usage:
#   az vm image terms accept --urn microsoftwindowsdesktop:Windows-10:win10-22h2-pro-g2:latest
#   ./range bake win-10        # one-time, ~30 min
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
  default = "win-10"
}
variable "image_version" {
  type    = string
  default = "1.0.0"
}
variable "vm_size" {
  type    = string
  default = "Standard_D4s_v5"
}

source "azure-arm" "win10" {
  use_azure_cli_auth = true
  subscription_id    = var.azure_subscription_id

  # Mirror modules/azure/images.tf's "windows-10" entry exactly.
  image_publisher = "MicrosoftWindowsDesktop"
  image_offer     = "Windows-10"
  image_sku       = "win10-22h2-pro-g2"
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
  sources = ["source.azure-arm.win10"]

  # Step 1: workstation baseline — RDP + WinRM + firewall posture.
  provisioner "powershell" {
    script = "${path.root}/scripts/win-10-baseline.ps1"
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

  # Step 3a + 3b: stage wallpaper.
  provisioner "powershell" {
    inline = [
      "New-Item -ItemType Directory -Path C:\\ProgramData\\CWR -Force | Out-Null",
    ]
  }
  provisioner "file" {
    source      = "${path.root}/../_shared/files/desktop-wallpaper-CWR.png"
    destination = "C:\\ProgramData\\CWR\\wallpaper.png"
  }

  # Step 4: shared hardening (wallpaper policy + privacy/telemetry off +
  # Defender sample-submission off + OOBE suppression).
  provisioner "powershell" {
    script = "${path.root}/../_shared/scripts/windows-hardening.ps1"
  }

  # Step 5: finalize — disable wuauserv so deploys don't re-patch.
  provisioner "powershell" {
    script = "${path.root}/scripts/win-10-finalize.ps1"
  }

  # Step 6: sysprep /generalize. Win10 uses the same Sysprep.exe path
  # as Server SKUs (System32\Sysprep\Sysprep.exe).
  provisioner "powershell" {
    inline = [
      "Write-Host 'Running sysprep...'",
      "& $env:SystemRoot\\System32\\Sysprep\\Sysprep.exe /oobe /generalize /quiet /quit",
      "while ((Get-ItemProperty -Path HKLM:\\SYSTEM\\Setup\\Status\\SysprepStatus -Name GeneralizationState).GeneralizationState -ne 7) { Start-Sleep -Seconds 5 }",
    ]
  }
}
