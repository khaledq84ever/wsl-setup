<#
diag.ps1 - save a diagnostics report about WSL on this PC, for wsl-setup.bat
(main menu 3). The report is a plain text file the user can read first and
then send to whoever helps them. Nothing in it is changed on the PC: it only
asks Windows and wsl.exe questions.

What is in it: Windows edition/build, the account and whether this window is
elevated, the WSL and Virtual Machine Platform feature states, virtualization
(hypervisor running / enabled in firmware), restart-pending keys, the distros
registered for this account (name, WSL version, state - no paths), and what
wsl.exe says for --version, --status, --list --verbose and a start of the
default distro (`wsl.exe -- true`, which shows WSL's own error if it cannot
start).

What is never in it: a password or the base64 credentials. wsl-setup.bat
clears them before its menu comes back, and on top of that this script drops
PASS_B64 / USER_B64 from its own environment and from WSLENV before running
wsl.exe, and removes the password (base64 and plain, if 4+ characters) from
the text before saving. No environment variables are written to the report.

Saved as wsl-setup-report-<date>-<time>.txt next to this script; if that
folder cannot be written to, in the temp folder. Opened in Notepad unless
-NoOpen or WSL_SETUP_DIAG_NO_OPEN=1. Exit code 0 = saved, 1 = could not save.

-WslExe / -OutDir / -TimeoutSec / -LxssKey / -RebootKeys / -WslFeature /
-VmpFeature / -HypervisorPresent / -FirmwareVirt exist for the tests
(test/diag.tests.ps1); wsl-setup.bat uses the defaults. The end-to-end tests
cannot pass parameters; for them WSL_SETUP_DIAG_DIR, WSL_SETUP_DIAG_NO_OPEN
and WSL_SETUP_REBOOT_KEYS (paths separated by ;) change the defaults.
#>
param(
    [string]$WslExe = 'wsl.exe',
    [string]$OutDir = $(if ($env:WSL_SETUP_DIAG_DIR) { $env:WSL_SETUP_DIAG_DIR } else { $PSScriptRoot }),
    [int]$TimeoutSec = 30,
    [string]$LxssKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss',
    [string[]]$RebootKeys = $(if ($env:WSL_SETUP_REBOOT_KEYS) { $env:WSL_SETUP_REBOOT_KEYS -split ';' } else { @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') }),
    # Tests pass these instead of asking Windows (Linux has no such features).
    [string]$WslFeature = '',
    [string]$VmpFeature = '',
    [string]$HypervisorPresent = '',
    [string]$FirmwareVirt = '',
    [switch]$NoOpen
)
$ErrorActionPreference = 'Stop'

# ---- credentials: keep them away from wsl.exe and out of the text ----------
$secrets = @()
if ($env:PASS_B64) {
    $secrets += $env:PASS_B64
    try {
        $plain = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($env:PASS_B64))
        # A very short password would match ordinary text all over the report.
        if ($plain.Length -ge 4) { $secrets += $plain }
    } catch { }
}
Remove-Item Env:PASS_B64, Env:USER_B64 -ErrorAction SilentlyContinue
if ($env:WSLENV) {
    $keep = @($env:WSLENV -split ':' | Where-Object { $_ -and ($_ -split '/')[0] -notin @('PASS_B64', 'USER_B64') })
    if ($keep.Count) { $env:WSLENV = $keep -join ':' } else { Remove-Item Env:WSLENV -ErrorAction SilentlyContinue }
}

function ConvertFrom-WslBytes([byte[]]$Bytes) {
    # Same rules as list-distros.ps1: UTF-16LE with/without BOM, or UTF-8.
    if ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xFE) {
        return [Text.Encoding]::Unicode.GetString($Bytes, 2, $Bytes.Length - 2)
    }
    if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) {
        return [Text.Encoding]::UTF8.GetString($Bytes, 3, $Bytes.Length - 3)
    }
    $zeros = 0
    foreach ($b in $Bytes) { if ($b -eq 0) { $zeros++ } }
    if ($Bytes.Length -gt 0 -and ($zeros * 4) -gt $Bytes.Length) {
        return [Text.Encoding]::Unicode.GetString($Bytes)
    }
    return [Text.Encoding]::UTF8.GetString($Bytes)
}

