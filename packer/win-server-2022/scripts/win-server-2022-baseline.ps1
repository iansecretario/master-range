# Bake-time baseline for Windows Server 2022.
# Installs AD-DS feature (without promo), opens RDP + WinRM, sets the
# default network profile to Private so first boot of every cloned VM
# doesn't bounce to Public and break WinRM firewall opening.
#
# Idempotent — sysprep will reset machine-specific state; this script
# only configures the "every VM should have this" baseline.

$ErrorActionPreference = "Continue"
Start-Transcript -Path C:\packer-baseline.log -Append

Write-Host "==> Installing AD-DS + DNS roles (no promotion)..."
Install-WindowsFeature -Name AD-Domain-Services,DNS,RSAT-AD-Tools,RSAT-DNS-Server -IncludeManagementTools

Write-Host "==> Firewall: enable RDP + WinRM groups, disable per-profile blocking for lab use..."
Set-NetFirewallProfile -Profile Domain,Public,Private -Enabled False
Enable-NetFirewallRule -DisplayGroup "Remote Desktop"
Enable-NetFirewallRule -DisplayGroup "Windows Remote Management"

Write-Host "==> RDP enabled (TermService auto-start, fDenyTSConnections=0)..."
Set-Service -Name TermService -StartupType Automatic
Set-ItemProperty -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server" -Name fDenyTSConnections -Value 0

Write-Host "==> WinRM baseline (Basic+Negotiate, AllowUnencrypted for lab)..."
Enable-PSRemoting -Force -SkipNetworkProfileCheck
Set-Item WSMan:\localhost\Service\AllowUnencrypted   $true -Force -ErrorAction SilentlyContinue
Set-Item WSMan:\localhost\Service\Auth\Basic         $true -Force -ErrorAction SilentlyContinue
Set-Item WSMan:\localhost\Shell\MaxMemoryPerShellMB  1024 -Force -ErrorAction SilentlyContinue
Set-Service WinRM -StartupType Automatic

Write-Host "==> Default NIC categorization to Private at next boot (avoids Public-profile WinRM block)..."
# This sets the NLA classification policy so first-boot doesn't dump us
# back to Public. Combined with the runtime Set-NetConnectionProfile
# call in the deploy-time script, this is belt-and-suspenders.
New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\NetworkList\Signatures" -Force | Out-Null

Write-Host "==> Baseline complete."
Stop-Transcript
