# list-distros.tests.ps1 - run the real list-distros.ps1 against a fake wsl.exe
# that prints prepared bytes, covering every encoding and layout wsl.exe has
# been seen to produce, plus the failure modes. Linux/pwsh only (the fake is a
# /bin/sh script).
$ErrorActionPreference = 'Stop'
$script:pass = 0; $script:fail = 0
function Ok  { $script:pass++ }
function Bad { param($m) $script:fail++; Write-Host "  FAIL: $m" }

$lister = Join-Path $PSScriptRoot '..' 'list-distros.ps1'
$pwshExe = (Get-Process -Id $PID).Path
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("listdistros-" + [guid]::NewGuid())
New-Item -ItemType Directory $tmp | Out-Null
$fake = Join-Path $tmp 'fake-wsl'
Set-Content -Path $fake -Value "#!/bin/sh`ncat `"`$1`"`n" -NoNewline
chmod +x $fake

$intro3 = @(
    'The following is a list of valid distributions that can be installed.',
    "Install using 'wsl.exe --install <Distro>'.",
    '')
$table = @(
    'NAME                            FRIENDLY NAME',
    'AlmaLinux-9                     AlmaLinux OS 9',
    'Debian                          Debian GNU/Linux',
    'FedoraLinux-42                  Fedora Linux 42',
    'SUSE-Linux-Enterprise-15-SP6    SUSE Linux Enterprise 15 SP6',
    'Ubuntu                          Ubuntu',
    'Ubuntu-24.04                    Ubuntu 24.04 LTS',
    'archlinux                       Arch Linux',
    'kali-linux                      Kali Linux Rolling',
    'openSUSE-Tumbleweed             openSUSE Tumbleweed',
    'OracleLinux_9_5                 Oracle Linux 9.5',
    'nameless-os                     Starts with "name" - must survive')
$want = @(
    'AlmaLinux-9|AlmaLinux OS 9', 'Debian|Debian GNU/Linux', 'FedoraLinux-42|Fedora Linux 42',
    'SUSE-Linux-Enterprise-15-SP6|SUSE Linux Enterprise 15 SP6', 'Ubuntu|Ubuntu',
    'Ubuntu-24.04|Ubuntu 24.04 LTS', 'archlinux|Arch Linux', 'kali-linux|Kali Linux Rolling',
    'openSUSE-Tumbleweed|openSUSE Tumbleweed', 'OracleLinux_9_5|Oracle Linux 9.5',
    'nameless-os|Starts with name - must survive')

function Write-Case([string]$name, [string[]]$lines, [string]$eol, [string]$enc) {
    $text = ($lines -join $eol) + $eol
    $bytes = switch ($enc) {
        'utf16bom' { [byte[]](0xFF, 0xFE) + [Text.Encoding]::Unicode.GetBytes($text) }
        'utf16'    { [Text.Encoding]::Unicode.GetBytes($text) }
        'utf8bom'  { [byte[]](0xEF, 0xBB, 0xBF) + [Text.Encoding]::UTF8.GetBytes($text) }
        'utf8'     { [Text.Encoding]::UTF8.GetBytes($text) }
    }
    if ($null -eq $bytes) { $bytes = [byte[]]::new(0) }   # empty output case
    $f = Join-Path $tmp $name
    [IO.File]::WriteAllBytes($f, [byte[]]$bytes)
    $f
}
function Invoke-Lister([string[]]$extra) {
    $out = & $pwshExe -NoProfile -File $lister @extra 2>$null
    [pscustomobject]@{ Rows = @($out | Where-Object { $_ }); Code = $LASTEXITCODE }
}
function Test-List([string]$label, [string]$file, [string[]]$expect, [int]$code) {
    $r = Invoke-Lister @('-WslExe', $fake, '-WslArgs', $file)
    if ($r.Code -ne $code) { Bad "$label`: exit $($r.Code), want $code"; return }
    $got = $r.Rows -join "`n"; $exp = $expect -join "`n"
    if ($got -ceq $exp) { Ok } else { Bad "$label`: rows differ`n    got: $($r.Rows -join ' / ')`n   want: $($expect -join ' / ')" }
}

