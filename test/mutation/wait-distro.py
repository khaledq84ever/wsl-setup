#!/usr/bin/env python3
"""wait-distro.py - mutation run for wait-distro.ps1.

Applies one deliberate bug at a time to wait-distro.ps1 (wrong exit code,
inverted probe result, restart check moved or removed, timeout broken), runs
its unit tests (test/install-wait.tests.ps1) and reports whether they noticed.
The file is restored afterwards, also on Ctrl-C. Exit code 1 if a mutant
survives - that is a gap in the tests, not in wait-distro.ps1.

Not part of test/run-tests.sh (it takes a few minutes: one mutant can only be
caught by the tests hanging). Run it after changing wait-distro.ps1 or its
tests:   python3 test/mutation/wait-distro.py        (PWSH=... if not on PATH)
"""
import os, subprocess, sys
repo = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
pwsh = os.environ.get("PWSH", "pwsh")
path = os.path.join(repo, "wait-distro.ps1")
orig = open(path, "rb").read().decode()
PROBE = "    & $WslExe -d $Distro -u root -- true 2>$null | Out-Null\n    if ($LASTEXITCODE -eq 0) { Write-Progress -Activity done -Completed; exit 0 }\n"
REBOOT = ("    foreach ($k in $RebootKeys) {\n        if (Test-Path -LiteralPath $k -ErrorAction SilentlyContinue) {\n"
          "            Write-Progress -Activity done -Completed\n            exit 2\n        }\n    }\n")
M = [
 ("A ready: exit 0 -> exit 1", "-Completed; exit 0 }", "-Completed; exit 1 }"),
 ("B restart pending: exit 2 -> exit 1", "            exit 2\n", "            exit 1\n"),
 ("C restart pending: exit 2 -> exit 0", "            exit 2\n", "            exit 0\n"),
 ("D gave up: exit 1 -> exit 0", "-Completed\nexit 1\n", "-Completed\nexit 0\n"),
 ("E gave up: exit 1 -> exit 2", "-Completed\nexit 1\n", "-Completed\nexit 2\n"),
 ("F probe result inverted (-eq 0 -> -ne 0)", "$LASTEXITCODE -eq 0", "$LASTEXITCODE -ne 0"),
 ("G negative probe result counts as ready (-eq 0 -> -le 0)", "$LASTEXITCODE -eq 0", "$LASTEXITCODE -le 0"),
 ("H restart check before the probe (ready distro + pending key -> 2)", PROBE + REBOOT, REBOOT + PROBE),
 ("I restart check removed", REBOOT, ""),
 ("J never gives up (timeout break removed)", "    if ($elapsed -ge $TimeoutSec) { break }\n", ""),
 ("K gives up at once (-ge -> -lt)", "$elapsed -ge $TimeoutSec", "$elapsed -lt $TimeoutSec"),
]
norm = orig.replace("\r\n", "\n")
survived = 0
try:
    for name, old, new in M:
        assert norm.count(old) == 1, (name, norm.count(old))
        open(path, "w", newline="\n").write(norm.replace(old, new))
        try:
            r = subprocess.run([pwsh, "-NoProfile", "-File", os.path.join(repo, "test", "install-wait.tests.ps1")],
                               capture_output=True, text=True, timeout=90)
            fails = [l.strip() for l in r.stdout.splitlines() if "FAIL" in l or l.strip().startswith("BAD")]
            verdict = "KILLED" if r.returncode != 0 else "SURVIVED"
            detail = fails[0][:110] if fails else ""
        except subprocess.TimeoutExpired:
            verdict, detail = "KILLED (tests hang > 90 s)", ""
        survived += verdict == "SURVIVED"
        print(f"{verdict:28} {name}   {detail}", flush=True)
finally:
    open(path, "wb").write(orig.encode())
print(f"\n{len(M) - survived}/{len(M)} mutants killed, {survived} survived")
sys.exit(1 if survived else 0)
