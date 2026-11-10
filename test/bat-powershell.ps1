# bat-powershell.ps1 - test the PowerShell that wsl-setup.bat runs, without Windows.
#
# Runs under PowerShell 7 on Linux (pwsh). It:
#   1. extracts every `powershell -NoProfile -Command "..."` string from the .bat
#      (and any script it writes out with `echo`, undoing ^ escapes and %%),
#      plus the shipped *.ps1 files, and parses all of them;
#   2. runs the real :MATCHRE helper against valid/invalid usernames and menu
#      choices, including cmd-special characters;
#   3. runs the real password snippet (Read-Host swapped for a test SecureString)
#      and checks the base64 it returns decodes back to the exact password.
#
# Not covered: anything that needs Windows itself (UAC, registry, wsl.exe), and
# cmd.exe's own parsing of the .bat - that still needs a real Windows smoke test.
param([string]$Bat = (Join-Path $PSScriptRoot '..' 'wsl-setup.bat'))
$ErrorActionPreference = 'Stop'
$script:pass = 0; $script:fail = 0
function Ok   { $script:pass++ }
function Bad  { param($m) $script:fail++; Write-Host "  FAIL: $m" }

$lines = (Get-Content -Raw $Bat) -split "`r?`n"
# Stand-ins for the batch variables the snippets reference.
function Sub([string]$t) {
    $t.Replace('!selectedName!', 'Ubuntu').Replace('!selectedFriendly!', 'Ubuntu 24.04').
       Replace('!installLog!', '/tmp/i.log').Replace('!installErrLog!', '/tmp/e.log')
}

# ---- 1. extract ----
$snippets = [ordered]@{}
for ($i = 0; $i -lt $lines.Count; $i++) {
    $m = [regex]::Match($lines[$i], 'powershell -NoProfile -Command "(.*?)"(?:`\)|\s*$)')
    if ($m.Success) { $snippets["inline L$($i + 1)"] = Sub $m.Groups[1].Value }
}
for ($i = 0; $i -lt $lines.Count - 1; $i++) {
    if ($lines[$i].Trim() -eq '(' -and $lines[$i + 1].Trim().StartsWith('echo ')) {
        $body = @(); $j = $i + 1
        while (-not $lines[$j].Trim().StartsWith(')')) {
            $t = $lines[$j].Trim().Substring(5)
            $t = [regex]::Replace($t, '\^(.)', '$1').Replace('%%', '%')
            $body += Sub $t; $j++
        }
        if (($body -join '') -match '\$') { $snippets["generated L$($i + 1)"] = $body -join "`n" }
        $i = $j
    }
}

Write-Host "=== PS PARSE: $($snippets.Count) PowerShell snippets from wsl-setup.bat ==="
if ($snippets.Count -lt 6) { Bad "expected at least 6 snippets, found $($snippets.Count) - extractor out of date?" }
# ...and the PowerShell files shipped next to the .bat.
foreach ($f in Get-ChildItem (Split-Path $Bat) -Filter *.ps1) { $snippets["file $($f.Name)"] = Get-Content -Raw $f.FullName }
foreach ($k in $snippets.Keys) {
    $err = $null
    [void][System.Management.Automation.Language.Parser]::ParseInput($snippets[$k], [ref]$null, [ref]$err)
    if ($err.Count) { Bad "$k does not parse: $($err[0].Message)" } else { Ok }
}

function Find-Snippet([string]$needle) {
    $hit = @($snippets.Values | Where-Object { $_.Contains($needle) })
    if ($hit.Count -ne 1) { throw "expected exactly one snippet containing '$needle', found $($hit.Count)" }
    $hit[0]
}
$pwshExe = (Get-Process -Id $PID).Path

# ---- 2. :MATCHRE ----
Write-Host '=== PS MATCHRE: username and menu-choice validation ==='
$match = Find-Snippet '$env:CHK_VAL -cmatch $env:CHK_RE'
function Test-Match($re, $val, $want) {
    $env:CHK_RE = $re; $env:CHK_VAL = $val
    & $pwshExe -NoProfile -Command $match
    if ($LASTEXITCODE -eq $want) { Ok } else { Bad "re=$re val=[$val] exit=$LASTEXITCODE want=$want" }
}
# Patterns must be the ones the .bat actually sets.
$userRe   = ([regex]::Match(($lines -join "`n"), 'set "CHK_RE=(\^\[a-z_\][^"]*)"')).Groups[1].Value
$choiceRe = ([regex]::Match(($lines -join "`n"), 'set "CHK_RE=(\^\[1-9\][^"]*)"')).Groups[1].Value
if (-not $userRe -or -not $choiceRe) { Bad 'could not find the CHK_RE patterns in the .bat' }
foreach ($v in 'dev', 'my_user', '_x', 'a-b', 'x1', ('a' * 32)) { Test-Match $userRe $v 0 }
Test-Match $userRe ('a' * 33) 1   # Linux max is 32
foreach ($v in 'Dev', 'DEV', 'Zed', 'dEv', 'devX', '1abc', 'dev&calc', 'dev|x', '', 'dév', 'a b', 'dev!', 'de^v', '%x%', '"q"', "dev`nx") {
    Test-Match $userRe $v 1
}
foreach ($v in '1', '2', '12', '9999') { Test-Match $choiceRe $v 0 }
foreach ($v in '0', '01', '10000', '1&calc', '', ' 1', '1 ', '-1', '99999999999') { Test-Match $choiceRe $v 1 }

# ---- 3. password -> base64 ----
Write-Host '=== PS PASSWORD: confirm + base64 round-trip ==='
$pw = Find-Snippet 'ERR:MISMATCH'
$pw = $pw.Replace("Read-Host -AsSecureString '  New Linux password'", 'Get-TestSecret $env:T1').
          Replace("Read-Host -AsSecureString '  Confirm password'", 'Get-TestSecret $env:T2')
if ($pw.Contains('Read-Host')) { Bad 'password snippet changed shape - update the Read-Host substitution' }
$pw = 'function Get-TestSecret($s) { $x = [securestring]::new(); foreach ($c in $s.ToCharArray()) { $x.AppendChar($c) }; $x }; ' + $pw
function Test-Pw($t1, $t2, $wantMarker) {
    $env:T1 = $t1; $env:T2 = $t2
    $out = (& $pwshExe -NoProfile -Command $pw | Out-String).Trim()
    if ($wantMarker) {
        if ($out -eq $wantMarker) { Ok } else { Bad "[$t1]/[$t2] gave [$out], want $wantMarker" }
    } else {
        $back = try { [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($out)) } catch { "<not base64: $out>" }
        if ($back -ceq $t1) { Ok } else { Bad "round-trip [$t1] came back as [$back]" }
    }
}
foreach ($p in 'P@ss!word', 'a!b^c%d%e', 'with space', "quo'te`"dq", 'ar:كلمة', 'é€', '$(rm -rf /)', '!!', '&|<>()') {
    Test-Pw $p $p $null
}
Test-Pw 'abc' 'abd' 'ERR:MISMATCH'
Test-Pw 'Abc' 'abc' 'ERR:MISMATCH'
Test-Pw '' '' 'ERR:EMPTY'

Write-Host "PS RESULTS: $script:pass passed, $script:fail failed"
exit ([int]($script:fail -ne 0))
