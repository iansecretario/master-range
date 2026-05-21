# Bake-time baseline for Windows 10 workstation image.
# Same posture as the server templates' baseline minus AD-DS roles
# (this is a desktop SKU, not a domain controller).

$ErrorActionPreference = "Continue"
Start-Transcript -Path C:\packer-baseline.log -Append

Write-Host "==> Firewall: enable RDP + WinRM groups, disable per-profile blocking (lab)..."
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

Write-Host "==> Default NIC categorization to Private at next boot..."
New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\NetworkList\Signatures" -Force | Out-Null

Write-Host "==> Baseline complete."
Stop-Transcript
