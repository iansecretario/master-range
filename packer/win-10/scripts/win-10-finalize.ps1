# Bake-time finalize for Windows 10. Disables Windows Update so cloned
# VMs don't re-pull patches on first boot.

$ErrorActionPreference = "Continue"
Start-Transcript -Path C:\packer-finalize.log -Append

Write-Host "==> Disabling Windows Update services post-bake..."
foreach ($svc in @('wuauserv', 'UsoSvc', 'WaaSMedicSvc')) {
    try {
        Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
        Set-Service -Name $svc -StartupType Disabled -ErrorAction SilentlyContinue
        Write-Host "  disabled $svc"
    } catch { Write-Warning "couldn't disable ${svc}: $_" }
}

Write-Host "==> Disabling UpdateOrchestrator scheduled tasks..."
Get-ScheduledTask -TaskPath '\Microsoft\Windows\UpdateOrchestrator\' -ErrorAction SilentlyContinue |
    Disable-ScheduledTask -ErrorAction SilentlyContinue | Out-Null

Write-Host "==> Clearing event logs so first-boot logs are clean..."
wevtutil el | ForEach-Object { wevtutil cl "$_" 2>$null }

Write-Host "==> Defragging C:\ (compresses captured image)..."
Optimize-Volume -DriveLetter C -ReTrim -Verbose -ErrorAction SilentlyContinue

Write-Host "==> Finalize complete; image is ready for sysprep."
Stop-Transcript
