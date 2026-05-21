################################################################################
# Packer template: Windows Server 2022 pre-baked for terra-range DC role.
#
# What this image has done for you BEFORE terraform sees it:
#   - AD-Domain-Services + DNS roles installed (NOT promoted — promo is
#     per-deploy because forest creation needs unique domain name + creds)
#   - WinRM enabled with Basic+Negotiate auth, AllowUnencrypted (lab)
#   - Network profile defaulted to Private (first-boot doesn't bounce to
#     Public and break WinRM firewall opening)
#   - Windows Update disabled (wuauserv + UsoSvc set to Disabled)
#   - Latest cumulative update applied ONCE during build
#   - Firewall rules for RDP + WinRM open
#   - Sysprepped /generalize so the image is reusable across VMs
#
# What's left to do at deploy time (~3-5 min for promo, vs 25-30 from
# raw Marketplace):
#   - Install-ADDSForest -DomainName <per-deploy>
#   - lab_users seeding
#   - Member join scripts (on the OTHER VMs, which use their own image)
#
# Usage:
#   ./range bake server-2022     # one-time, ~30 min, ~$0.20 of compute
#   ./range apply <scenario>     # subsequent applies skip the slow bits
################################################################################

packer {
  required_plugins {
    azure = {
      source  = "github.com/hashicorp/azure"
      version = "~> 2.0"
    }
    # The `windows-update` provisioner in the build block below is the
    # community rgl plugin, NOT a packer built-in — it must be declared
    # here or `packer init` won't fetch it and `packer build` dies with
    # an "unknown provisioner windows-update" error.
    windows-update = {
      source  = "github.com/rgl/windows-update"
      version = "~> 0.18"
    }
  }
}

# ---- Where the operator authenticates + where the SIG lives ---------------
# Variables are populated by `./range bake` from terraform tfvars + scenario
# YAML so the operator doesn't have to maintain a second config surface.
variable "azure_subscription_id" { type = string }
variable "azure_region" {
  type    = string
  default = "southeastasia"
}
variable "sig_resource_group"    { type = string }
variable "sig_name"              { type = string }
variable "image_definition" {
  type    = string
  default = "win-server-2022-ad"
}
variable "image_version" {
  type    = string
  default = "1.0.0"
}
variable "vm_size" {
  type    = string
  default = "Standard_D4s_v5"
}

source "azure-arm" "win22-ad" {
  use_azure_cli_auth = true
  subscription_id    = var.azure_subscription_id

  # Base: same SKU as our Marketplace path in images.tf.
  image_publisher = "MicrosoftWindowsServer"
  image_offer     = "WindowsServer"
  image_sku       = "2022-datacenter-azure-edition"
  image_version   = "latest"

  os_type        = "Windows"
  vm_size        = var.vm_size
  location       = var.azure_region

  # Communicator: Packer connects to the build VM over WinRM (5986 / mTLS).
  communicator   = "winrm"
  winrm_use_ssl  = true
  winrm_insecure = true
  winrm_timeout  = "30m"
  winrm_username = "packer"

  # Output to Shared Image Gallery so terraform can reference by
  # source_image_id without juggling managed-disk names.
  shared_image_gallery_destination {
    subscription         = var.azure_subscription_id
    resource_group       = var.sig_resource_group
    gallery_name         = var.sig_name
    image_name           = var.image_definition
    image_version        = var.image_version
    replication_regions  = [var.azure_region]
    storage_account_type = "Standard_LRS"
  }

  # Sysprep so the captured image is generalized; first boot of every
  # cloned VM re-runs OOBE-light and gets a fresh machine SID.
  # No build_resource_group_name: with `location` set above, Packer
  # creates its OWN ephemeral resource group for the build VM and tears
  # it down when the build finishes. `location` and
  # build_resource_group_name are mutually exclusive — setting both is
  # the "specify either a location ... or an existing
  # build_resource_group_name, but not both" error.
  #
  # The throwaway managed image lands in the SIG's resource group
  # (terra-range-images-rg — it already exists; pointing at a dedicated
  # build RG would mean creating that RG first). It's version-suffixed
  # so re-bakes don't collide on the name. terraform never reads this
  # managed image — it reads the gallery version published by
  # shared_image_gallery_destination above.
  managed_image_name        = "${var.image_definition}-${var.image_version}-tmp"
  managed_image_resource_group_name = var.sig_resource_group
}

build {
  sources = ["source.azure-arm.win22-ad"]

  # Step 1: baseline + AD-DS install. Reboot if requested.
  provisioner "powershell" {
    script = "${path.root}/scripts/win-server-2022-baseline.ps1"
  }

  # Step 2: Windows Update once during build (operator pays this cost
  # ONCE per quarterly rebake, not on every deploy). Comment out if you
  # want to skip updates entirely.
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

  # Step 3a: create the target directory for the wallpaper upload.
  # Packer's `file` provisioner doesn't auto-create parent dirs on
  # Windows, so we mkdir first via inline powershell. Idempotent
  # via -Force.
  provisioner "powershell" {
    inline = [
      "New-Item -ItemType Directory -Path C:\\ProgramData\\CWR -Force | Out-Null",
    ]
  }

  # Step 3b: stage the Guidem CWR wallpaper at the canonical path. The
  # hardening script (next step) references this exact path in the
  # HKLM Wallpaper policy key. Wallpaper file is staged ONCE in
  # packer/_shared/files/ so every Windows template uses the same
  # asset; bumping the wallpaper is a single-file replace.
  provisioner "file" {
    source      = "${path.root}/../_shared/files/desktop-wallpaper-CWR.png"
    destination = "C:\\ProgramData\\CWR\\wallpaper.png"
  }

  # Step 4: shared Windows hardening — same posture for every baked
  # Windows image (Guidem wallpaper policy + privacy/telemetry off +
  # Defender sample submission forced off + OOBE suppression). Lives
  # in packer/_shared/scripts/windows-hardening.ps1 so a posture change
  # is one edit, not per-image. Mirrors the
  # modules/azure/ansible/roles/windows-base role's task set —
  # defense-in-depth (image-baked AND ansible-applied on every repair).
  provisioner "powershell" {
    script = "${path.root}/../_shared/scripts/windows-hardening.ps1"
  }

  # Step 5: post-update finalize — disable wuauserv so deploys don't
  # re-patch on first boot.
  provisioner "powershell" {
    script = "${path.root}/scripts/win-server-2022-finalize.ps1"
  }

  # Step 6: sysprep. Packer's built-in `windows-sysprep` is not enough
  # for Server SKUs; we drive sysprep manually to ensure /generalize +
  # /oobe + /shutdown so the captured image is truly reusable.
  provisioner "powershell" {
    inline = [
      "Write-Host 'Running sysprep...'",
      "& $env:SystemRoot\\System32\\Sysprep\\Sysprep.exe /oobe /generalize /quiet /quit",
      "while ((Get-ItemProperty -Path HKLM:\\SYSTEM\\Setup\\Status\\SysprepStatus -Name GeneralizationState).GeneralizationState -ne 7) { Start-Sleep -Seconds 5 }",
    ]
  }
}
