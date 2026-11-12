#!/usr/bin/env python3
"""mutate.py - mutation run for the helper scripts wsl-setup.bat ships: the
four PowerShell helpers and the two shell scripts that run inside the distro.

For each helper it plants one deliberate bug at a time (wrong exit code,
inverted check, a dropped argument, a removed safety step ...), runs that
helper's unit tests and reports whether they noticed. The file is restored
afterwards, also on Ctrl-C. Exit code 1 if a mutant survives - that is a gap
in the tests, not in the helper.

  python3 test/mutation/mutate.py                 all helpers
  python3 test/mutation/mutate.py wait install    only these (wait, install, list, status,
                                                  user, devtools)

PWSH=... picks the PowerShell (default pwsh); PWSH=powershell runs it on
Windows PowerShell 5.1, as the CI "mutation" job does. Mutants marked PS51
only show on 5.1 (they undo a 5.1 workaround) and are skipped elsewhere.

The shell scripts (user, devtools) are tested by test/run-tests.sh, run here
with ITER=2 and without its PowerShell and end-to-end parts. Only
enable_systemd is mutated in setup-dev-tools.sh: the rest of that script
installs packages and is only run for real, by the real-WSL CI job.

Not part of test/run-tests.sh: it takes several minutes, because a mutant
that makes a helper wait forever is only caught by its tests hanging.
"""
import os, signal, subprocess, sys
HANG = int(os.environ.get("MUTATION_HANG_SEC", "90"))   # a run of the tests takes a few seconds
repo = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
pwsh = os.environ.get("PWSH", "pwsh")
PS51 = os.path.basename(pwsh).lower().replace(".exe", "") == "powershell"

PROBE = "    & $WslExe -d $Distro -u root -- true 2>$null | Out-Null\n    if ($LASTEXITCODE -eq 0) { Write-Progress -Activity done -Completed; exit 0 }\n"
REBOOT = ("    foreach ($k in $RebootKeys) {\n        if (Test-Path -LiteralPath $k -ErrorAction SilentlyContinue) {\n"
          "            Write-Progress -Activity done -Completed\n            exit 2\n        }\n    }\n")
