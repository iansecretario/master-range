$ErrorActionPreference = "Stop"
Start-Transcript -Path C:\bootstrap.log -Append

# --- Privacy / OOBE suppression ---------------------------------------------
# Fresh Windows client VMs (Win10/Win11) can stall at the OOBE
# "Choose privacy settings for your device" screen, waiting for a human
# to click Accept — which blocks the operator (we hit this on ws11).
# DisablePrivacyExperience=1 makes OOBE skip that page entirely; the
# rest of the keys pre-set every privacy toggle to its most-private
# value so even if the page somehow renders, the answers are already
# "No". Idempotent — safe to re-run, harmless on Server SKUs.
# NOTE: this runs from the RunCommand bootstrap, which fires once the
# VM agent is up. If a future image regresses such that OOBE blocks
# the agent ENTIRELY, the durable fix is an autounattend.xml <OOBE>
# block in VM provisioning — bigger change, tracked separately.
function Set-RegValue($Path, $Name, $Value, $Type = "DWord") {
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
}
try {
    # Skip the OOBE privacy-experience page outright.
    Set-RegValue "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE" "DisablePrivacyExperience" 1
    Set-RegValue "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE" "ProtectYourPC" 3
    # Location -> Deny
    Set-RegValue "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location" "Value" "Deny" "String"
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors" "DisableLocation" 1
    # Find my device -> off
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\FindMyDevice" "AllowFindMyDevice" 0
    # Diagnostic data -> minimal (0 = Security/Required-only)
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" "AllowTelemetry" 0
    # Inking & typing -> off
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\TextInput" "AllowLinguisticDataCollection" 0
    # Tailored experiences -> off
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent" "DisableTailoredExperiencesWithDiagnosticData" 1
    # Advertising ID -> off
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo" "DisabledByGroupPolicy" 1
    Set-RegValue "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo" "Enabled" 0
    Write-Output "privacy + OOBE suppression applied"
} catch { Write-Warning "privacy/OOBE suppression failed: $_" }

# --- local admin baseline ---
$user = "${local_admin}"
$pass = ConvertTo-SecureString "${local_password}" -AsPlainText -Force
if (-not (Get-LocalUser -Name $user -ErrorAction SilentlyContinue)) {
    New-LocalUser -Name $user -Password $pass -PasswordNeverExpires -AccountNeverExpires
}
Add-LocalGroupMember -Group "Administrators" -Member $user -ErrorAction SilentlyContinue

# --- firewall + RDP ---
Set-NetFirewallProfile -Profile Domain,Public,Private -Enabled False
Enable-NetFirewallRule -DisplayGroup "Remote Desktop"
Set-Service -Name TermService -StartupType Automatic
Start-Service TermService
Set-ItemProperty -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server" -Name fDenyTSConnections -Value 0

# --- WinRM (so ansible / DSC / remote PowerShell can reach this box) ---
# Force network profile to Private FIRST so the WinRM firewall rules
# can apply. Azure's default first-boot profile is "Public", which
# blocks Enable-PSRemoting's firewall opening with WSManFault.
try {
    Get-NetConnectionProfile -ErrorAction SilentlyContinue | ForEach-Object {
        Set-NetConnectionProfile -InterfaceIndex $_.InterfaceIndex -NetworkCategory Private -ErrorAction SilentlyContinue
    }
} catch { Write-Warning "network-profile set failed: $_" }
# Now enable PSRemoting. -SkipNetworkProfileCheck handles the Public
# case if the above didn't take. We DON'T call `winrm quickconfig` or
# `winrm set ... NTLM=true` because:
#   - quickconfig duplicates what Enable-PSRemoting does AND fails hard
#     on Public-classified NICs (no skip flag).
#   - NTLM isn't a valid key on winrm/config/service/auth -- newer
#     Windows rejects it as "Parameter name does not match any
#     properties on resource: NTLM" (NTLM is enabled via Negotiate).
try {
    Enable-PSRemoting -Force -SkipNetworkProfileCheck -ErrorAction SilentlyContinue
    Set-Item WSMan:\localhost\Service\AllowUnencrypted $true -Force -ErrorAction SilentlyContinue
    Set-Item WSMan:\localhost\Service\Auth\Basic       $true -Force -ErrorAction SilentlyContinue
    Set-Item WSMan:\localhost\Shell\MaxMemoryPerShellMB 1024 -Force -ErrorAction SilentlyContinue
    Enable-NetFirewallRule -DisplayGroup "Windows Remote Management" -ErrorAction SilentlyContinue
    Set-Service WinRM -StartupType Automatic
} catch { Write-Warning "WinRM setup: $_" }

