<#
install-distro.ps1 - run `wsl.exe --install -d <Distro> --no-launch --web-download`
with a progress bar, for wsl-setup.bat.

Exit code is wsl.exe's own exit code. On failure, wsl.exe's output is printed
(decoded - it may be UTF-16) so the user can see why.

This used to be generated at runtime by wsl-setup.bat with `echo` lines. As a
shipped file it can be tested directly, and the distro names arrive as
parameters, not spliced into PowerShell source (a friendly name with an
apostrophe used to break the generated script).

-WslExe / -PollMs exist for the test harness; wsl-setup.bat uses the defaults.
#>
param(
    [Parameter(Mandatory)] [string]$Distro,
    [string]$Friendly = $Distro,
    [string]$WslExe = 'wsl.exe',
    [int]$PollMs = 300
)
$ErrorActionPreference = 'Stop'

function Read-WslLog([string]$Path) {
    # wsl.exe may write UTF-16LE without a BOM; dropping the NULs turns its
    # ASCII text back into something readable either way.
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    try { (Get-Content -LiteralPath $Path -Raw -ErrorAction Stop) -replace "`0", '' } catch { '' }
}

$tmp = [IO.Path]::GetTempPath()
$outLog = Join-Path $tmp "wsl_setup_install_$PID.log"
$errLog = Join-Path $tmp "wsl_setup_install_${PID}_err.log"

try {
    $proc = Start-Process -FilePath $WslExe -PassThru -NoNewWindow `
        -ArgumentList @('--install', '-d', $Distro, '--no-launch', '--web-download') `
        -RedirectStandardOutput $outLog -RedirectStandardError $errLog
} catch {
    Write-Host "Could not start ${WslExe}: $($_.Exception.Message)"
    exit 1
}
# Windows PowerShell 5.1 quirk: without touching .Handle while the process is
# alive, ExitCode stays $null after it exits, and `exit $null` is exit 0 - a
# failed install would then look like a success.
$null = $proc.Handle

$spinner = '|', '/', '-', '\'
$i = 0
$started = Get-Date
while (-not $proc.HasExited) {
    $elapsed = [Math]::Round(((Get-Date) - $started).TotalSeconds)
    $pct = -1
    $all = [regex]::Matches((Read-WslLog $outLog), '(\d+(?:\.\d+)?)%')
    if ($all.Count) { $pct = [Math]::Min(100, [double]$all[$all.Count - 1].Groups[1].Value) }
    if ($pct -ge 0) {
        Write-Progress -Activity "Downloading $Friendly" -Status "$pct% - ${elapsed}s elapsed" -PercentComplete $pct
    } else {
        Write-Progress -Activity "Downloading $Friendly" -Status "$($spinner[$i % 4])  ${elapsed}s elapsed (waiting for progress data)" -PercentComplete -1
    }
    $i++
    Start-Sleep -Milliseconds $PollMs
}
$proc.WaitForExit()
Write-Progress -Activity done -Completed

$code = $proc.ExitCode
if ($null -eq $code) { $code = 1 }   # never report an unknown result as success
if ($code -ne 0) {
    $details = ((Read-WslLog $outLog) + "`n" + (Read-WslLog $errLog)).Trim()
    if ($details) { Write-Host $details }
}
Remove-Item -LiteralPath $outLog, $errLog -ErrorAction SilentlyContinue
exit $code
