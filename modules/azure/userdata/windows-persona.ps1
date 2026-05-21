# Windows persona wrapper.
# Runs as SYSTEM via the CustomScriptExtension. The base64-encoded
# persona script is decoded to disk, executed, and then cleanup wipes:
#   - the persona script file
#   - CSE log files (which contain the rendered command line, including
#     the EncodedCommand for this wrapper itself -- that decodes to this
#     full template, so leaving it would betray the build process)
#   - DSC/CSE plugin status files for this run
#
# Cleanup is narrow: anything the persona itself wrote (registered
# users, planted files, configured roles) is preserved.

$ErrorActionPreference = "Continue"
Start-Transcript -Path C:\persona-wrapper.log -Append

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

# 1. Optional baseline (matches windows-member): firewall, RDP on
Set-NetFirewallProfile -Profile Domain,Public,Private -Enabled False
Enable-NetFirewallRule -DisplayGroup "Remote Desktop"
Set-Service -Name TermService -StartupType Automatic
Start-Service TermService
Set-ItemProperty -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server" -Name fDenyTSConnections -Value 0

# ---- WinRM (so ansible-from-guac can reach this box for repair/wallpaper) ----
# HTTP on 5985 with basic auth + AllowUnencrypted. Lab-tier — the
# WinRM listener is gated by the spoke NSG's from-hub rule (only
# guacamole subnet can reach it). HTTPS-over-5986 is a future
# hardening pass. Mirrors windows-blank.ps1 / windows-analyst.ps1 /
# windows-member.ps1.
winrm quickconfig -force -quiet
winrm set winrm/config/service '@{AllowUnencrypted="true"}'
winrm set winrm/config/service/auth '@{Basic="true"}'
winrm set winrm/config/client/auth '@{Basic="true"}'
winrm set winrm/config/listener?Address=*+Transport=HTTP '@{Port="5985"}'

# 2. Optional domain join -- done before persona so persona can use AD context
if ("${do_domain_join}" -eq "True") {
    $domain = "${domain_fqdn}"
    $dcIp   = "${dc_ip}"
    $cred   = New-Object System.Management.Automation.PSCredential(
        "${domain_user}",
        (ConvertTo-SecureString "${domain_pass}" -AsPlainText -Force))
    # Point NIC at DC for DNS before resolving AD SRV records -- Azure's
    # default resolver (168.63.129.16) can't see internal AD zones.
    # Per-adapter try/catch: some NICs don't expose
    # MSFT_DNSClientServerAddress mid-init; ignore those, succeed on
    # whichever ones do.
    try {
        Get-NetIPConfiguration -ErrorAction SilentlyContinue |
            Where-Object { $_.NetAdapter.Status -eq 'Up' -and $_.IPv4Address } |
            ForEach-Object {
                try {
                    Set-DnsClientServerAddress -InterfaceIndex $_.InterfaceIndex -ServerAddresses $dcIp -ErrorAction Stop
                } catch { Write-Warning "DNS set on ifIndex $($_.InterfaceIndex) failed: $_" }
            }
        Clear-DnsClientCache -ErrorAction SilentlyContinue
    } catch { Write-Warning "DNS server set failed: $_" }
    $tries = 0
    while ($tries -lt 60) {
        try {
            Resolve-DnsName -Type SRV "_ldap._tcp.dc._msdcs.$domain" -ErrorAction Stop | Out-Null
            break
        } catch { Start-Sleep -Seconds 30; $tries++ }
    }
    try {
        Add-Computer -DomainName $domain -Credential $cred -Force
        # Don't reboot here -- persona may want to run pre-reboot. The
        # persona is responsible for triggering a reboot if needed.
    } catch { Write-Warning "domain join failed: $_" }
}

# 3. Decode and run the persona
$personaB64 = "${persona_b64}"
$personaPath = "C:\persona.ps1"
[System.IO.File]::WriteAllBytes(
    $personaPath,
    [Convert]::FromBase64String($personaB64))

try {
    & powershell.exe -ExecutionPolicy Bypass -NoProfile -File $personaPath *> C:\persona-build.log 2>&1
} catch {
    Write-Warning "persona script errored: $_"
}

# 4. Cleanup -- narrow, only build artefacts
function Remove-If-Exists { param($p) if (Test-Path $p) { Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue } }

Remove-If-Exists $personaPath
Remove-If-Exists "C:\persona-build.log"
Remove-If-Exists "C:\persona-wrapper.log"

# CSE writes plugin logs to:
#   C:\WindowsAzure\Logs\Plugins\Microsoft.Compute.CustomScriptExtension\<ver>\
#   C:\Packages\Plugins\Microsoft.Compute.CustomScriptExtension\<ver>\Status\
# The Status JSON contains the literal commandToExecute, which is our
# EncodedCommand. Truncate them.
Get-ChildItem "C:\WindowsAzure\Logs\Plugins\Microsoft.Compute.CustomScriptExtension" -Recurse -ErrorAction SilentlyContinue |
    ForEach-Object { Clear-Content $_.FullName -ErrorAction SilentlyContinue }
Get-ChildItem "C:\Packages\Plugins\Microsoft.Compute.CustomScriptExtension" -Recurse -Filter "*.status" -ErrorAction SilentlyContinue |
    ForEach-Object { Clear-Content $_.FullName -ErrorAction SilentlyContinue }

# Clear the local Administrator's Run history (in case persona used Run dialog macros)
Remove-If-Exists "$env:USERPROFILE\AppData\Roaming\Microsoft\Windows\PowerShell\PSReadLine\ConsoleHost_history.txt"

Stop-Transcript -ErrorAction SilentlyContinue
