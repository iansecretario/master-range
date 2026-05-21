# =============================================================================
# Windows 10 analyst VM — FLARE-VM bootstrap.
# =============================================================================
# Installs Mandiant's FLARE-VM curated malware-analysis / reverse-engineering
# toolset (https://github.com/mandiant/flare-vm) on a fresh Windows 10 box.
#
# Install timeline (rough):
#   T+0       this script writes itself to C:\flare-bootstrap\ and exits.
#             Cloud-init / Azure CSE returns success quickly.
#   T+5 min   first scheduled run kicks off; Defender disabled, dependencies
#             pulled (Boxstarter, Chocolatey). VM reboots.
#   T+20-90m  Boxstarter installs ~150 packages, rebooting between phases.
#   T+90m-2h  fully installed; FLARE-VM background wallpaper visible.
#
# Disk requirements: 100 GB MIN, 200+ GB recommended (some packages — Ghidra,
# IDA-free, big symbol caches — eat 30-50 GB combined). We provision the
# VM at 256 GB by default in vms.tf.
#
# Memory: 4 GB MIN, 16 GB recommended. The default vm_size for this role is
# Standard_D4s_v5 (4 vCPU / 16 GB) — see images.tf.
#
# Network access: this VM sits in the per-student attacker subnet alongside
# Kali, so its NSG rules are identical (intra-vnet allow, from-hub allow,
# operator SSH allow). That gives it reach to every other student VM
# plus the hub (RedELK / Ghostwriter / etc) over peering.
# =============================================================================
$ErrorActionPreference = "Continue"
Start-Transcript -Path C:\bootstrap.log -Append

# --- Privacy / OOBE suppression ---------------------------------------------
# Skip the OOBE "Choose privacy settings" screen + pre-set every privacy
# toggle to its most-private value. See windows-member.ps1 for the full
# rationale. Idempotent; harmless to re-run.
function Set-RegValue($Path, $Name, $Value, $Type = "DWord") {
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
}
try {
    Set-RegValue "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE" "DisablePrivacyExperience" 1
    Set-RegValue "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE" "ProtectYourPC" 3
    Set-RegValue "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location" "Value" "Deny" "String"
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors" "DisableLocation" 1
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\FindMyDevice" "AllowFindMyDevice" 0
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" "AllowTelemetry" 0
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\TextInput" "AllowLinguisticDataCollection" 0
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent" "DisableTailoredExperiencesWithDiagnosticData" 1
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo" "DisabledByGroupPolicy" 1
    Set-RegValue "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo" "Enabled" 0
    Write-Output "privacy + OOBE suppression applied"
} catch { Write-Warning "privacy/OOBE suppression failed: $_" }

# ---- Local admin --------------------------------------------------------
$user = "${local_admin}"
$pass = ConvertTo-SecureString "${local_password}" -AsPlainText -Force
if (-not (Get-LocalUser -Name $user -ErrorAction SilentlyContinue)) {
    New-LocalUser -Name $user -Password $pass -PasswordNeverExpires -AccountNeverExpires
}
Add-LocalGroupMember -Group "Administrators" -Member $user -ErrorAction SilentlyContinue

# ---- Firewall + RDP + WinRM (for ansible repair access later) ----------
Set-NetFirewallProfile -Profile Domain,Public,Private -Enabled False
Enable-NetFirewallRule -DisplayGroup "Remote Desktop"
Set-Service -Name TermService -StartupType Automatic
Start-Service TermService
Set-ItemProperty -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server" -Name fDenyTSConnections -Value 0

winrm quickconfig -force -quiet
winrm set winrm/config/service '@{AllowUnencrypted="true"}'
winrm set winrm/config/service/auth '@{Basic="true"}'
winrm set winrm/config/client/auth '@{Basic="true"}'
winrm set winrm/config/listener?Address=*+Transport=HTTP '@{Port="5985"}'
Set-Service -Name WinRM -StartupType Automatic
Start-Service WinRM
New-NetFirewallRule -DisplayName "WinRM HTTP" -Direction Inbound -LocalPort 5985 -Protocol TCP -Action Allow -ErrorAction SilentlyContinue

