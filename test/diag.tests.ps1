# diag.tests.ps1 - run the real diag.ps1 against fake wsl.exe scripts (see
# helpers.ps1), on PowerShell 7 and Windows PowerShell 5.1. The Windows
# feature and virtualization lookups are replaced by parameters: Linux has no
# such things, and on Windows the answer would depend on the machine. The
# distro registry part runs for real on Windows, against a test key.
. (Join-Path $PSScriptRoot 'helpers.ps1')

$diag = Join-Path (Join-Path $PSScriptRoot '..') 'diag.ps1'
$tmp = New-TestDir 'diag'

# The password the user typed, and what wsl-setup.bat holds of it. A fake
# that prints it back stands for any way it could end up in the output.
$PW = 'Tr0ub4dor&3!x%q'
$PWB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($PW))
$UB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('dev'))

$v16 = "$tmp/ver-utf16"
[IO.File]::WriteAllBytes($v16, [Text.Encoding]::Unicode.GetBytes("WSL version: 2.6.1.0`r`nKernel version: 6.6.87.2-1`r`n"))
$leaky = "$tmp/leaky.txt"
[IO.File]::WriteAllText($leaky, "Default Distribution: Debian`nDefault Version: 2`necho: $PW / $PWB64`n")
$envLog = "$tmp/env.log"
$full = New-Fake 'wsl-full' (@(
    "printf '%s|%s|%s\n' `"`$PASS_B64`" `"`$USER_B64`" `"`$WSLENV`" >> '$envLog'",
    "case `"`$1`" in",
    "  --version) cat '$v16' ;;",
    "  --status) cat '$leaky' ;;",
    "  --list) printf '  NAME      STATE           VERSION\r\n* Debian    Stopped         2\r\n' ;;",
    "  --) echo 'There is no distribution with the supplied name.' >&2; echo 'Error code: Wsl/Service/WSL_E_DISTRO_NOT_FOUND' >&2; exit 255 ;;",
    "esac") -join "`n")

$pendingKey = "$tmp/reboot-pending"
Set-Content -Path $pendingKey -Value ''

# On Windows the registry part runs for real, against a key of its own.
$lxss = "$tmp/no-such-key"
$testRoot = $null
if ($onWindows) {
    $testRoot = 'HKCU:\Software\wsl-setup-diag-test-' + [guid]::NewGuid()
    $lxss = "$testRoot\Lxss"
    $g1 = '{' + [guid]::NewGuid() + '}'; $g2 = '{' + [guid]::NewGuid() + '}'
    New-Item -Path $lxss -Force | Out-Null
    Set-ItemProperty -Path $lxss -Name DefaultDistribution -Value $g1
    New-Item -Path "$lxss\$g1" | Out-Null
    Set-ItemProperty -Path "$lxss\$g1" -Name DistributionName -Value 'Ubuntu-24.04'
    New-ItemProperty -Path "$lxss\$g1" -Name Version -Value 2 -PropertyType DWord | Out-Null
    New-ItemProperty -Path "$lxss\$g1" -Name State -Value 1 -PropertyType DWord | Out-Null
    Set-ItemProperty -Path "$lxss\$g1" -Name BasePath -Value 'C:\Users\someone\private-place'
    New-Item -Path "$lxss\$g2" | Out-Null
    Set-ItemProperty -Path "$lxss\$g2" -Name DistributionName -Value 'Debian'
    New-ItemProperty -Path "$lxss\$g2" -Name Version -Value 1 -PropertyType DWord | Out-Null
    New-ItemProperty -Path "$lxss\$g2" -Name State -Value 1 -PropertyType DWord | Out-Null
}

# Runs diag.ps1 into a fresh output folder; returns the result plus the
# report files it wrote there.
$script:runCount = 0
function Invoke-Diag([string[]]$a, [string]$outDir = '') {
    $script:runCount++
    if (-not $outDir) { $outDir = "$tmp/out-$script:runCount"; New-Item -ItemType Directory $outDir | Out-Null }
    $res = Invoke-Script $diag (@('-OutDir', $outDir, '-NoOpen', '-LxssKey', $lxss) + $a)
    $files = @(Get-ChildItem -LiteralPath $outDir -ErrorAction SilentlyContinue | Where-Object { -not $_.PSIsContainer })
    $text = ''
    if ($files.Count -eq 1) { $text = [IO.File]::ReadAllText($files[0].FullName) }
    [pscustomobject]@{ Code = $res.Code; Out = $res.Out + $res.Err; Files = $files; Text = $text }
}
function Has($r, [string]$label, [string]$s) {
    if ($r.Text.Contains($s)) { Ok } else { Bad "${label}: report lacks [$s]`n$($r.Text)" }
}
function Lacks($r, [string]$label, [string]$s) {
    if (-not $r.Text.Contains($s)) { Ok } else { Bad "${label}: report contains [$s]" }
}

