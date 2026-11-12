# helpers.ps1 - shared by the *.tests.ps1 files (dot-sourced). Everything here
# works on PowerShell 7 (Linux, Windows) and on Windows PowerShell 5.1, which
# is what really runs the shipped .ps1 files.
$ErrorActionPreference = 'Stop'
$script:pass = 0; $script:fail = 0
function Ok  { $script:pass++ }
function Bad { param($m) $script:fail++; Write-Host "  FAIL: $m" }

$onWindows = $env:OS -eq 'Windows_NT'   # $IsWindows does not exist in 5.1
$pwshExe = (Get-Process -Id $PID).Path  # the PowerShell running the tests
$sh = $null
if ($onWindows) {
    # Git's sh, by full path: a bare "bash"/"sh" could be WSL's launcher.
    $sh = Join-Path $env:ProgramFiles 'Git\bin\sh.exe'
    if (-not (Test-Path -LiteralPath $sh)) { $sh = (Get-Command sh.exe -ErrorAction Stop).Source }
}

# A fresh temp directory, with forward slashes: its path is also written
# into the sh fakes, where a backslash would be an escape character.
function New-TestDir([string]$prefix) {
    $d = (Join-Path ([IO.Path]::GetTempPath()) ($prefix + '-' + [guid]::NewGuid())) -replace '\\', '/'
    New-Item -ItemType Directory $d | Out-Null
    $d
}

# A fake wsl.exe in the test's $tmp: a /bin/sh script with the given body. On
# Windows it gets a .cmd wrapper that runs it with Git's sh.exe and passes its
# exit code on; the wrapper is what is returned, since that is what Windows
# can start.
function New-Fake([string]$name, [string]$body) {
    $f = "$tmp/$name"
    Set-Content -Path $f -Value ("#!/bin/sh`n" + $body + "`n") -NoNewline
    if (-not $onWindows) { chmod +x $f; return $f }
    Set-Content -Path "$f.cmd" -Value ("@`"$sh`" `"%~dp0$name`" %*`r`n@exit /b %errorlevel%`r`n") -NoNewline
    "$f.cmd"
}

# Run a shipped script in a child PowerShell with stdout and stderr in
# separate files. Not `2> file`: Windows PowerShell 5.1 turns redirected
# stderr lines into error records, which stop the caller or reformat the text.
# Bypass: a default Windows policy would refuse to run a .ps1 fake.
# Start-Process joins the arguments with spaces, so none may contain one.
# Not -Wait: on Windows that also waits for every descendant, and a fake that
# "hangs" leaves its sh child sleeping after the helper has killed the .cmd
# wrapper - the test would then measure the fake, not the helper. That child
# also keeps the output files open, hence one pair of files per call and a
# cleanup (Remove-TestDir) that does not insist.
$script:invokeCount = 0
function Invoke-Script([string]$script, [string[]]$a) {
    $script:invokeCount++
    $o = "$tmp/stdout-$script:invokeCount.txt"; $e = "$tmp/stderr-$script:invokeCount.txt"
    $p = Start-Process -FilePath $pwshExe -NoNewWindow -PassThru `
        -ArgumentList (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script) + $a) `
        -RedirectStandardOutput $o -RedirectStandardError $e
    $null = $p.Handle   # 5.1: without this, ExitCode is $null after the exit
    $p.WaitForExit()
    $read = { param($f) $t = Get-Content -Raw -LiteralPath $f -ErrorAction SilentlyContinue; if ($null -eq $t) { '' } else { [string]$t } }
    [pscustomobject]@{ Code = $p.ExitCode; Out = (& $read $o); Err = (& $read $e) }
}

function Remove-TestDir { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
