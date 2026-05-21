# Bake-time finalize. Runs AFTER Windows Update so the image ships with
# the latest cumulative patches but won't re-run WU on every cloned VM.

$ErrorActionPreference = "Continue"
Start-Transcript -Path C:\packer-finalize.log -Append

Write-Host "==> Disabling Windows Update services post-bake..."
# wuauserv = Windows Update; UsoSvc = Update Orchestrator (triggers wuauserv);
# WaaSMedicSvc = self-healing for WU. Disabling all three keeps first-boot
# of cloned VMs from re-pulling patches.
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