# --- domain join ---
if ("${do_domain_join}" -eq "True") {
    $domain = "${domain_fqdn}"
    $duser  = "${domain_user}"
    $dpass  = ConvertTo-SecureString "${domain_pass}" -AsPlainText -Force
    $dcIp   = "${dc_ip}"
    $cred   = New-Object System.Management.Automation.PSCredential($duser, $dpass)

    # Point this member at the DC for DNS BEFORE attempting to resolve
    # the AD SRV records. Without this, the box uses Azure's default
    # recursive resolver (168.63.129.16) which has no knowledge of the
    # internal AD zone (e.g. corp.local) and Resolve-DnsName always
    # times out -> silent join failure after 30 min of polling.
    #
    # Per-adapter try/catch: some adapters (especially synthetic NICs
    # mid-init) don't expose MSFT_DNSClientServerAddress yet; logging
    # a warning is fine as long as at least one adapter took the DNS.
    try {
        $adapters = Get-NetIPConfiguration -ErrorAction SilentlyContinue |
            Where-Object { $_.NetAdapter.Status -eq 'Up' -and $_.IPv4Address }
        $setCount = 0
        foreach ($a in $adapters) {
            try {
                Set-DnsClientServerAddress -InterfaceIndex $a.InterfaceIndex -ServerAddresses $dcIp -ErrorAction Stop
                $setCount++
                Write-Host "DNS server set on ifIndex $($a.InterfaceIndex) ($($a.InterfaceAlias)) -> $dcIp"
            } catch {
                Write-Warning "DNS server set on ifIndex $($a.InterfaceIndex) failed: $_"
            }
        }
        if ($setCount -eq 0) {
            # Fallback: try every Up adapter regardless of IP state.
            Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object Status -eq 'Up' | ForEach-Object {
                try { Set-DnsClientServerAddress -InterfaceIndex $_.ifIndex -ServerAddresses $dcIp -ErrorAction Stop; $setCount++ } catch {}
            }
        }
        Clear-DnsClientCache -ErrorAction SilentlyContinue
        Write-Host "DNS configured on $setCount adapter(s); waiting for AD SRV records via $dcIp..."
    } catch { Write-Warning "DNS server set failed: $_" }

    # Wait until the DC's DNS resolves the domain (peering + DC promotion done)
    $tries = 0
    while ($tries -lt 60) {
        try {
            Resolve-DnsName -Type SRV "_ldap._tcp.dc._msdcs.$domain" -ErrorAction Stop | Out-Null
            break
        } catch {
            Start-Sleep -Seconds 30
            $tries++
        }
    }
    if ($tries -ge 60) {
        Write-Warning "DC SRV records never resolved via $dcIp after 30 min -- check DC promotion + NSG :53/UDP+TCP from member -> DC"
    }

    try {
        # Do NOT use -Restart here. -Restart forces an IMMEDIATE reboot,
        # which kills the powershell process mid-script. RunCommand v2
        # sees its child die unexpectedly and reports exitCode 1 ->
        # terraform marks the resource Failed even though the join
        # actually succeeded.
        #
        # Instead: join without restart, then schedule a delayed reboot
        # via shutdown.exe so the script can exit cleanly first. The
        # 30-second delay gives RunCommand enough time to capture the
        # transcript and report Succeeded before Windows tears down the
        # session.
        Add-Computer -DomainName $domain -Credential $cred -Force
        Write-Host "Domain join succeeded; scheduling reboot in 30s"
        shutdown.exe /r /t 30 /c "terra-range: rebooting to finish domain join"
    } catch {
        Write-Warning "domain join failed: $_"
    }
}

# --- agents ---
if ("${deploy_agents}" -eq "True") {
    try {
        $sysmonZip = "$env:TEMP\Sysmon.zip"
        Invoke-WebRequest -Uri "https://download.sysinternals.com/files/Sysmon.zip" -OutFile $sysmonZip
        Expand-Archive -Force -Path $sysmonZip -DestinationPath "C:\Sysmon"
        Invoke-WebRequest -Uri "https://raw.githubusercontent.com/SwiftOnSecurity/sysmon-config/master/sysmonconfig-export.xml" -OutFile "C:\Sysmon\config.xml"
        Start-Process -Wait -FilePath "C:\Sysmon\Sysmon64.exe" -ArgumentList "-accepteula -i C:\Sysmon\config.xml"

        $beatMsi = "$env:TEMP\winlogbeat.msi"
        Invoke-WebRequest -Uri "https://artifacts.elastic.co/downloads/beats/winlogbeat/winlogbeat-8.13.4-windows-x86_64.msi" -OutFile $beatMsi
        Start-Process msiexec.exe -Wait -ArgumentList "/i $beatMsi /qn"
        # winlogbeat YAML is built in terraform-land + base64'd. Avoids the
        # PowerShell here-string parser tripping on inline ":" or " - " (LF
        # line-endings on Unix-authored files reliably hit this on Windows).
        $cfgB64 = "${winlogbeat_b64}"
        $cfg = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($cfgB64))
        $cfg | Out-File "C:\Program Files\Winlogbeat\winlogbeat.yml" -Encoding ascii -Force
        Start-Service winlogbeat -ErrorAction SilentlyContinue
    } catch {
        Write-Warning "agent install failed: $_"
    }
}

Stop-Transcript