Write-Host '=== DIAG ==='
$virtOff = @('-WslFeature', 'Enabled', '-VmpFeature', 'Disabled', '-HypervisorPresent', 'False', '-FirmwareVirt', 'False')

# --- 1. everything answers; credentials still in the environment ---------------
$env:PASS_B64 = $PWB64; $env:USER_B64 = $UB64; $env:WSLENV = 'KEEPME:USER_B64:PASS_B64/u'
try {
    $r = Invoke-Diag (@('-WslExe', $full, '-RebootKeys', $pendingKey) + $virtOff)
} finally {
    Remove-Item Env:PASS_B64, Env:USER_B64, Env:WSLENV -ErrorAction SilentlyContinue
}
$L = 'full report'
if ($r.Code -eq 0) { Ok } else { Bad "${L}: exit $($r.Code) [$($r.Out)]" }
if ($r.Files.Count -eq 1 -and $r.Files[0].Name -match '^wsl-setup-report-\d{8}-\d{6}\.txt$') { Ok } else { Bad "${L}: files written: [$($r.Files.Name -join ', ')]" }
if ($r.Files.Count -eq 1 -and $r.Out.Contains('Report saved: ') -and $r.Out.Contains($r.Files[0].Name)) { Ok } else { Bad "${L}: console does not say where the report is [$($r.Out)]" }
$bytes = if ($r.Files.Count -eq 1) { [IO.File]::ReadAllBytes($r.Files[0].FullName) } else { @() }
if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { Ok } else { Bad "${L}: not UTF-8 with a BOM" }
if (-not $r.Text.Contains([string][char]0)) { Ok } else { Bad "${L}: NUL characters in the report (UTF-16 not decoded)" }
Has $r $L 'wsl-setup diagnostics report'
Has $r $L '--- wsl --version (exit code 0) ---'
Has $r $L 'WSL version: 2.6.1.0'
Has $r $L 'Default Distribution: Debian'
Has $r $L '* Debian    Stopped         2'
Has $r $L '--- wsl -- true (exit code 255) ---'
Has $r $L 'There is no distribution with the supplied name.'
Has $r $L 'Error code: Wsl/Service/WSL_E_DISTRO_NOT_FOUND'
Has $r $L 'Windows Subsystem for Linux: Enabled'
Has $r $L 'Virtual Machine Platform: Disabled'
Has $r $L 'Hypervisor running: no'
Has $r $L 'Virtualization enabled in firmware (BIOS/UEFI): no'
Has $r $L 'turn on VT-x / AMD-V'
Has $r $L "yes - Windows is waiting for a restart:`r`n  $pendingKey"
# Never the password, in any form, and never the environment.
Lacks $r $L $PW
Lacks $r $L $PWB64
Lacks $r $L 'KEEPME'
Has $r $L 'echo: [removed] / [removed]'
# wsl.exe itself never received the credentials; the rest of WSLENV stays.
$seen = @(Get-Content -LiteralPath $envLog -ErrorAction SilentlyContinue)
if ($seen.Count -eq 4) { Ok } else { Bad "${L}: wsl.exe ran $($seen.Count) times, want 4" }
if (@($seen | Where-Object { $_ -ne '||KEEPME' }).Count -eq 0) { Ok } else { Bad "${L}: wsl.exe saw credentials or lost WSLENV: [$($seen -join ' / ')]" }
if ($onWindows) {
    Has $r $L '* Ubuntu-24.04   (WSL 2, state 1)'
    Has $r $L '  Debian   (WSL 1, state 1)'
    Lacks $r $L 'private-place'
} else {
    Has $r $L 'none registered (no WSL registry key for this account)'
}
# Sections come in a fixed order, so a reader finds them.
$order = @('== Windows ==', '== This window ==', '== WSL features ==', '== Virtualization ==',
           '== Restart pending ==', '== Linux distros for this account ==', '== wsl.exe ==')
$pos = @($order | ForEach-Object { $r.Text.IndexOf($_) })
if (-not ($pos -contains -1) -and (($pos | Sort-Object) -join ',') -eq ($pos -join ',')) { Ok } else { Bad "${L}: sections missing or out of order: $($pos -join ',')" }