# ---- Stage the FLARE-VM install script ---------------------------------
# We DON'T run install.ps1 inline from Azure RunCommand because:
#   1. Boxstarter reboots multiple times. Azure RunCommand expects the
#      script to complete in a single session; a mid-run reboot causes
#      timeout + "extension execution failed".
#   2. The install must run as the LOGGED-IN user (Boxstarter auto-logon),
#      not as SYSTEM (which is what RunCommand provides).
#
# Instead, drop the launcher to disk and register a "RunOnce" entry that
# fires on first interactive logon. The operator (or Guacamole's RDP
# auto-login) triggers the install.
$flareDir = "C:\flare-bootstrap"
New-Item -ItemType Directory -Force -Path $flareDir | Out-Null

# Disable Defender's real-time protection BEFORE install — FLARE-VM
# requires it OFF or many tools (mimikatz, RATs, packers) get quarantined
# mid-install and the package install fails.
try {
  Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction SilentlyContinue
  Set-MpPreference -DisableScriptScanning   $true -ErrorAction SilentlyContinue
  Set-MpPreference -DisableBehaviorMonitoring $true -ErrorAction SilentlyContinue
} catch {
  Write-Host "[!] could not disable Defender via PowerShell (tamper protection?); the FLARE installer will retry."
}

# Launcher script — kicks off FLARE-VM unattended. Operator just needs
# to RDP in once to trigger this on first logon.
@"
# FLARE-VM unattended installer launcher.
# Generated by terra-range cloud-init.
`$ErrorActionPreference = 'Continue'
Start-Transcript -Path C:\flare-bootstrap\install.log -Append

# Pull the official installer
`$installer = 'C:\flare-bootstrap\install.ps1'
if (-not (Test-Path `$installer)) {
  Invoke-WebRequest -UseBasicParsing `
    -Uri 'https://raw.githubusercontent.com/mandiant/flare-vm/main/install.ps1' `
    -OutFile `$installer
}

# Run it non-interactively:
#   -password    avoid the prompt; the FLARE installer needs the user
#                password to re-authenticate Boxstarter auto-logon across
#                reboots.
#   -noWait      don't prompt the operator before starting
#   -noGui       no GUI installer chooser; install everything
#   -noChecks    skip the disk / RAM / OS sanity checks (we know our
#                VM meets the minimums)
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Unrestricted -Force
& `$installer -password '${local_password}' -noWait -noGui -noChecks
Stop-Transcript
"@ | Out-File -FilePath "$flareDir\run-flare-install.ps1" -Encoding ASCII -Force

# Register the launcher under HKLM RunOnce so it fires on the next
# interactive logon AS THE ADMIN USER. RunOnce ⇒ runs exactly once
# unless renamed; this matches Boxstarter's reboot semantics.
$runOnceKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce"
New-ItemProperty -Path $runOnceKey -Name "FLARE-VM-Install" `
  -Value "powershell.exe -ExecutionPolicy Bypass -NoProfile -File C:\flare-bootstrap\run-flare-install.ps1" `
  -PropertyType String -Force | Out-Null

# Drop a desktop README so the operator knows the install is queued.
$readme = @"
FLARE-VM install is queued and will start automatically on first RDP login.

Expected timeline:
  - First 5 min   : dependencies install (Chocolatey + Boxstarter)
  - 20-90 min     : ~150 tools install, reboots happen automatically
  - 90 min - 2 hr : final tools + wallpaper change

Log: C:\flare-bootstrap\install.log
Original installer: https://github.com/mandiant/flare-vm

Customize package selection via:
  C:\flare-bootstrap\run-flare-install.ps1
"@
$readme | Out-File "C:\Users\Public\Desktop\FLARE-VM-README.txt" -Encoding ASCII -Force

Write-Host "[+] FLARE-VM bootstrap scheduled. RDP into this VM to trigger the install."
Stop-Transcript
