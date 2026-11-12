# wsl-status.tests.ps1 - run the real wsl-status.ps1 against fake wsl.exe
# scripts (see helpers.ps1), on PowerShell 7 and Windows PowerShell 5.1. The
# Windows feature lookup is replaced by -FeatureState: Linux has no such
# feature, and on Windows the answer would depend on the machine.
. (Join-Path $PSScriptRoot 'helpers.ps1')

$status = Join-Path (Join-Path $PSScriptRoot '..') 'wsl-status.ps1'
$tmp = New-TestDir 'wslstatus'

function Test-Status([string]$label, [string[]]$a, [int]$wantCode, [string]$wantLine) {
    $r = Invoke-Script $status $a
    $code = $r.Code
    $out = @(($r.Out + "`n" + $r.Err) -split "`r?`n")
    $lines = @($out | Where-Object { $_.Trim() })
    if ($code -eq $wantCode) { Ok } else { Bad "${label}: exit $code, want $wantCode [$($out -join ' / ')]" }
    if ($lines.Count -eq 1 -and $lines[0] -ceq $wantLine) { Ok } else { Bad "${label}: printed [$($out -join ' / ')], want [$wantLine]" }
    # The .bat prints the message with delayed expansion on and splits on |.
    if ($lines.Count -eq 1 -and $lines[0] -match '^(OK|INFO)\|[^|!^%"]+$') { Ok } else { Bad "${label}: not a safe KIND|message line: [$($lines -join ' / ')]" }
}

Write-Host '=== WSL-STATUS ==='
$v16 = "$tmp/ver-utf16"
[IO.File]::WriteAllBytes($v16, [Text.Encoding]::Unicode.GetBytes("WSL version: 2.6.1.0`r`nKernel version: 6.6.87.2-1`r`n"))
$store16 = New-Fake 'wsl-store16' "[ `"`$1`" = --version ] && cat '$v16' && exit 0; exit 9"
Test-Status 'store WSL, UTF-16' @('-WslExe', $store16, '-FeatureState', 'Unknown') 0 'OK|WSL is installed - version 2.6.1.0'

# A localized label and UTF-8 output (WSL_UTF8=1 honoured).
$store8 = New-Fake 'wsl-store8' 'printf "WSL-Version: 2.7.0.0\r\nKernelversion: 6.6\r\n"; exit 0'
Test-Status 'store WSL, UTF-8, German label' @('-WslExe', $store8, '-FeatureState', 'Unknown') 0 'OK|WSL is installed - version 2.7.0.0'

# Old built-in wsl.exe: no --version, prints usage and fails.
$inbox = New-Fake 'wsl-inbox' 'echo "Invalid command line option: --version"; exit 255'
Test-Status 'built-in WSL, feature on' @('-WslExe', $inbox, '-FeatureState', 'Enabled') 0 'OK|WSL is installed - built-in Windows version'
Test-Status 'wsl.exe stub, feature off' @('-WslExe', $inbox, '-FeatureState', 'Disabled') 1 'INFO|WSL is not installed yet - it is set up together with the distro you pick. Windows may need a restart.'
Test-Status 'feature enabled, restart pending' @('-WslExe', $inbox, '-FeatureState', 'EnablePending') 1 'INFO|WSL was just turned on - restart Windows to finish, then run this tool again.'
Test-Status 'no answer either way' @('-WslExe', $inbox, '-FeatureState', 'Unknown') 2 'INFO|Could not check whether WSL is installed - continuing anyway.'

Test-Status 'no wsl.exe at all' @('-WslExe', (Join-Path $tmp 'missing-wsl'), '-FeatureState', 'Unknown') 1 'INFO|WSL is not installed yet - it is set up together with the distro you pick. Windows may need a restart.'

# --version hangs: must give up after -TimeoutSec, not block the menu.
$hang = New-Fake 'wsl-hang' 'sleep 30'
$sw = [Diagnostics.Stopwatch]::StartNew()
Test-Status 'wsl.exe hangs' @('-WslExe', $hang, '-TimeoutSec', '1', '-FeatureState', 'Unknown') 2 'INFO|Could not check whether WSL is installed - continuing anyway.'
$sw.Stop()
if ($sw.Elapsed.TotalSeconds -lt 15) { Ok } else { Bad "hang case took $([int]$sw.Elapsed.TotalSeconds)s" }

# Succeeds but prints no version number: not trusted as "installed".
$noVer = New-Fake 'wsl-nover' 'echo "something unexpected"; exit 0'
Test-Status 'exit 0 without a version' @('-WslExe', $noVer, '-FeatureState', 'Disabled') 1 'INFO|WSL is not installed yet - it is set up together with the distro you pick. Windows may need a restart.'

# Fails but happens to print something version-like: a failed --version says
# nothing about WSL being installed.
$failVer = New-Fake 'wsl-failver' 'echo "WSL version: 9.9.9.9"; exit 1'
Test-Status 'failed --version with a version in its output' @('-WslExe', $failVer, '-FeatureState', 'Disabled') 1 'INFO|WSL is not installed yet - it is set up together with the distro you pick. Windows may need a restart.'

# The feature is on but there is no wsl.exe to run: not usable, so not "installed".
Test-Status 'feature on, no wsl.exe' @('-WslExe', (Join-Path $tmp 'missing-wsl'), '-FeatureState', 'Enabled') 1 'INFO|WSL is not installed yet - it is set up together with the distro you pick. Windows may need a restart.'

# The feature is being turned off (takes effect at the next restart).
Test-Status 'feature being disabled' @('-WslExe', $inbox, '-FeatureState', 'DisablePending') 1 'INFO|WSL is not installed yet - it is set up together with the distro you pick. Windows may need a restart.'

Remove-Item -Recurse -Force $tmp
Write-Host "WSL-STATUS RESULTS: $script:pass passed, $script:fail failed"
exit ([int]($script:fail -ne 0))
