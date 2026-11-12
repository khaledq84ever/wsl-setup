<#
wait-distro.ps1 - wait until a freshly installed distro answers
`wsl.exe -d <Distro> -u root -- true`, for wsl-setup.bat.

Exit codes: 0 = ready, 2 = Windows has a restart pending (WSL cannot finish
until reboot), 1 = gave up after -TimeoutSec.

Only the servicing key counts as "restart pending": enabling a Windows
feature such as WSL sets it. PendingFileRenameOperations is deliberately not
used - it is a registry value, not a key (so Test-Path on it was always
false), and almost any installer sets it, which says nothing about WSL.

-WslExe / -IntervalSec / -RebootKeys exist for the test harness;
wsl-setup.bat uses the defaults. The end-to-end tests drive wsl-setup.bat
itself and so cannot pass parameters; for them the defaults can be changed
with WSL_SETUP_WAIT_TIMEOUT, WSL_SETUP_WAIT_INTERVAL (seconds) and
WSL_SETUP_REBOOT_KEYS (paths separated by ;). Unset in normal use.
#>
param(
    [Parameter(Mandatory)] [string]$Distro,
    [string]$WslExe = 'wsl.exe',
    [int]$TimeoutSec = $(if ($env:WSL_SETUP_WAIT_TIMEOUT) { [int]$env:WSL_SETUP_WAIT_TIMEOUT } else { 300 }),
    [double]$IntervalSec = $(if ($env:WSL_SETUP_WAIT_INTERVAL) { [double]$env:WSL_SETUP_WAIT_INTERVAL } else { 5 }),
    [string[]]$RebootKeys = $(if ($env:WSL_SETUP_REBOOT_KEYS) { $env:WSL_SETUP_REBOOT_KEYS -split ';' } else {
        @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') })
)

$started = Get-Date
while ($true) {
    $elapsed = [int]((Get-Date) - $started).TotalSeconds
    $pct = [Math]::Min(100, [Math]::Round($elapsed / $TimeoutSec * 100))
    Write-Progress -Activity "Waiting for $Distro to finish initializing" `
        -Status "$elapsed sec / $TimeoutSec sec (first-time boot can take a while)" -PercentComplete $pct
    & $WslExe -d $Distro -u root -- true 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { Write-Progress -Activity done -Completed; exit 0 }
    foreach ($k in $RebootKeys) {
        if (Test-Path -LiteralPath $k -ErrorAction SilentlyContinue) {
            Write-Progress -Activity done -Completed
            exit 2
        }
    }
    if ($elapsed -ge $TimeoutSec) { break }
    Start-Sleep -Seconds $IntervalSec
}
Write-Progress -Activity done -Completed
exit 1
