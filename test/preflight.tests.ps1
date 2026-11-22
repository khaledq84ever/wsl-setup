# preflight.tests.ps1 - run the real preflight.ps1 for every combination that
# matters, on PowerShell 7 and Windows PowerShell 5.1. The Windows lookups are
# replaced by its parameters (and once by its env hooks): Linux has no such
# things, and on Windows the answers would depend on the machine.
. (Join-Path $PSScriptRoot 'helpers.ps1')

$pre = Join-Path (Join-Path $PSScriptRoot '..') 'preflight.ps1'
$tmp = New-TestDir 'preflight'

$VIRT = 'Virtualization is turned off in this PC''s BIOS/UEFI setup.'
$PEND = 'Virtual Machine Platform was just turned on, and Windows has not'
$VMPOFF = 'Virtual Machine Platform is not turned on yet. The install turns it'

function Test-Pre([string]$label, [string[]]$a, [int]$wantCode, [string[]]$want, [string[]]$unwanted) {
    $r = Invoke-Script $pre $a
    $out = $r.Out + $r.Err
    if ($r.Code -eq $wantCode) { Ok } else { Bad "${label}: exit $($r.Code), want $wantCode [$out]" }
    if ($out.Contains('Checking that this PC can run WSL 2 ...')) { Ok } else { Bad "${label}: no header [$out]" }
    foreach ($w in $want) { if ($out.Contains($w)) { Ok } else { Bad "${label}: lacks [$w] [$out]" } }
    foreach ($u in $unwanted) { if (-not $out.Contains($u)) { Ok } else { Bad "${label}: has [$u] [$out]" } }
    if ($r.Err.Trim() -eq '') { Ok } else { Bad "${label}: stderr [$($r.Err)]" }
    # Every line is shown by a console that may not be UTF-8.
    if ($out -notmatch '[^\x00-\x7F]') { Ok } else { Bad "${label}: non-ASCII output" }
}
function Args3([string]$vmp, [string]$hv, [string]$fw) { @('-VmpFeature', $vmp, '-HypervisorPresent', $hv, '-FirmwareVirt', $fw) }

Write-Host '=== PREFLIGHT ==='
Test-Pre 'all fine'                         (Args3 Enabled True True)   0 @() @('[WARN]', '[INFO]')
Test-Pre 'VT on, no hypervisor yet'          (Args3 Enabled False True)  0 @() @('[WARN]', '[INFO]')
Test-Pre 'VT off in firmware'                (Args3 Enabled False False) 3 @("[WARN] $VIRT", 'Intel VT-x', 'AMD-V / SVM Mode', 'nested virtualization', 'You can continue anyway') @('[INFO]', $PEND)
# Windows reports the firmware flag as off once Hyper-V runs: not a problem.
Test-Pre 'hypervisor running, flag off'      (Args3 Enabled True False)  0 @() @('[WARN]', '[INFO]')
Test-Pre 'VMP off, VT on'                    (Args3 Disabled False True) 0 @("[INFO] $VMPOFF", 'may then need a restart') @('[WARN]')
Test-Pre 'VMP off and VT off'                (Args3 Disabled False False) 3 @("[WARN] $VIRT", "[INFO] $VMPOFF") @($PEND)
Test-Pre 'VMP being turned off'              (Args3 DisablePending True True) 0 @("[INFO] $VMPOFF") @('[WARN]')
Test-Pre 'VMP waiting for a restart'         (Args3 EnablePending True True) 3 @("[WARN] $PEND", 'Restart Windows first') @($VIRT, '[INFO]')
Test-Pre 'restart due and VT off'            (Args3 EnablePending False False) 3 @("[WARN] $VIRT", "[WARN] $PEND") @('[INFO]')
# Nothing could be read: no advice at all, rather than wrong advice.
Test-Pre 'nothing readable'                  (Args3 Unknown Unknown Unknown) 0 @() @('[WARN]', '[INFO]')

# The env hooks the end-to-end tests use.
$env:WSL_SETUP_PREFLIGHT_VMP = 'Disabled'; $env:WSL_SETUP_PREFLIGHT_HV = 'False'; $env:WSL_SETUP_PREFLIGHT_FW = 'False'
try {
    Test-Pre 'env hooks' @() 3 @("[WARN] $VIRT", "[INFO] $VMPOFF") @()
} finally {
    Remove-Item Env:WSL_SETUP_PREFLIGHT_VMP, Env:WSL_SETUP_PREFLIGHT_HV, Env:WSL_SETUP_PREFLIGHT_FW -ErrorAction SilentlyContinue
}

# No overrides: the real lookups. Off Windows they all fail -> silent. (On
# Windows the answer depends on the machine; the end-to-end tests cover it.)
if (-not $onWindows) {
    Test-Pre 'real lookups, not Windows' @() 0 @() @('[WARN]', '[INFO]')
}

Remove-TestDir
Write-Host "PREFLIGHT RESULTS: $script:pass passed, $script:fail failed"
exit ([int]($script:fail -ne 0))