Write-Host '=== LIST-DISTROS: encodings x line endings x intro lengths ==='
$intros = @{ 'intro3' = $intro3; 'intro1' = @("Install using 'wsl.exe --install <Distro>'."); 'intro0' = @() }
foreach ($enc in 'utf16bom', 'utf16', 'utf8bom', 'utf8') {
    foreach ($eol in "`r`n", "`n", "`r`r`n") {
        foreach ($ik in $intros.Keys) {
            $label = "$enc/$(($eol -replace "`r",'CR') -replace "`n",'LF')/$ik"
            $f = Write-Case "$enc-$($eol.Length)-$ik" ($intros[$ik] + $table) $eol $enc
            Test-List $label $f $want 0
        }
    }
}

Write-Host '=== LIST-DISTROS: localized header, cleanup, failure modes ==='
# Localized column header (no lowercase) is still skipped.
$fr = @('Voici la liste des distributions valides.', '', 'NOM                 NOM CONVIVIAL') + $table[1..2]
Test-List 'french header' (Write-Case 'fr' $fr "`r`n" 'utf16') @('AlmaLinux-9|AlmaLinux OS 9', 'Debian|Debian GNU/Linux') 0
# No header at all: the first real row must NOT be dropped.
Test-List 'no header' (Write-Case 'nohdr' $table[1..2] "`r`n" 'utf8') @('AlmaLinux-9|AlmaLinux OS 9', 'Debian|Debian GNU/Linux') 0
# cmd-hostile characters stripped from friendly names; duplicates removed.
$dirty = @('NAME    FRIENDLY NAME', 'Weird-1    Bang! ^Caret| 100%', 'Weird-1    duplicate', 'Plain-2    Plain')
Test-List 'sanitize+dedupe' (Write-Case 'dirty' $dirty "`r`n" 'utf16bom') @('Weird-1|Bang Caret 100', 'Plain-2|Plain') 0
# A genuine wsl.exe failure (no network) -> no rows, exit 1.
$errText = @('Failed to fetch the list distribution from ''https://raw.githubusercontent.com/microsoft/WSL/master/distributions/DistributionInfo.json''.',
             'The server name or address could not be resolved', 'Error code: Wsl/WININET_E_NAME_NOT_RESOLVED')
Test-List 'network error utf16' (Write-Case 'err16' $errText "`r`n" 'utf16') @() 1
Test-List 'network error utf8' (Write-Case 'err8' $errText "`r`n" 'utf8') @() 1
Test-List 'empty output' (Write-Case 'empty' @() '' 'utf8') @() 1
# The error text must reach stderr so the user sees why.
$ef = Join-Path $tmp 'stderr.txt'
& $pwshExe -NoProfile -File $lister -WslExe $fake -WslArgs (Join-Path $tmp 'err16') 2> $ef 1> $null
$stderr = Get-Content -Raw $ef
if ($stderr -match 'WININET_E_NAME_NOT_RESOLVED') { Ok } else { Bad "error text not shown on stderr: [$stderr]" }
# wsl.exe missing -> exit 2; wsl.exe hanging -> killed, exit 2, promptly.
$r = Invoke-Lister @('-WslExe', (Join-Path $tmp 'does-not-exist'))
if ($r.Code -eq 2 -and $r.Rows.Count -eq 0) { Ok } else { Bad "missing exe: exit $($r.Code)" }
$sw = [Diagnostics.Stopwatch]::StartNew()
$r = Invoke-Lister @('-WslExe', '/bin/sleep', '-WslArgs', '30', '-TimeoutSec', '2')
$sw.Stop()
if ($r.Code -eq 2 -and $sw.Elapsed.TotalSeconds -lt 15) { Ok } else { Bad "hang: exit $($r.Code) after $([int]$sw.Elapsed.TotalSeconds)s" }

Remove-Item -Recurse -Force $tmp
Write-Host "LIST-DISTROS RESULTS: $script:pass passed, $script:fail failed"
exit ([int]($script:fail -ne 0))
