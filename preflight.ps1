<#
preflight.ps1 - before wsl-setup.bat installs a distro, check that this PC can
run it: virtualization turned on in the firmware, and the Virtual Machine
Platform feature. Prints plain-language advice itself (the .bat does not
parse it) and never changes anything.

Exit codes, for the .bat:
  0 = nothing in the way (an [INFO] line may have been printed)
  3 = a [WARN] was printed - the .bat asks "Continue anyway?"
  (not 1: PowerShell exits 1 when a script fails, which is no warning)

Rules:
- Virtualization: a running hypervisor proves it is on, whatever the firmware
  flag says (Windows reports the flag as off once Hyper-V runs). Otherwise a
  firmware flag of False means it is off: WSL 2 distros cannot start -> WARN.
- Virtual Machine Platform Disabled: [INFO] only - wsl --install turns it on,
  then Windows needs a restart. EnablePending: it was just turned on and the
  restart is still due -> WARN.
- Anything that cannot be read stays silent: no advice is better than wrong
  advice, and wsl.exe reports real problems itself.

-VmpFeature / -HypervisorPresent / -FirmwareVirt replace the lookups, for the
tests (test/preflight.tests.ps1). The end-to-end tests cannot pass parameters
and use WSL_SETUP_PREFLIGHT_VMP / _HV / _FW instead. Unset in normal use.
#>
param(
    [string]$VmpFeature = $env:WSL_SETUP_PREFLIGHT_VMP,
    [string]$HypervisorPresent = $env:WSL_SETUP_PREFLIGHT_HV,
    [string]$FirmwareVirt = $env:WSL_SETUP_PREFLIGHT_FW
)
$ErrorActionPreference = 'Stop'

Write-Host 'Checking that this PC can run WSL 2 ...'

$vmp = $VmpFeature
if (-not $vmp) {
    try { $vmp = [string](Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -ErrorAction Stop).State } catch { $vmp = '' }
}
$hv = $HypervisorPresent
if (-not $hv) {
    try { $hv = [string](Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).HypervisorPresent } catch { $hv = '' }
}
$fw = $FirmwareVirt
if (-not $fw) {
    try { $fw = [string](@(Get-CimInstance Win32_Processor -ErrorAction Stop)[0]).VirtualizationFirmwareEnabled } catch { $fw = '' }
}

function Say([string]$tag, [ConsoleColor]$color, [string[]]$lines) {
    Write-Host ''
    Write-Host $tag -ForegroundColor $color -NoNewline
    Write-Host (' ' + $lines[0])
    foreach ($l in @($lines | Select-Object -Skip 1)) { Write-Host ('       ' + $l) }
}

$warn = $false
if ($hv -ne 'True' -and $fw -eq 'False') {
    $warn = $true
    Say '[WARN]' Yellow @(
        'Virtualization is turned off in this PC''s BIOS/UEFI setup.',
        'WSL 2 - which new distros use - cannot start without it.',
        'How to fix: restart the PC, open the BIOS/UEFI setup (often F2, F10,',
        'Del or Esc right at power-on) and turn on Intel VT-x / Virtualization',
        'Technology, or AMD-V / SVM Mode. Save, restart, run this tool again.',
        'In a virtual machine, turn on nested virtualization for it instead.',
        'You can continue anyway: the install may finish, but the distro will',
        'not start until virtualization is on.')
}
if ($vmp -eq 'EnablePending') {
    $warn = $true
    Say '[WARN]' Yellow @(
        'Virtual Machine Platform was just turned on, and Windows has not',
        'restarted since. Restart Windows first, then run this tool again.')
} elseif ($vmp -eq 'Disabled' -or $vmp -eq 'DisablePending') {
    Say '[INFO]' Cyan @(
        'Virtual Machine Platform is not turned on yet. The install turns it',
        'on for you; Windows may then need a restart before the distro starts.',
        'If this tool asks for a restart, restart and run it again.')
}
Write-Host ''
if ($warn) { exit 3 }
exit 0
