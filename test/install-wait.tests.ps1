# install-wait.tests.ps1 - run the real install-distro.ps1 and wait-distro.ps1
# against fake wsl.exe scripts (see helpers.ps1). Runs on PowerShell 7 and on
# Windows PowerShell 5.1, which is what really runs the shipped scripts.
. (Join-Path $PSScriptRoot 'helpers.ps1')

$root = Join-Path $PSScriptRoot '..'
$install = Join-Path $root 'install-distro.ps1'
$wait = Join-Path $root 'wait-distro.ps1'
$tmp = New-TestDir 'instwait'

function Run([string]$script, [string[]]$a) {
    # Bypass: the -1 fake below is a .ps1, which a default Windows policy blocks.
    $out = & $pwshExe -NoProfile -ExecutionPolicy Bypass -File $script @a 2>&1 | Out-String
    [pscustomobject]@{ Out = $out; Code = $LASTEXITCODE }
}

Write-Host '=== INSTALL-DISTRO ==='
# install-distro.ps1 keeps wsl.exe's output in two temp files while it runs;
# none may be left behind, on success or failure (checked after its tests).
function Get-InstallLogs { @(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Filter 'wsl_setup_install_*' -ErrorAction SilentlyContinue | ForEach-Object Name) }
$logsBefore = Get-InstallLogs
$argsFile = "$tmp/install-args"
$ok = New-Fake 'wsl-ok' "echo `"`$*`" > '$argsFile'; for p in 10.0 55.5 100.0; do echo `"Downloading: `$p%`"; sleep 0.2; done; exit 0"
$r = Run $install @('-Distro', 'Ubuntu-24.04', '-Friendly', "Ubuntu 24.04 LTS (it's fine)", '-WslExe', $ok, '-PollMs', '50')
if ($r.Code -eq 0) { Ok } else { Bad "success case: exit $($r.Code) [$($r.Out)]" }
$got = (Get-Content -Raw $argsFile).Trim()
if ($got -ceq '--install -d Ubuntu-24.04 --no-launch --web-download') { Ok } else { Bad "wsl.exe got [$got]" }

# Failure, with the error written as UTF-16LE like an old wsl.exe would.
$errFile = "$tmp/err-utf16"
[IO.File]::WriteAllBytes($errFile, [Text.Encoding]::Unicode.GetBytes("There is no distribution with the supplied name.`r`nError code: Wsl/InstallDistro/WSL_E_DISTRO_NOT_FOUND`r`n"))
$bad = New-Fake 'wsl-bad' "cat '$errFile'; exit 5"
$r = Run $install @('-Distro', 'Nope', '-WslExe', $bad, '-PollMs', '50')
if ($r.Code -eq 5) { Ok } else { Bad "failure case: exit $($r.Code), want 5" }
if ($r.Out -match 'WSL_E_DISTRO_NOT_FOUND') { Ok } else { Bad "failure output not shown/decoded: [$($r.Out)]" }

# Exits before the first progress poll - must still report its real code.
$fast = New-Fake 'wsl-fast' 'exit 3'
$r = Run $install @('-Distro', 'X', '-WslExe', $fast, '-PollMs', '50')
if ($r.Code -eq 3) { Ok } else { Bad "fast-exit case: exit $($r.Code), want 3" }

# Silent at first: the first progress polls see an empty log. On Windows
# PowerShell 5.1 that once crashed the script (Get-Content -Raw -> $null).
$slow = New-Fake 'wsl-slow' 'sleep 1; echo "Downloading: 100.0%"; exit 0'
$r = Run $install @('-Distro', 'X', '-WslExe', $slow, '-PollMs', '50')
if ($r.Code -eq 0 -and $r.Out -notmatch 'Exception') { Ok } else { Bad "empty-log-at-first case: exit $($r.Code) [$($r.Out)]" }

$r = Run $install @('-Distro', 'X', '-WslExe', (Join-Path $tmp 'missing'))
if ($r.Code -eq 1) { Ok } else { Bad "missing wsl.exe: exit $($r.Code), want 1" }

$left = @(Get-InstallLogs | Where-Object { $logsBefore -notcontains $_ })
if ($left.Count -eq 0) { Ok } else { Bad "install-distro.ps1 left log files behind: $($left -join ', ')" }

Write-Host '=== WAIT-DISTRO ==='
$count = "$tmp/count"
$waitArgs = "$tmp/wait-args"
$third = New-Fake 'wsl-third' "echo `"`$*`" > '$waitArgs'; n=`$(cat '$count' 2>/dev/null || echo 0); n=`$((n+1)); echo `$n > '$count'; [ `$n -ge 3 ]"
$r = Run $wait @('-Distro', 'Debian', '-WslExe', $third, '-IntervalSec', '0.1', '-RebootKeys', (Join-Path $tmp 'no-such-key'))
if ($r.Code -eq 0) { Ok } else { Bad "ready on 3rd try: exit $($r.Code)" }
if ((Get-Content $count).Trim() -eq '3') { Ok } else { Bad "expected 3 attempts, got $(Get-Content $count)" }
if ((Get-Content -Raw $waitArgs).Trim() -ceq '-d Debian -u root -- true') { Ok } else { Bad "wait args [$(Get-Content -Raw $waitArgs)]" }

$never = New-Fake 'wsl-never' 'exit 1'
$sw = [Diagnostics.Stopwatch]::StartNew()
$r = Run $wait @('-Distro', 'Debian', '-WslExe', $never, '-TimeoutSec', '1', '-IntervalSec', '0.2', '-RebootKeys', (Join-Path $tmp 'no-such-key'))
$sw.Stop()
if ($r.Code -eq 1 -and $sw.Elapsed.TotalSeconds -lt 15) { Ok } else { Bad "timeout: exit $($r.Code) after $([int]$sw.Elapsed.TotalSeconds)s" }

$key = Join-Path $tmp 'reboot-pending'; New-Item -ItemType File $key | Out-Null
# -TimeoutSec so that a lost restart check fails here in seconds, not after
# the default five minutes.
$r = Run $wait @('-Distro', 'Debian', '-WslExe', $never, '-TimeoutSec', '2', '-IntervalSec', '0.1', '-RebootKeys', $key)
if ($r.Code -eq 2) { Ok } else { Bad "reboot pending: exit $($r.Code), want 2" }

# wsl.exe exits with -1 for its own errors (distro not found, service
# failure). A /bin/sh fake cannot produce a negative code, a PowerShell one
# can: -1 is a failed probe, never "ready".
$minus1 = Join-Path $tmp 'wsl-minus1.ps1'
Set-Content -LiteralPath $minus1 -Value 'exit -1'
$r = Run $wait @('-Distro', 'Debian', '-WslExe', $minus1, '-TimeoutSec', '1', '-IntervalSec', '0.2', '-RebootKeys', (Join-Path $tmp 'no-such-key'))
if ($r.Code -eq 1) { Ok } else { Bad "probe exits -1: exit $($r.Code), want 1 (not ready)" }

# A distro that answers is ready, whatever Windows says about a restart: the
# pending-restart key (set by any unrelated Windows update) must only be
# consulted after a failed probe.
$ready = New-Fake 'wsl-ready' 'exit 0'
$r = Run $wait @('-Distro', 'Debian', '-WslExe', $ready, '-IntervalSec', '0.1', '-RebootKeys', $key)
if ($r.Code -eq 0) { Ok } else { Bad "ready distro with a restart pending: exit $($r.Code), want 0" }

Remove-TestDir
Write-Host "INSTALL-WAIT RESULTS: $script:pass passed, $script:fail failed"
exit ([int]($script:fail -ne 0))
