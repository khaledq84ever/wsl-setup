<#
list-distros.ps1 - print the distros `wsl.exe --list --online` offers, one per
line as  NAME|FRIENDLY NAME , for wsl-setup.bat to read with `for /f`.

Why this is not done in cmd: wsl.exe writes UTF-16LE when its output is piped,
unless it is new enough to honour WSL_UTF8=1. cmd's `for /f`/findstr cannot
read UTF-16 (every other byte is NUL), so on older wsl.exe builds the list
always came back empty. Here the raw bytes are captured and decoded according
to what they actually are: UTF-16LE with or without a BOM, or UTF-8.

Parsing does not depend on how many intro lines wsl.exe prints (that has
changed between versions) or on their language. A distro row is
  <name><2+ spaces><friendly name>
where <name> is a plain identifier. The column header is the first such row
and is skipped only if it has no lowercase letter (NAME, NOM, NOMBRE, ...).
Intro and error prose never has a 2+ space gap, so a failure yields 0 rows.

Exit codes: 0 = rows printed, 1 = no rows found, 2 = wsl.exe could not be
run or timed out. On failure, what wsl.exe said goes to stderr, which
`for /f` does not capture, so it shows on the console for the user.

-WslExe / -WslArgs / -TimeoutSec exist for the test harness
(test/list-distros.tests.ps1); wsl-setup.bat uses the defaults.
#>
param(
    [string]$WslExe = 'wsl.exe',
    [string]$WslArgs = '--list --online',
    [int]$TimeoutSec = 90
)
$ErrorActionPreference = 'Stop'

function ConvertFrom-WslBytes([byte[]]$Bytes) {
    if ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xFE) {
        return [Text.Encoding]::Unicode.GetString($Bytes, 2, $Bytes.Length - 2)
    }
    if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) {
        return [Text.Encoding]::UTF8.GetString($Bytes, 3, $Bytes.Length - 3)
    }
    # No BOM: ASCII-range text encoded as UTF-16LE has a NUL in every other
    # byte. Real UTF-8 text has none.
    $zeros = 0
    foreach ($b in $Bytes) { if ($b -eq 0) { $zeros++ } }
    if ($Bytes.Length -gt 0 -and ($zeros * 4) -gt $Bytes.Length) {
        return [Text.Encoding]::Unicode.GetString($Bytes)
    }
    return [Text.Encoding]::UTF8.GetString($Bytes)
}

function Get-DistroRows([string]$Text) {
    $seen = @{}
    $first = $true
    foreach ($raw in (($Text -replace "`0", '') -split "`r*`n")) {
        $line = $raw.TrimEnd()
        $m = [regex]::Match($line, '^\s*([A-Za-z0-9][A-Za-z0-9._-]*)\s{2,}(\S.*)$')
        if (-not $m.Success) { continue }
        $name = $m.Groups[1].Value
        if ($first) {
            $first = $false
            if ($name -cnotmatch '[a-z]') { continue }   # the column header
        }
        if ($seen.ContainsKey($name)) { continue }
        $seen[$name] = $true
        # The .bat stores these with delayed expansion on, which would eat
        # "!" (and the carets around it); "|" is our field separator.
        $friendly = ($m.Groups[2].Value -replace '[!^|%"]', '').Trim()
        if (-not $friendly) { $friendly = $name }
        [pscustomobject]@{ Name = $name; Friendly = $friendly }
    }
}

function Invoke-WslCapture {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $WslExe
    $psi.Arguments = $WslArgs
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    # Read both pipes asynchronously as raw bytes: no decoding guesses by
    # .NET, and no deadlock if one pipe fills while we wait on the other.
    $out = New-Object System.IO.MemoryStream
    $err = New-Object System.IO.MemoryStream
    $tasks = [System.Threading.Tasks.Task[]]@(
        $p.StandardOutput.BaseStream.CopyToAsync($out),
        $p.StandardError.BaseStream.CopyToAsync($err))
    if (-not $p.WaitForExit($TimeoutSec * 1000)) {
        try { $p.Kill() } catch { }
        throw "wsl.exe did not answer within $TimeoutSec seconds"
    }
    [void][System.Threading.Tasks.Task]::WaitAll($tasks, 5000)
    (ConvertFrom-WslBytes $out.ToArray()) + "`n" + (ConvertFrom-WslBytes $err.ToArray())
}

try {
    $text = Invoke-WslCapture
} catch {
    [Console]::Error.WriteLine("Could not run '$WslExe $WslArgs': $($_.Exception.Message)")
    exit 2
}

$rows = @(Get-DistroRows $text)
if ($rows.Count -eq 0) {
    [Console]::Error.WriteLine("wsl.exe returned no distro list. It said:")
    [Console]::Error.WriteLine(($text -replace "`0", '').Trim())
    exit 1
}
foreach ($r in $rows) { '{0}|{1}' -f $r.Name, $r.Friendly }
exit 0
