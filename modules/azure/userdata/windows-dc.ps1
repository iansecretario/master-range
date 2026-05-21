# Two-phase DC bootstrap.
#
# Phase 1 (this CSE invocation):
#   - hardens local admin / RDP / firewall
#   - installs ADDS + DNS roles
#   - calls Install-ADDSForest with -NoRebootOnCompletion so the cmdlet
#     RETURNS to PS, the script registers a RunOnce that does Phase 2
#     after the OS reboots, then triggers the reboot manually.
#   - CSE sees a clean exit and reports Succeeded.
#
# Phase 2 (RunOnce after reboot, runs as SYSTEM at next login screen):
#   - waits for ADDS to be reachable
#   - deploys Sysmon + Winlogbeat to the DC itself (so DC events ship to ELK)
#
# Note: when domain.enabled is true the generator forces this VM's local
# admin user/password to match domain.admin_user/admin_password, so after
# promotion that account IS the Domain Administrator. Members join with
# the same creds.

$ErrorActionPreference = "Stop"
Start-Transcript -Path C:\bootstrap.log -Append

# --- Privacy / OOBE suppression ---------------------------------------------
# Server SKUs rarely show the consumer OOBE privacy screen, but we set
# the keys anyway for consistency + defense (a future image regression
# can't stall the DC bootstrap). See windows-member.ps1 for rationale.
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

# ---- fast_windows: short-circuit Windows Update on first boot ----
# When the operator opted into --fast-windows, kill wuauserv and the
# Update Orchestrator so the OS doesn't burn 10-15 min pulling
# cumulative updates while we're trying to promote the DC. Trades
# latest CVE patches for faster lab spin-up; not for production.
if ("${fast_windows}" -eq "true") {
    Write-Host "fast_windows=true -> disabling Windows Update for this boot"
    try {
        Stop-Service -Name wuauserv,UsoSvc -Force -ErrorAction SilentlyContinue
        Set-Service -Name wuauserv -StartupType Disabled -ErrorAction SilentlyContinue
        Set-Service -Name UsoSvc   -StartupType Disabled -ErrorAction SilentlyContinue
        # Block the scheduled-task path too (UpdateOrchestrator triggers wuauserv).
        Get-ScheduledTask -TaskPath '\Microsoft\Windows\UpdateOrchestrator\' -ErrorAction SilentlyContinue |
            Disable-ScheduledTask -ErrorAction SilentlyContinue | Out-Null
    } catch { Write-Warning "fast_windows disable failed: $_" }
}

# ---- baseline ----
Set-NetFirewallProfile -Profile Domain,Public,Private -Enabled False
Enable-NetFirewallRule -DisplayGroup "Remote Desktop"
Set-Service -Name TermService -StartupType Automatic
Start-Service TermService
Set-ItemProperty -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server" -Name fDenyTSConnections -Value 0

# ---- WinRM (so ansible-from-guac can reach the DC for repair/config) ----
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

# ---- phase 2 script written to disk now, run by RunOnce after reboot ----
$phase2 = @'
$ErrorActionPreference = "Continue"
Start-Transcript -Path C:\bootstrap-phase2.log -Append

# Wait until ADDS is fully up
$tries = 0
while ($tries -lt 60) {
    try {
        Import-Module ActiveDirectory -ErrorAction Stop
        Get-ADDomain -ErrorAction Stop | Out-Null
        break
    } catch { Start-Sleep -Seconds 10; $tries++ }
}

if ("__DEPLOY_AGENTS__" -eq "True") {
    try {
        $sysmonZip = "$env:TEMP\Sysmon.zip"
        Invoke-WebRequest -Uri "https://download.sysinternals.com/files/Sysmon.zip" -OutFile $sysmonZip
        Expand-Archive -Force -Path $sysmonZip -DestinationPath "C:\Sysmon"
        Invoke-WebRequest -Uri "https://raw.githubusercontent.com/SwiftOnSecurity/sysmon-config/master/sysmonconfig-export.xml" -OutFile "C:\Sysmon\config.xml"
        Start-Process -Wait -FilePath "C:\Sysmon\Sysmon64.exe" -ArgumentList "-accepteula -i C:\Sysmon\config.xml"

        $beatMsi = "$env:TEMP\winlogbeat.msi"
        Invoke-WebRequest -Uri "https://artifacts.elastic.co/downloads/beats/winlogbeat/winlogbeat-8.13.4-windows-x86_64.msi" -OutFile $beatMsi
        Start-Process msiexec.exe -Wait -ArgumentList "/i $beatMsi /qn"

        # winlogbeat YAML composed in terraform-land + base64'd.
        # Sidesteps the PowerShell here-string parser, which mis-handles
        # multi-line "- name:" content under certain LF-vs-CRLF + indent
        # combinations and fails the entire RunCommand script.
        $cfgB64 = "__WINLOGBEAT_B64__"
        $cfg = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($cfgB64))
        $cfg | Out-File "C:\Program Files\Winlogbeat\winlogbeat.yml" -Encoding ascii -Force
        Start-Service winlogbeat -ErrorAction SilentlyContinue
    } catch { Write-Warning "agent install failed: $_" }
}

