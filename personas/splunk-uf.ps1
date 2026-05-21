# Persona: splunk-uf
# Theme   : Splunk Universal Forwarder + Sysmon for a Windows box that
#           reports into a paired splunk-server persona elsewhere in
#           the range.
# Target  : windows-member or windows-workstation
# Pair    : Linux box with persona=splunk-server (typically at the hub)
#
# The forwarder ships Application/System/Security/Sysmon-Operational to
# the configured Splunk indexer. Host of the indexer is hard-coded
# below — adjust the SplunkHost variable to match your scenario.

$ErrorActionPreference = "Continue"
Start-Transcript -Path C:\splunkuf-persona.log -Append

# Default to hub-tier infra subnet IPs (10.0.1.0/24). Change to match
# wherever your splunk-server persona lands.
$SplunkHost     = "10.0.1.20"
$SplunkPort     = 9997
$SplunkPassword = "Sp1unk!Lab2025"

# 1. Sysmon (SwiftOnSecurity config — known-good baseline)
try {
    $sysmonZip = "$env:TEMP\Sysmon.zip"
    Invoke-WebRequest -Uri "https://download.sysinternals.com/files/Sysmon.zip" -OutFile $sysmonZip
    Expand-Archive -Force -Path $sysmonZip -DestinationPath "C:\Sysmon"
    Invoke-WebRequest -Uri "https://raw.githubusercontent.com/SwiftOnSecurity/sysmon-config/master/sysmonconfig-export.xml" -OutFile "C:\Sysmon\config.xml"
    Start-Process -Wait -FilePath "C:\Sysmon\Sysmon64.exe" -ArgumentList "-accepteula -i C:\Sysmon\config.xml"
} catch { Write-Warning "Sysmon install failed: $_" }

# 2. Universal Forwarder
try {
    $ufVer    = "9.3.2"
    $ufBuild  = "d8bb32809498"
    $ufMsi    = "$env:TEMP\splunkforwarder.msi"
    $ufUrl    = "https://download.splunk.com/products/universalforwarder/releases/$ufVer/windows/splunkforwarder-$ufVer-$ufBuild-windows-x64.msi"
    Invoke-WebRequest -Uri $ufUrl -OutFile $ufMsi
    Start-Process msiexec.exe -Wait -ArgumentList @(
        "/i", $ufMsi,
        "AGREETOLICENSE=Yes",
        "RECEIVING_INDEXER=$SplunkHost`:$SplunkPort",
        "SPLUNKUSERNAME=admin",
        "SPLUNKPASSWORD=$SplunkPassword",
        "/qn"
    )
} catch { Write-Warning "UF install failed: $_" }

# 3. Inputs — what to send
$ufHome = "C:\Program Files\SplunkUniversalForwarder"
$inputs = @"
[default]
host = $env:COMPUTERNAME

[WinEventLog://Application]
disabled = 0
index = wineventlog

[WinEventLog://System]
disabled = 0
index = wineventlog

[WinEventLog://Security]
disabled = 0
index = wineventlog

[WinEventLog://Microsoft-Windows-Sysmon/Operational]
disabled = 0
index = sysmon
renderXml = true
"@
$inputsPath = Join-Path $ufHome "etc\system\local\inputs.conf"
New-Item -Path (Split-Path $inputsPath) -ItemType Directory -Force | Out-Null
$inputs | Out-File $inputsPath -Encoding ascii -Force

# 4. Restart UF to apply
Restart-Service SplunkForwarder -Force -ErrorAction SilentlyContinue

Stop-Transcript -ErrorAction SilentlyContinue