# First line of an error message only: some are several lines long.
function Msg($e) { ([string]$e.Exception.Message -split "`r?`n")[0] }

# Runs wsl.exe with the given arguments and returns its output as report
# lines: a header with the exit code, then stdout and stderr. Never throws.
function Invoke-Wsl([string]$WslArgs, [int]$Seconds) {
    $head = "--- wsl $WslArgs"
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $WslExe
    $psi.Arguments = $WslArgs
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    try { $p = [System.Diagnostics.Process]::Start($psi) } catch {
        return @("$head ---", "(could not run wsl.exe: $(Msg $_))", '')
    }
    $out = New-Object System.IO.MemoryStream
    $err = New-Object System.IO.MemoryStream
    $tasks = [System.Threading.Tasks.Task[]]@(
        $p.StandardOutput.BaseStream.CopyToAsync($out),
        $p.StandardError.BaseStream.CopyToAsync($err))
    if (-not $p.WaitForExit($Seconds * 1000)) {
        try { $p.Kill() } catch { }
        return @("$head (no answer within $Seconds seconds - stopped) ---", '')
    }
    [void][System.Threading.Tasks.Task]::WaitAll($tasks, 5000)
    $text = ((ConvertFrom-WslBytes $out.ToArray()) + "`n" + (ConvertFrom-WslBytes $err.ToArray())) -replace "`0", ''
    $lines = @($text -split "`r*`n" | ForEach-Object { $_.TrimEnd() } | Where-Object { $_ })
    if (-not $lines.Count) { $lines = @('(no output)') }
    return @("$head (exit code $($p.ExitCode)) ---") + $lines + @('')
}

function Get-Feature([string]$Override, [string]$Name) {
    if ($Override) { return $Override }
    try {
        return [string](Get-WindowsOptionalFeature -Online -FeatureName $Name -ErrorAction Stop).State
    } catch {
        return "unknown (could not ask Windows: $(Msg $_))"
    }
}

function YesNo($v) { if ([string]$v -eq 'True') { 'yes' } elseif ([string]$v -eq 'False') { 'no' } else { [string]$v } }

$r = New-Object System.Collections.Generic.List[string]
function Add([string[]]$lines) { foreach ($l in $lines) { $r.Add($l) } }

Write-Host 'Collecting information about WSL on this PC - this can take a minute ...'