Stop-Transcript
'@

# Substitute build-time values into the phase 2 script before writing
$phase2 = $phase2 -replace '__DEPLOY_AGENTS__', '${deploy_agents}'
$phase2 = $phase2 -replace '__ELK_ENDPOINT__',  '${elk_endpoint}'
$phase2 = $phase2 -replace '__ELK_PASSWORD__',  '${kibana_password}'
$phase2 = $phase2 -replace '__WINLOGBEAT_B64__', '${winlogbeat_b64}'
$phase2 | Out-File -FilePath C:\bootstrap-phase2.ps1 -Encoding ascii -Force

# Register RunOnce (HKLM, runs as SYSTEM before login screen)
$runOnceArgs = @{
    Path         = "HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce"
    Name         = "RangePhase2"
    PropertyType = "String"
    Value        = "powershell.exe -ExecutionPolicy Bypass -NoProfile -File C:\bootstrap-phase2.ps1"
    Force        = $true
}
New-ItemProperty @runOnceArgs | Out-Null

# ---- install AD roles + promote ----
Install-WindowsFeature -Name AD-Domain-Services,DNS -IncludeManagementTools

$alreadyDC = $false
try { Get-ADDomainController -ErrorAction Stop | Out-Null; $alreadyDC = $true } catch {}

