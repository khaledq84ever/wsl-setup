<#
wsl-status.ps1 - tell wsl-setup.bat whether WSL itself is installed on this PC
(separately from any distro). Prints ONE line, KIND|message, for `for /f`:

  OK|WSL is installed - version 2.6.1.0           (Store WSL answers --version)
  OK|WSL is installed - built-in Windows version   (old inbox WSL, feature on)
  INFO|WSL is not installed yet - ...              (no wsl.exe, or feature off)
  INFO|WSL was just turned on - restart ...         (feature enabled, restart pending)
  INFO|Could not check whether WSL is installed ... (no answer either way)

Exit code matches: 0 = installed, 1 = not installed yet, 2 = unknown. It is
only shown to the user - wsl.exe --install sets WSL up either way.

The message must not contain ! ^ | % or quotes: the .bat prints it with delayed
expansion on. -WslExe / -TimeoutSec / -FeatureState exist for the tests
(test/wsl-status.tests.ps1); wsl-setup.bat uses the defaults.
#>
param(
    [string]$WslExe = 'wsl.exe',
    [int]$TimeoutSec = 30,
    # Tests pass Enabled / Disabled / Unknown instead of asking Windows.
    [string]$FeatureState = ''
)
$ErrorActionPreference = 'Stop'

function ConvertFrom-WslBytes([byte[]]$Bytes) {
    # Same rules as list-distros.ps1: UTF-16LE with/without BOM, or UTF-8.
    if ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xFE) {
        return [Text.Encoding]::Unicode.GetString($Bytes, 2, $Bytes.Length - 2)
    }
    $zeros = 0
    foreach ($b in $Bytes) { if ($b -eq 0) { $zeros++ } }
    if ($Bytes.Length -gt 0 -and ($zeros * 4) -gt $Bytes.Length) {
        return [Text.Encoding]::Unicode.GetString($Bytes)
    }
    return [Text.Encoding]::UTF8.GetString($Bytes)
}

# Returns the version string `wsl.exe --version` reports, or $null.
function Get-StoreWslVersion {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $WslExe
    $psi.Arguments = '--version'
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    try { $p = [System.Diagnostics.Process]::Start($psi) } catch { return $null }
    $out = New-Object System.IO.MemoryStream
    $err = New-Object System.IO.MemoryStream
    $tasks = [System.Threading.Tasks.Task[]]@(
        $p.StandardOutput.BaseStream.CopyToAsync($out),
        $p.StandardError.BaseStream.CopyToAsync($err))
    if (-not $p.WaitForExit($TimeoutSec * 1000)) {
        try { $p.Kill() } catch { }
        return $null
    }
    [void][System.Threading.Tasks.Task]::WaitAll($tasks, 5000)
    if ($p.ExitCode -ne 0) { return $null }
    # The first line is "WSL version: X.Y.Z.W" (label is localized) - take the
    # first dotted number on it.
    $text = (ConvertFrom-WslBytes $out.ToArray()) -replace "`0", ''
    $first = ($text -split "`r*`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
    $m = [regex]::Match([string]$first, '(\d+\.\d+\.\d+(?:\.\d+)?)')
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}

function Get-FeatureState {
    if ($FeatureState) { return $FeatureState }
    try {
        $f = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux -ErrorAction Stop
        return [string]$f.State
    } catch {
        return 'Unknown'
    }
}

$haveExe = [bool](Get-Command $WslExe -ErrorAction SilentlyContinue)
if ($haveExe) {
    $ver = Get-StoreWslVersion
    if ($ver) {
        'OK|WSL is installed - version ' + $ver
        exit 0
    }
}
# No answer from --version: either the old built-in WSL (which has no
# --version), or WSL not set up at all. The Windows feature tells them apart.
$state = Get-FeatureState
if ($haveExe -and $state -eq 'Enabled') {
    'OK|WSL is installed - built-in Windows version'
    exit 0
}
if ($state -eq 'EnablePending') {
    'INFO|WSL was just turned on - restart Windows to finish, then run this tool again.'
    exit 1
}
if (-not $haveExe -or $state -eq 'Disabled' -or $state -eq 'DisablePending') {
    'INFO|WSL is not installed yet - it is set up together with the distro you pick. Windows may need a restart.'
    exit 1
}
'INFO|Could not check whether WSL is installed - continuing anyway.'
exit 2
