# windows-blank bootstrap.
# Bare Windows server. No domain promotion, no domain join, no agents.
# Just: local admin password, RDP, firewall off, WinRM HTTP enabled
# (for ansible / external orchestration). Used as the substrate for
# GOAD-style scenarios where the cross-VM configuration is delivered
# by upstream ansible playbooks instead of CSE.

$ErrorActionPreference = "Continue"
Start-Transcript -Path C:\bootstrap.log -Append

# --- Privacy / OOBE suppression ---------------------------------------------
# Skip the OOBE "Choose privacy settings" screen + pre-set every privacy
# toggle to its most-private value. See windows-member.ps1 for rationale.
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

# Local admin
$user = "${local_admin}"
$pass = ConvertTo-SecureString "${local_password}" -AsPlainText -Force
if (-not (Get-LocalUser -Name $user -ErrorAction SilentlyContinue)) {
    New-LocalUser -Name $user -Password $pass -PasswordNeverExpires -AccountNeverExpires
}
Add-LocalGroupMember -Group "Administrators" -Member $user -ErrorAction SilentlyContinue

# Firewall + RDP
Set-NetFirewallProfile -Profile Domain,Public,Private -Enabled False
Enable-NetFirewallRule -DisplayGroup "Remote Desktop"
Set-Service -Name TermService -StartupType Automatic
Start-Service TermService
Set-ItemProperty -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server" -Name fDenyTSConnections -Value 0

# WinRM over HTTP for ansible (lab only -- basic auth + unencrypted).
# In a production AD environment you'd use HTTPS/Kerberos; here we
# need ansible to reach the box BEFORE the domain exists.
winrm quickconfig -force -quiet
winrm set winrm/config/service '@{AllowUnencrypted="true"}'
winrm set winrm/config/service/auth '@{Basic="true"}'
winrm set winrm/config/client/auth '@{Basic="true"}'
winrm set winrm/config/listener?Address=*+Transport=HTTP '@{Port="5985"}'

# Make sure the WinRM service is running and starts at boot
Set-Service -Name WinRM -StartupType Automatic
Start-Service WinRM

# Allow inbound 5985 (already open due to firewall-off, but be explicit)
New-NetFirewallRule -DisplayName "WinRM HTTP" -Direction Inbound -LocalPort 5985 -Protocol TCP -Action Allow -ErrorAction SilentlyContinue

# Disable Windows Update for the lab (otherwise ansible promotion can
# race with WU triggering reboots). Re-enable manually when you're done.
Set-Service -Name wuauserv -StartupType Disabled
Stop-Service -Name wuauserv -ErrorAction SilentlyContinue

Stop-Transcript