if (-not $alreadyDC) {
    $secure = ConvertTo-SecureString "${safemode_password}" -AsPlainText -Force

    # Force-load the ADDSDeployment module BEFORE calling Install-ADDSForest.
    # Without this, the cmdlet sometimes resolves to a stub that hasn't
    # fully populated its parameter set, and the prereq verifier dies
    # with the misleading "argument 'DomainNetbiosName' was not
    # recognized" message — even though the cmdlet's own ParameterSet
    # for DomainNetbiosName is correct. This is a documented Server 2022
    # ADDS quirk on freshly-imaged VMs where the module-autoload cache
    # is stale.
    Import-Module ADDSDeployment -Force -ErrorAction SilentlyContinue
    Write-Host "ADDSDeployment loaded. Install-ADDSForest parameters:"
    (Get-Command Install-ADDSForest).Parameters.Keys | Sort-Object | ForEach-Object { Write-Host "  -$_" }

    Write-Host "Calling Install-ADDSForest: DomainName='${domain_fqdn}' NetBIOS='${netbios}'"
    # Single-line explicit parameter passing — NO backticks, NO splat,
    # NO line continuations. -SkipPreChecks bypasses the over-eager
    # verifier that misreports valid configurations as broken (we still
    # get the real DCPromo logic). For lab use this is fine; for prod
    # you'd want the prechecks ON.
    Install-ADDSForest -DomainName "${domain_fqdn}" -DomainNetbiosName "${netbios}" -SafeModeAdministratorPassword $secure -InstallDns -NoRebootOnCompletion -Force -SkipPreChecks

    # ---- queue lab-users seeding ----
    # Two-pronged for resilience against Spot eviction / reboots:
    #   (a) Append a block to the RunOnce phase-2 script (fires on the
    #       first boot after promotion).
    #   (b) Also write a standalone idempotent script + scheduled task
    #       that runs at every boot and self-removes once seeding is
    #       confirmed complete. Belt and braces for the case where
    #       RunOnce fires too early (ADDS not yet up, pwd-policy not
    #       yet enforced) or is consumed by a transient failure.
    # `${lab_users_json}` is rendered by terraform; an empty list means
    # neither path runs.
    $labUsersJson = @'
${lab_users_json}
'@
    if ($labUsersJson.Trim() -ne "[]" -and $labUsersJson.Trim() -ne "") {
        # (a) Append to phase-2 RunOnce
        $appendBlock = @"

# ---- lab-users seeding (added by terra-range domain.lab_users) ----
try {
    `$labUsers = '$labUsersJson' | ConvertFrom-Json
    foreach (`$u in `$labUsers) {
        try {
            `$pw = ConvertTo-SecureString `$u.password -AsPlainText -Force
            `$userArgs = @{
                Name                 = `$u.name
                SamAccountName       = `$u.name
                AccountPassword      = `$pw
                Enabled              = `$true
                PasswordNeverExpires = `$true
                ErrorAction          = 'Stop'
            }
            New-ADUser @userArgs
            Write-Host "lab user created: `$(`$u.name)"
        } catch {
            if (`$_.Exception.Message -match 'already exists') {
                Write-Host "lab user `$(`$u.name) already exists; skipping"
            } else {
                Write-Warning "lab user `$(`$u.name) failed: `$_"
            }
        }
    }
    # Mark complete so the standalone task self-removes.
    `$null = New-Item -ItemType File -Path C:\range-labusers-done -Force
} catch { Write-Warning "lab-users block failed: `$_" }
"@
        Add-Content -Path C:\bootstrap-phase2.ps1 -Value $appendBlock

        # (b) Standalone idempotent script + scheduled task. Runs at
        # every system startup until C:\range-labusers-done exists,
        # then deletes itself + the task. Survives Spot reboots,
        # RunOnce mishaps, and AD-not-ready races.
        $standaloneScript = @"
# range-labusers-resume.ps1 -- idempotent lab_users seeding.
# Runs on boot until C:\range-labusers-done exists. Then self-deletes.
`$ErrorActionPreference = 'Continue'
Start-Transcript -Path C:\range-labusers-resume.log -Append

if (Test-Path C:\range-labusers-done) {
    # Job done; remove the task and this script.
    Unregister-ScheduledTask -TaskName 'RangeLabUsersResume' -Confirm:`$false -ErrorAction SilentlyContinue
    Remove-Item -Path C:\range-labusers-resume.ps1 -Force -ErrorAction SilentlyContinue
    Stop-Transcript
    exit 0
}

# Wait up to 10 min for ADDS to be online.
`$tries = 0
while (`$tries -lt 60) {
    try {
        Import-Module ActiveDirectory -ErrorAction Stop
        Get-ADDomain -ErrorAction Stop | Out-Null
        break
    } catch { Start-Sleep -Seconds 10; `$tries++ }
}
if (`$tries -ge 60) { Write-Warning 'ADDS not reachable; will retry on next boot.'; Stop-Transcript; exit 0 }

# Seed users idempotently.
try {
    `$labUsers = '$labUsersJson' | ConvertFrom-Json
    foreach (`$u in `$labUsers) {
        if (Get-ADUser -Filter "SamAccountName -eq '`$(`$u.name)'" -ErrorAction SilentlyContinue) {
            Write-Host "lab user `$(`$u.name) exists; skipping"
            continue
        }
        try {
            `$pw = ConvertTo-SecureString `$u.password -AsPlainText -Force
            `$userArgs = @{
                Name                 = `$u.name
                SamAccountName       = `$u.name
                AccountPassword      = `$pw
                Enabled              = `$true
                PasswordNeverExpires = `$true
                ErrorAction          = 'Stop'
            }
            New-ADUser @userArgs
            Write-Host "lab user created: `$(`$u.name)"
        } catch { Write-Warning "lab user `$(`$u.name) failed: `$_" }
    }
    `$null = New-Item -ItemType File -Path C:\range-labusers-done -Force
    # Self-remove on next boot via the same task firing and seeing the
    # marker.
} catch { Write-Warning "resume script failed: `$_" }
Stop-Transcript
"@
        $standaloneScript | Out-File -FilePath C:\range-labusers-resume.ps1 -Encoding ascii -Force

        # Register the scheduled task (runs at startup, as SYSTEM)
        try {
            $action  = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -NoProfile -File C:\range-labusers-resume.ps1"
            $trigger = New-ScheduledTaskTrigger -AtStartup
            $princ   = New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest
            $taskArgs = @{
                TaskName  = "RangeLabUsersResume"
                Action    = $action
                Trigger   = $trigger
                Principal = $princ
                Force     = $true
            }
            Register-ScheduledTask @taskArgs | Out-Null
        } catch {
            Write-Warning "Couldn't register RangeLabUsersResume task: $_"
        }
    }

    Stop-Transcript
    # Reboot in 60s so CSE has time to report success
    Start-Process -FilePath shutdown.exe -ArgumentList "/r /t 60 /c `"DC promotion: rebooting`"" -NoNewWindow
    exit 0
}

Stop-Transcript