# --- 2. a hypervisor is running: the firmware "no" is explained, not alarming ---
Remove-Item -LiteralPath $envLog -ErrorAction SilentlyContinue
$r = Invoke-Diag @('-WslExe', $full, '-RebootKeys', "$tmp/not-there", '-WslFeature', 'Enabled', '-VmpFeature', 'Enabled',
                   '-HypervisorPresent', 'True', '-FirmwareVirt', 'False')
$L = 'hypervisor running'
if ($r.Code -eq 0) { Ok } else { Bad "${L}: exit $($r.Code)" }
Has $r $L 'Hypervisor running: yes'
Has $r $L 'that is fine'
Lacks $r $L 'turn on VT-x'
Has $r $L "== Restart pending ==`r`nno`r`n"
# No credentials anywhere: nothing to remove, nothing marked removed.
Lacks $r $L '[removed]'
Has $r $L "echo: $PW / $PWB64"

# --- 3. no wsl.exe at all ---------------------------------------------------------
$r = Invoke-Diag (@('-WslExe', "$tmp/missing-wsl", '-RebootKeys', "$tmp/not-there") + $virtOff)
$L = 'no wsl.exe'
if ($r.Code -eq 0) { Ok } else { Bad "${L}: exit $($r.Code) [$($r.Out)]" }
Has $r $L 'was not found - WSL is not installed on this PC yet.'
Lacks $r $L '--- wsl '

# --- 4. wsl.exe hangs: every call is stopped, the report is still written ----------
$hang = New-Fake 'wsl-hang' 'sleep 30'
$sw = [Diagnostics.Stopwatch]::StartNew()
$r = Invoke-Diag (@('-WslExe', $hang, '-TimeoutSec', '1', '-RebootKeys', "$tmp/not-there") + $virtOff)
$sw.Stop()
$L = 'wsl.exe hangs'
if ($r.Code -eq 0) { Ok } else { Bad "${L}: exit $($r.Code)" }
Has $r $L '--- wsl --version (no answer within 1 seconds - stopped) ---'
Has $r $L '--- wsl -- true (no answer within 2 seconds - stopped) ---'
if ($sw.Elapsed.TotalSeconds -lt 25) { Ok } else { Bad "${L}: took $([int]$sw.Elapsed.TotalSeconds)s" }

# --- 5. the folder cannot be written to: saved in the temp folder instead -----------
$notDir = "$tmp/a-file-not-a-folder"
Set-Content -Path $notDir -Value ''
$tempDir = "$tmp/temp-fallback"
New-Item -ItemType Directory $tempDir | Out-Null
$saveTmp = @($env:TMPDIR, $env:TMP, $env:TEMP)
$env:TMPDIR = $tempDir; $env:TMP = $tempDir; $env:TEMP = $tempDir
try {
    $r = Invoke-Diag (@('-WslExe', $full, '-RebootKeys', "$tmp/not-there") + $virtOff) $notDir
    $L = 'folder not writable'
    $inTemp = @(Get-ChildItem -LiteralPath $tempDir -Filter 'wsl-setup-report-*.txt')
    if ($r.Code -eq 0) { Ok } else { Bad "${L}: exit $($r.Code) [$($r.Out)]" }
    if ($inTemp.Count -eq 1) { Ok } else { Bad "${L}: $($inTemp.Count) reports in the temp folder [$($r.Out)]" }
    if ($inTemp.Count -eq 1 -and $r.Out.Contains($inTemp[0].Name) -and $r.Out.Contains('could not write to')) { Ok } else { Bad "${L}: console [$($r.Out)]" }

    # --- 6. nowhere to write at all: says so, exit 1 ---------------------------------
    $env:TMPDIR = $notDir; $env:TMP = $notDir; $env:TEMP = $notDir
    $r = Invoke-Diag (@('-WslExe', $full, '-RebootKeys', "$tmp/not-there") + $virtOff) $notDir
    $L = 'nowhere to write'
    if ($r.Code -eq 1) { Ok } else { Bad "${L}: exit $($r.Code), want 1 [$($r.Out)]" }
    if ($r.Out.Contains('could not be saved anywhere')) { Ok } else { Bad "${L}: console [$($r.Out)]" }
} finally {
    $env:TMPDIR, $env:TMP, $env:TEMP = $saveTmp
}

if ($testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue }
Remove-TestDir
Write-Host "DIAG RESULTS: $script:pass passed, $script:fail failed"
exit ([int]($script:fail -ne 0))
