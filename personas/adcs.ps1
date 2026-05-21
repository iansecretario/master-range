# Persona: adcs
# Theme    : AD Certificate Services with intentional misconfigurations
#            covering common Certified Pre-Owned escalation paths.
# Target   : windows-member (already domain-joined by the wrapper)
# Source   : https://github.com/Orange-Cyberdefense/GOAD certificate
#            misconfigs + https://posts.specterops.io/certified-pre-owned-d95910965cd2
# WARNING  : ISOLATED LAB ENVIRONMENT ONLY.
#
# Provides:
#   - Enterprise CA installed on this host (CN=corp-CA)
#   - Vulnerable certificate template "VulnUser" with:
#       * mspki-certificate-name-flag = ENROLLEE_SUPPLIES_SUBJECT (ESC1)
#       * Client Authentication EKU
#       * Domain Users have Enroll permission
#   - Vulnerable template "VulnAdmin" with:
#       * Any Purpose EKU (ESC2)
#       * Domain Users have Enroll permission

$ErrorActionPreference = "Continue"
Start-Transcript -Path C:\adcs-persona.log -Append

# Requires this VM to be domain-joined and rebooted post-join. The
# windows-persona wrapper handles the join; the wrapper does NOT auto-
# reboot, so trigger one if we just joined and the SID isn't authoritative.
if (-not (Get-WmiObject Win32_ComputerSystem).PartOfDomain) {
    Write-Warning "Not domain-joined yet — ADCS install will fail. Aborting."
    Stop-Transcript
    exit 1
}

# 1. Install ADCS role + management tools
Install-WindowsFeature -Name AD-Certificate -IncludeManagementTools

# 2. Configure as Enterprise Root CA
Install-AdcsCertificationAuthority `
    -CAType EnterpriseRootCA `
    -CACommonName "corp-CA" `
    -KeyLength 2048 `
    -HashAlgorithmName SHA256 `
    -ValidityPeriod Years `
    -ValidityPeriodUnits 5 `
    -Force

Start-Service CertSvc -ErrorAction SilentlyContinue

# 3. Wait for CA to be operational
$tries = 0
while ($tries -lt 20) {
    try {
        certutil -ping
        if ($LASTEXITCODE -eq 0) { break }
    } catch {}
    Start-Sleep -Seconds 5
    $tries++
}

# 4. Plant vulnerable certificate templates.
# We do this by duplicating an existing template and toggling the
# unsafe attributes via ADSI, which is more reliable than certutil
# for cross-DC environments.

Import-Module ActiveDirectory
$configNc = (Get-ADRootDSE).configurationNamingContext
$tmplPath = "CN=Certificate Templates,CN=Public Key Services,CN=Services,$configNc"

function New-VulnTemplate {
    param(
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [int]$NameFlag,
        [Parameter(Mandatory)] [string[]]$EkuOids
    )
    $existing = Get-ADObject -Filter "Name -eq '$Name'" `
        -SearchBase $tmplPath -ErrorAction SilentlyContinue
    if ($existing) { Write-Host "Template $Name already exists"; return }

    # Clone the User template's attributes as a base
    $base = Get-ADObject -Identity "CN=User,$tmplPath" `
        -Properties * -ErrorAction Stop

    $attrs = @{
        "displayName"                          = $Name
        "flags"                                 = 0x20200
        "revision"                              = 100
        "msPKI-Cert-Template-OID"              = "1.3.6.1.4.1.311.21.8.{0}.1.1.{1}" -f (Get-Random -Min 1000 -Max 9999), (Get-Random -Min 1000 -Max 9999)
        "msPKI-Certificate-Name-Flag"          = $NameFlag
        "msPKI-Enrollment-Flag"                = 0
        "msPKI-Minimal-Key-Size"               = 2048
        "msPKI-Private-Key-Flag"               = 0
        "msPKI-RA-Signature"                    = 0
        "msPKI-Template-Minor-Revision"        = 1
        "msPKI-Template-Schema-Version"        = 2
        "pKIDefaultKeySpec"                     = 1
        "pKIExtendedKeyUsage"                   = $EkuOids
        "pKIMaxIssuingDepth"                    = 0
        "pKICriticalExtensions"                 = @("2.5.29.15")
        "pKIKeyUsage"                            = ([byte[]]@(0xa0, 0x00))
        "pKIExpirationPeriod"                    = ([byte[]]@(0x00,0x40,0x39,0x87,0x2e,0xe1,0xfe,0xff))
        "pKIOverlapPeriod"                       = ([byte[]]@(0x00,0x80,0xa6,0x0a,0xff,0xde,0xff,0xff))
        "pKIDefaultCSPs"                         = @("1,Microsoft RSA SChannel Cryptographic Provider","2,Microsoft Enhanced Cryptographic Provider v1.0")
    }

    New-ADObject -Name $Name -Type "pKICertificateTemplate" `
        -Path $tmplPath -OtherAttributes $attrs

    # Grant Domain Users enroll permission on the template.
    # Enroll is extended right with rightsGuid 0e10c968-78fb-11d2-90d4-00c04f79dc55
    $tmplDn = "CN=$Name,$tmplPath"
    dsacls $tmplDn /G "Domain Users:CA;Enroll" 2>&1 | Out-Null

    # Publish to the CA
    certutil -SetCAtemplates "+$Name" 2>&1 | Out-Null
}

# ESC1 — ENROLLEE_SUPPLIES_SUBJECT (flag 1) + Client Auth EKU
New-VulnTemplate -Name "VulnUser" -NameFlag 1 `
    -EkuOids @("1.3.6.1.5.5.7.3.2")  # Client Authentication

# ESC2 — Any Purpose EKU (or none)
New-VulnTemplate -Name "VulnAdmin" -NameFlag 0 `
    -EkuOids @("2.5.29.37.0")         # anyExtendedKeyUsage

# Restart CertSvc so newly-published templates are picked up
Restart-Service CertSvc

# 5. Trophy file
@"
============================================================
  ADCS Lab — Compromised
  TROPHY: guidem{adcs_esc1_template_misconfigured_2025}
============================================================
"@ | Out-File C:\TROPHY.txt -Encoding ascii
icacls C:\TROPHY.txt /inheritance:r /grant:r "Administrators:R" "SYSTEM:F" | Out-Null

Stop-Transcript