Add @('wsl-setup diagnostics report',
      ('Saved: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' (local time)'),
      'No password is in this report. It shows your Windows account name and the',
      'names of your Linux distros. Read it before you send it to anyone.', '')

# ---- Windows -----------------------------------------------------------------
Add @('== Windows ==')
try {
    $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
    Add @("Edition: $($cv.ProductName) ($($cv.EditionID))",
          "Version: $($cv.DisplayVersion) - build $($cv.CurrentBuild).$($cv.UBR)")
} catch {
    Add @("Edition: unknown (could not read the registry: $(Msg $_))")
}
Add @("OS: $([Environment]::OSVersion.VersionString), $env:PROCESSOR_ARCHITECTURE",
      "PowerShell: $($PSVersionTable.PSVersion)", '')

# ---- this window ---------------------------------------------------------------
Add @('== This window ==')
try {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $admin = ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    Add @("Account: $($id.Name)", "Administrator: $(YesNo $admin)")
} catch {
    Add @("Account: $([Environment]::UserName)", 'Administrator: unknown')
}
Add @('Distros belong to one Windows account: they show up only for the account that installed them.', '')

# ---- features and virtualization -----------------------------------------------
Add @('== WSL features ==',
      ('Windows Subsystem for Linux: ' + (Get-Feature $WslFeature 'Microsoft-Windows-Subsystem-Linux')),
      ('Virtual Machine Platform: ' + (Get-Feature $VmpFeature 'VirtualMachinePlatform')), '')

Add @('== Virtualization ==')
$hv = $HypervisorPresent
$fw = $FirmwareVirt
if (-not $hv) {
    try { $hv = [string](Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).HypervisorPresent } catch { $hv = 'unknown' }
}
if (-not $fw) {
    try { $fw = [string](@(Get-CimInstance Win32_Processor -ErrorAction Stop)[0]).VirtualizationFirmwareEnabled } catch { $fw = 'unknown' }
}
Add @("Hypervisor running: $(YesNo $hv)",
      "Virtualization enabled in firmware (BIOS/UEFI): $(YesNo $fw)")
if ((YesNo $hv) -eq 'yes') {
    Add @('(With a hypervisor running, Windows may report the firmware setting as no - that is fine.)')
} elseif ((YesNo $fw) -eq 'no') {
    Add @('WSL 2 needs virtualization: turn on VT-x / AMD-V (SVM) in the BIOS/UEFI setup.')
}
Add @('')

Add @('== Restart pending ==')
$pending = @($RebootKeys | Where-Object { $_ -and (Test-Path -LiteralPath $_ -ErrorAction SilentlyContinue) })
if ($pending.Count) {
    Add @('yes - Windows is waiting for a restart:')
    Add (@($pending | ForEach-Object { "  $_" }))
    Add @('Restart Windows before trying again.')
} else {
    Add @('no')
}
Add @('')

# ---- distros registered for this account ----------------------------------------
Add @('== Linux distros for this account ==')
try {
    $root = Get-Item -LiteralPath $LxssKey -ErrorAction Stop
    $def = [string]$root.GetValue('DefaultDistribution')
    $subs = @(Get-ChildItem -LiteralPath $LxssKey -ErrorAction Stop)
    $n = 0
    foreach ($s in $subs) {
        $name = $s.GetValue('DistributionName')
        if (-not $name) { continue }
        $n++
        $mark = if ($def -and $s.PSChildName -eq $def) { '*' } else { ' ' }
        $info = @()
        if ($null -ne $s.GetValue('Version')) { $info += "WSL $($s.GetValue('Version'))" }
        if ($null -ne $s.GetValue('State')) { $info += "state $($s.GetValue('State'))" }
        $extra = if ($info.Count) { '   (' + ($info -join ', ') + ')' } else { '' }
        Add @("$mark $name$extra")
    }
    if ($n -eq 0) { Add @('none registered') } else { Add @('(* = default)') }
} catch {
    Add @('none registered (no WSL registry key for this account)')
}
Add @('')

# ---- wsl.exe itself ----------------------------------------------------------------
Add @('== wsl.exe ==')
$cmd = Get-Command $WslExe -ErrorAction SilentlyContinue
if (-not $cmd) {
    Add @("$WslExe was not found - WSL is not installed on this PC yet.", '')
} else {
    Add @("Path: $(@($cmd)[0].Source)", '')
    Write-Host '  asking wsl.exe for its version, status and distros ...'
    Add (Invoke-Wsl '--version' $TimeoutSec)
    Add (Invoke-Wsl '--status' $TimeoutSec)
    Add (Invoke-Wsl '--list --verbose' $TimeoutSec)
    Write-Host '  trying to start the default distro ...'
    Add @('Starting the default distro (wsl -- true). Any error below is WSL''s own message:')
    Add (Invoke-Wsl '-- true' ($TimeoutSec * 2))
}

# ---- save -------------------------------------------------------------------------
$text = ($r -join "`r`n") + "`r`n"
foreach ($s in $secrets) { if ($s) { $text = $text.Replace($s, '[removed]') } }

$name = 'wsl-setup-report-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.txt'
$saved = $null
foreach ($dir in @($OutDir, [IO.Path]::GetTempPath())) {
    if (-not $dir) { continue }
    $path = Join-Path $dir $name
    try {
        # UTF-8 with a BOM: older Notepad versions guess the encoding otherwise.
        [IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding $true))
        $saved = $path
        break
    } catch {
        Write-Host "  could not write to $dir - $(Msg $_)"
    }
}
if (-not $saved) {
    Write-Host 'The report could not be saved anywhere. Copy the folder to C:\ and try again.'
    exit 1
}
Write-Host ''
Write-Host "Report saved: $saved"
Write-Host 'Read it, then attach the file (or paste its text) when you ask for help.'
if (-not $NoOpen -and -not $env:WSL_SETUP_DIAG_NO_OPEN) {
    try { Start-Process -FilePath 'notepad.exe' -ArgumentList ('"' + $saved + '"') -ErrorAction Stop } catch { }
}
exit 0