WAIT = [
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

INSTALL = [
 ("--web-download dropped", "'--no-launch', '--web-download')", "'--no-launch')"),
 ("--no-launch dropped", "'-d', $Distro, '--no-launch', ", "'-d', $Distro, "),
 ("exit code replaced by 0", "exit $code\n", "exit 0\n"),
 ("failure details shown on success instead of failure", "if ($code -ne 0) {", "if ($code -eq 0) {"),
 ("UTF-16 log not cleaned of NULs", "return ([string]$text) -replace \"`0\", ''", "return ([string]$text)"),
 ("wsl.exe cannot be started: exit 1 -> exit 0", "-ErrorAction SilentlyContinue\n    exit 1\n", "-ErrorAction SilentlyContinue\n    exit 0\n"),
 ("log files left behind after a run", "Remove-Item -LiteralPath $outLog, $errLog -ErrorAction SilentlyContinue\nexit $code", "exit $code"),
 ("log files left behind when wsl.exe cannot be started", "    Remove-Item -LiteralPath $outLog, $errLog -ErrorAction SilentlyContinue\n    exit 1", "    exit 1"),
 ("PS51: .Handle not touched (exit code lost)", "$null = $proc.Handle\n", ""),
 # Three guards cover the same 5.1 quirk (Get-Content -Raw of an empty file
 # is $null); removing any one alone changes nothing, so all three go.
 ("PS51: empty log handled as $null (all three guards removed)", [
     ("    if ($null -eq $text) { return '' }\n", ""),
     ("return ([string]$text) -replace", "return $text -replace"),
     ("[regex]::Matches([string](Read-WslLog $outLog),", "[regex]::Matches((Read-WslLog $outLog),")], None),
]

LIST = [
 ("one space is enough for a row (prose becomes distros)", "[A-Za-z0-9._-]*)\\s{2,}(\\S.*)$'", "[A-Za-z0-9._-]*)\\s{1,}(\\S.*)$'"),
 ("column header not skipped", "            if ($name -cnotmatch '[a-z]') { continue }   # the column header\n", ""),
 ("every all-caps name skipped, not just the header", "            $first = $false\n", ""),
 ("duplicates kept", "        if ($seen.ContainsKey($name)) { continue }\n", ""),
 ("cmd-special characters left in the friendly name", " -replace '[!^|%\"]', '').Trim()", ").Trim()"),
 ("empty friendly name not replaced by the name", "        if (-not $friendly) { $friendly = $name }\n", ""),
 ("fields swapped", "'{0}|{1}' -f", "'{1}|{0}' -f"),
 ("cannot run wsl.exe: exit 2 -> exit 0", "$($_.Exception.Message)\")\n    exit 2\n", "$($_.Exception.Message)\")\n    exit 0\n"),
 ("no rows: exit 1 -> exit 0", ".Trim())\n    exit 1\n", ".Trim())\n    exit 0\n"),
 ("rows printed: exit 0 -> exit 1", "$r.Friendly }\nexit 0\n", "$r.Friendly }\nexit 1\n"),
 ("what wsl.exe said is not shown when there are no rows", "    [Console]::Error.WriteLine(($text -replace \"`0\", '').Trim())\n", ""),
 ("stderr of wsl.exe dropped", " + \"`n\" + (ConvertFrom-WslBytes $err.ToArray())", ""),
 ("timeout 100x longer", "$p.WaitForExit($TimeoutSec * 1000)", "$p.WaitForExit($TimeoutSec * 100000)"),
]

STATUS = [
 ("version taken from the last line, not the first", "Select-Object -First 1)", "Select-Object -Last 1)"),
 ("a failed --version is still trusted", "    if ($p.ExitCode -ne 0) { return $null }\n", ""),
 ("store WSL: exit 0 -> exit 1", "'OK|WSL is installed - version ' + $ver\n        exit 0", "'OK|WSL is installed - version ' + $ver\n        exit 1"),
 ("built-in WSL: exit 0 -> exit 1", "built-in Windows version'\n    exit 0", "built-in Windows version'\n    exit 1"),
 ("feature on counts as installed even without wsl.exe", "if ($haveExe -and $state -eq 'Enabled') {", "if ($state -eq 'Enabled') {"),
 ("restart pending: exit 1 -> exit 0", "then run this tool again.'\n    exit 1", "then run this tool again.'\n    exit 0"),
 ("restart pending not recognised", "if ($state -eq 'EnablePending') {", "if ($state -eq 'NoSuchState') {"),
 ("missing wsl.exe not treated as not installed", "if (-not $haveExe -or $state -eq 'Disabled'", "if ($state -eq 'Disabled'"),
 ("feature Disabled not treated as not installed", "-or $state -eq 'Disabled' -or", "-or"),
 ("feature DisablePending not treated as not installed", " -or $state -eq 'DisablePending') {", ") {"),
 ("not installed: exit 1 -> exit 0", "Windows may need a restart.'\n    exit 1", "Windows may need a restart.'\n    exit 0"),
 ("unknown: exit 2 -> exit 0", "continuing anyway.'\nexit 2", "continuing anyway.'\nexit 0"),
 ("timeout 100x longer", "$p.WaitForExit($TimeoutSec * 1000)", "$p.WaitForExit($TimeoutSec * 100000)"),
]

USER = [
 ("user name not base64-decoded", "u=$(printf '%s' \"$USER_B64\" | base64 -d)", "u=$USER_B64"),
 ("password not base64-decoded", "p=$(printf '%s' \"$PASS_B64\" | base64 -d)", "p=$PASS_B64"),
 ("account never created", "id -u \"$u\" >/dev/null 2>&1 || useradd -m -s /bin/bash \"$u\"\n", ""),
 ("account created even if it exists", "id -u \"$u\" >/dev/null 2>&1 || useradd", "useradd"),
 ("no home directory (-m dropped)", "useradd -m -s /bin/bash", "useradd -s /bin/bash"),
 ("login shell not bash", "useradd -m -s /bin/bash", "useradd -m -s /bin/sh"),
 ("password set to the user name", "printf '%s:%s\\n' \"$u\" \"$p\" | chpasswd", "printf '%s:%s\\n' \"$u\" \"$u\" | chpasswd"),
 ("password never set", "printf '%s:%s\\n' \"$u\" \"$p\" | chpasswd\n", ""),
 ("not added to the sudo group", "usermod -aG sudo \"$u\" 2>/dev/null || usermod", "usermod"),
 ("no wheel fallback", "|| usermod -aG wheel \"$u\" 2>/dev/null || true", "|| true"),
 ("a missing admin group aborts the script", "usermod -aG wheel \"$u\" 2>/dev/null || true", "usermod -aG wheel \"$u\" 2>/dev/null"),
 ("sudoers.d not created", "mkdir -p \"$SUDOERS_DIR\"\n", ""),
 ("sudo still asks for a password", "ALL=(ALL) NOPASSWD:ALL\\n'", "ALL=(ALL) ALL\\n'"),
 ("sudoers file world-readable", "chmod 0440", "chmod 0644"),
 ("sudo not installed with apt-get", "DEBIAN_FRONTEND=noninteractive apt-get install -y sudo; }", "true; }"),
 ("sudo not installed with dnf", "dnf install -y sudo ||", "true ||"),
 ("sudo not installed with pacman", "pacman -Syu --noconfirm --needed sudo ||", "true ||"),
 ("sudo not installed with zypper", "zypper --non-interactive install sudo ||", "true ||"),
 ("a failed sudo install aborts account creation", "|| echo \"WARN: could not install sudo via dnf\" >&2", ""),
 ("no package manager aborts account creation", "        echo \"WARN: no known package manager found - install sudo manually\" >&2\n", "        exit 1\n"),
 ("indented [user] section not recognised", "grep -Eq '^[[:space:]]*\\[user\\]'", "grep -q '^\\[user\\]'"),
 ("spaced default = not recognised", "grep -Eq '^[[:space:]]*default[[:space:]]*='", "grep -q '^default='"),
 ("existing default not replaced", "sed -i -E \"s/^[[:space:]]*default[[:space:]]*=.*/default=$u/\"", "sed -i -E \"s/^nothing$/default=$u/\""),
 ("default not added under an existing [user]", "sed -i -E \"/^[[:space:]]*\\[user\\]/a default=$u\"", "sed -i -E \"/^nothing$/a default=$u\""),
 ("existing wsl.conf overwritten", "printf '\\n[user]\\ndefault=%s\\n' \"$u\" >> \"$CONF_FILE\"", "printf '\\n[user]\\ndefault=%s\\n' \"$u\" > \"$CONF_FILE\""),
 ("[user] glued onto an unterminated last line", "printf '\\n[user]\\ndefault=%s\\n' \"$u\" >>", "printf '[user]\\ndefault=%s\\n' \"$u\" >>"),
 ("no wsl.conf written on a fresh distro", "    printf '[user]\\ndefault=%s\\n' \"$u\" > \"$CONF_FILE\"\n", "    :\n"),
]

DEVTOOLS = [
 ("already enabled: return 1 -> 0", "*true[[:space:]]*$' \"$conf\"; then\n        return 1", "*true[[:space:]]*$' \"$conf\"; then\n        return 0"),
 ("changed: return 0 -> 1", "    fi\n    return 0\n}", "    fi\n    return 1\n}"),
 ("any systemd= line counts as enabled", "systemd[[:space:]]*=[[:space:]]*true[[:space:]]*$' \"$conf\"; then", "systemd[[:space:]]*=' \"$conf\"; then"),
 ("systemd=false not flipped", "s/^[[:space:]]*systemd[[:space:]]*=.*/systemd=true/'", "s/^[[:space:]]*systemd[[:space:]]*=.*/systemd=false/'"),
 ("existing systemd= line ignored (second one added)", "if [ -f \"$conf\" ] && grep -Eq '^[[:space:]]*systemd[[:space:]]*=' \"$conf\"; then", "if false; then"),
 ("existing [boot] ignored (second one added)", "elif [ -f \"$conf\" ] && grep -Eq '^[[:space:]]*\\[boot\\]' \"$conf\"; then", "elif false; then"),
 ("[boot] glued onto an unterminated last line", "nl=$'\\n'", "nl=''"),
 ("wsl.conf overwritten instead of appended", "| $SUDO tee -a \"$conf\" >/dev/null", "| $SUDO tee \"$conf\" >/dev/null"),
]

TARGETS = {
    "wait":    ("wait-distro.ps1",    "install-wait.tests.ps1", WAIT),
    "install": ("install-distro.ps1", "install-wait.tests.ps1", INSTALL),
    "list":    ("list-distros.ps1",   "list-distros.tests.ps1", LIST),
    "status":  ("wsl-status.ps1",     "wsl-status.tests.ps1",   STATUS),
    "user":     ("setup-user.sh",      "run-tests.sh", USER),
    "devtools": ("setup-dev-tools.sh", "run-tests.sh", DEVTOOLS),
}


def run_tests(test, fail_fast=True):
    """-> (killed, detail). Stops the whole process tree if the tests hang.
    With a mutant in place the tests stop at their first failure (see
    helpers.ps1): that is all a mutation run needs, and it is much faster."""
    env = dict(os.environ)
    if fail_fast:
        env["TEST_FAIL_FAST"] = "1"
    if test.endswith(".sh"):
        # The shell harness only: few iterations, no PowerShell tests (they do
        # not touch the shell scripts), no end-to-end run.
        env.update({"ITER": "2", "PWSH": "no-such-pwsh-for-mutation"})
        env.pop("E2E", None)
        cmd = ["bash", os.path.join(repo, "test", test)]
    else:
        cmd = [pwsh, "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", os.path.join(repo, "test", test)]
    p = subprocess.Popen(cmd,
                         stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=env,
                         start_new_session=(os.name != "nt"))
    try:
        out, _ = p.communicate(timeout=HANG)
    except subprocess.TimeoutExpired:
        # A mutant that never returns leaves the test's own child looping
        # forever: stop the whole tree, not just the test process.
        if os.name == "nt":
            subprocess.run(["taskkill", "/T", "/F", "/PID", str(p.pid)], capture_output=True)
        else:
            os.killpg(p.pid, signal.SIGKILL)
        p.communicate()
        return True, f"(tests hang > {HANG} s)"
    fails = [l.strip() for l in out.splitlines() if "FAIL" in l]
    return p.returncode != 0, (fails[0][:100] if fails else "")


def mutate(key):
    target, test, mutants = TARGETS[key]
    path = os.path.join(repo, target)
    orig = open(path, "rb").read()
    norm = orig.decode().replace("\r\n", "\n")
    print(f"=== {target}  (tests: {test}) ===", flush=True)
    killed, detail = run_tests(test, fail_fast=False)
    if killed:
        sys.exit(f"the tests fail without any mutant: {detail} - fix that first")
    ran = survived = 0
    try:
        for name, old, new in mutants:
            edits = old if isinstance(old, list) else [(old, new)]   # a mutant may need several edits
            for o, _ in edits:
                assert norm.count(o) == 1, f"{target}: mutant {name!r} matches {norm.count(o)} places - mutate.py is out of date"
            if name.startswith("PS51:") and not PS51:
                print(f"skipped   {name}", flush=True)
                continue
            text = norm
            for o, n in edits:
                text = text.replace(o, n)
            open(path, "w", newline="\n").write(text)
            killed, detail = run_tests(test)
            ran += 1
            survived += not killed
            print(f"{'KILLED  ' if killed else 'SURVIVED'}  {name}   {detail}", flush=True)
    finally:
        open(path, "wb").write(orig)
    print(f"{ran - survived}/{ran} mutants killed, {survived} survived\n", flush=True)
    return survived


keys = sys.argv[1:] or list(TARGETS)
for k in keys:
    if k not in TARGETS:
        sys.exit(f"unknown helper {k!r} - choose from {', '.join(TARGETS)}")
total = sum(mutate(k) for k in keys)
print(f"TOTAL: {total} mutant(s) survived" if total else "TOTAL: every mutant was killed")
sys.exit(1 if total else 0)
