# =============================================================================
# windows-hardening.ps1 — shared Packer provisioner for every Windows image.
# =============================================================================
# Runs at IMAGE BAKE TIME (not deploy time). Bakes the following posture
# into every captured Windows image:
#
#   1. Guidem CWR desktop wallpaper, machine-wide, stretched.
#   2. Privacy / telemetry — fully off (DataCollection, ads, location,
#      Cortana, Find My Device, linguistic typing data, etc.).
#   3. DiagTrack + dmwappushservice services stopped + disabled.
#   4. Windows Defender sample submission FORCED OFF (SubmitSamplesConsent=
#      NeverSend on both policy + non-policy sides, SpynetReporting=0,
#      DisableBlockAtFirstSeen=1). Belt + suspenders even though
#      lab VMs have no internet egress in lockdown mode — if NSGs
#      ever drift open or AFD becomes a side channel, the OS itself
#      refuses to send samples.
#   5. OOBE privacy wizard suppressed; first interactive logon goes
#      straight to the desktop with the policy already applied.
#
# This is the EXACT same posture as
# modules/azure/ansible/roles/windows-base/tasks/main.yml — running both
# (image-baked AND ansible-applied) is intentional defense-in-depth:
# if an operator deploys against a stock Marketplace image (no bake),
# ansible fills in. If they deploy against a baked image, ansible
# re-applies idempotently and confirms nothing drifted at boot.
#
# Used by:
#   packer/win-server-2022/win-server-2022-ad.pkr.hcl
#   packer/win-server-2019/win-server-2019.pkr.hcl
#   packer/win-10/win-10.pkr.hcl
#   packer/win-11/win-11.pkr.hcl
# (and any future Windows template).
#
# Prereq: wallpaper file is staged at C:\ProgramData\CWR\wallpaper.png
# by a `file` provisioner BEFORE this script runs. See the template's
# build block for the exact ordering.

$ErrorActionPreference = "Continue"
Start-Transcript -Path C:\packer-hardening.log -Append

# ---- Helper: idempotent registry write ------------------------------------
# New-ItemProperty -Force replaces the value; we use New-Item to ensure
# the key path exists first (some keys aren't created on a stock image).
function Set-RegValue {
    param(
        [Parameter(Mandatory=$true)] [string] $Path,
        [Parameter(Mandatory=$true)] [string] $Name,
        [Parameter(Mandatory=$true)] $Value,
        [ValidateSet("DWord","String","ExpandString","Binary","MultiString","QWord")]
        [string] $Type = "DWord"
    )
    if (-not (Test-Path $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
}

# ============================================================================
# 1) Guidem CWR wallpaper — machine-wide via HKLM Policies\System
# ============================================================================
# The file provisioner in the packer template uploads
# desktop-wallpaper-CWR.png from packer/_shared/files/ into
# C:\ProgramData\CWR\wallpaper.png BEFORE this script runs. We just
# verify it's there and set the policy keys.
$wallpaperPath = "C:\ProgramData\CWR\wallpaper.png"
if (-not (Test-Path $wallpaperPath)) {
    Write-Warning "Wallpaper file missing at $wallpaperPath — the file provisioner in the packer template was supposed to stage it. Continuing with hardening; wallpaper policy will reference a non-existent file (operators can drop the file in via ansible later)."
}

Write-Host "==> [hardening] Wallpaper policy (HKLM Policies\System, stretched, no tile)"
Set-RegValue "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" "Wallpaper"       $wallpaperPath "String"
Set-RegValue "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" "WallpaperStyle"  "2"            "String"  # 2 = stretched
Set-RegValue "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" "TileWallpaper"   "0"            "String"

# ============================================================================
# 2) Privacy / telemetry — everything off
# ============================================================================
Write-Host "==> [hardening] Privacy + telemetry registry keys"

# Diagnostic data + telemetry (HKLM policy side)
Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection"        "AllowTelemetry" 0
Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent"          "DisableTailoredExperiencesWithDiagnosticData" 1

# Advertising info (both policy + non-policy sides — Windows reads
# whichever it likes depending on SKU)
Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo"       "DisabledByGroupPolicy" 1
Set-RegValue "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo" "Enabled" 0

# Find My Device + Location
Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\FindMyDevice"                  "AllowFindMyDevice" 0
Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors"    "DisableLocation"   1
Set-RegValue "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location" "Value" "Deny" "String"

# Cortana
Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search"        "AllowCortana" 0

# Linguistic / typing telemetry
Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\TextInput"             "AllowLinguisticDataCollection" 0

# ============================================================================
# 3) Stop + disable telemetry services
# ============================================================================
# Try/catch on each — on Server Core or certain trimmed SKUs these may
# not exist. We don't want a missing service to fail the bake.
Write-Host "==> [hardening] Stopping + disabling telemetry services"
foreach ($svc in @('DiagTrack', 'dmwappushservice')) {
    try {
        $s = Get-Service -Name $svc -ErrorAction Stop
        if ($s.Status -ne 'Stopped') {
            Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
        }
        Set-Service -Name $svc -StartupType Disabled -ErrorAction Stop
        Write-Host "  $svc → stopped + disabled"
    } catch {
        Write-Host "  $svc → not present on this SKU (skipping)"
    }
}

# ============================================================================
# 4) Windows Defender — sample submission FORCED OFF
# ============================================================================
# The user's threat model: lab VMs are normally air-gapped from
# the internet, but a misconfigured NSG or future AFD egress could
# become a side channel for Defender to upload samples. Disabling at
# the OS layer makes Windows REFUSE to send samples even if the
# network would allow it.
#
# Keys set:
#   SubmitSamplesConsent      = 2  (NeverSend; values: 0=always-ask,
#                                   1=send-safe, 2=never-send, 3=send-all)
#   SpynetReporting           = 0  (MAPS membership OFF)
#   DisableBlockAtFirstSeen   = 1  (no cloud-delivered first-seen blocking,
#                                   which is the path that uploads hashes)
# Both the policy side (HKLM\SOFTWARE\Policies\...) AND the runtime
# side (HKLM\SOFTWARE\Microsoft\...) get the same values — on some
# SKUs Defender reads one, on others the other.
Write-Host "==> [hardening] Defender sample submission forced OFF"
foreach ($parent in @(
    "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Spynet",
    "HKLM:\SOFTWARE\Microsoft\Windows Defender\Spynet"
)) {
    Set-RegValue $parent "SubmitSamplesConsent"     2  # NeverSend
    Set-RegValue $parent "SpynetReporting"          0
}
Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Spynet" "DisableBlockAtFirstSeen" 1

# ============================================================================
# 5) OOBE first-login suppression
# ============================================================================
# On a sysprepped image, first interactive logon would normally show
# the "Choose privacy settings" wizard. Pre-set every toggle to the
# most-private value AND tell Windows to skip the wizard altogether.
Write-Host "==> [hardening] OOBE privacy wizard suppressed"
Set-RegValue "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE" "DisablePrivacyExperience" 1
Set-RegValue "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE" "ProtectYourPC"            3

# ============================================================================
# Done.
# ============================================================================
Write-Host "==> [hardening] Done. Wallpaper + privacy + Defender baked into image."
Stop-Transcript
