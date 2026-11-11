#!/usr/bin/env python3
"""run_real_wsl.py - run the REAL wsl-setup.bat against REAL WSL: Microsoft's
wsl.exe and a real Linux distro. Nothing is faked. Round 1 picks WSL_DISTRO
(default Debian) from the live menu, so the .bat really runs
`wsl --install -d Debian --no-launch --web-download` and waits for it; round 2
runs the .bat again and takes the "already installed" path. The CI job uses
Vampire/setup-wsl first, to make sure WSL itself works on the runner and so
another distro is registered (the .bat must take over the machine default).

Checked inside the distro afterwards: the account exists, its password hash
matches exactly what was typed (cmd/PowerShell special characters included),
passwordless sudo works, wsl.conf makes it the default user, the distro is
the machine default, and no temp script is left in /tmp. Then the .bat runs a
second time on the same distro (idempotent re-run), this time answering "y"
to the dev-tools prompt, so setup-dev-tools.sh really installs nvm/Node,
Docker and gh; those, the docker group and wsl.conf are checked as well.

Reuses the real-console driver from run_e2e_windows.py. Like that script it
refuses to run unless E2E_WINDOWS_CI=1: it creates a sudo-enabled account in
whichever distro WSL_DISTRO names - CI machines only.
"""
import os, re, subprocess, sys, tempfile, winreg

import run_e2e_windows as base  # exits unless E2E_WINDOWS_CI=1
from run_e2e_windows import Console, REPO, LXSS

USER = "dev"
PW = 'P@ss!w^rd %x% "q"'
MENU, UPROMPT, KEY = "Choose an option: ", "New Linux username: ", "Press any key"
PWD1, PWD2 = "New Linux password", "Confirm password"
DEV, AGAIN = "[y/n]: ", "(y/n): "

passed = failed = 0


def check(cond, msg):
    global passed, failed
    if cond:
        passed += 1
    else:
        failed += 1
        print(f"  FAIL: {msg}", flush=True)


def registered():
    names = []
    try:
        k = winreg.OpenKey(winreg.HKEY_CURRENT_USER, LXSS)
    except OSError:
        return names
    i = 0
    while True:
        try:
            sub = winreg.EnumKey(k, i); i += 1
        except OSError:
            break
        with winreg.OpenKey(k, sub) as sk:
            try:
                names.append(winreg.QueryValueEx(sk, "DistributionName")[0])
            except OSError:
                pass
    return names


def wsl(distro, user, *argv, env=None):
    """wsl.exe --exec: argv goes to the program directly, no Linux shell."""
    e = dict(os.environ)
    e.update(env or {})
    e["WSL_UTF8"] = "1"
    r = subprocess.run(["wsl.exe", "-d", distro, "-u", user, "--exec", *argv],
                       capture_output=True, env=e, timeout=120)
    return r.returncode, r.stdout.decode("utf-8", "replace").replace("\0", "").strip()


def menu_number(distro):
    """The menu shows friendly names only; map them back via list-distros.ps1,
    which is what the .bat itself parsed."""
    r = subprocess.run(["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
                        os.path.join(REPO, "list-distros.ps1")], capture_output=True, text=True, timeout=120)
    rows = [l.split("|", 1) for l in r.stdout.splitlines() if "|" in l]
    if not rows:  # the .bat would have shown its fixed fallback menu
        rows = [["Ubuntu", "Ubuntu - latest LTS"], ["Debian", "Debian"]]
    for i, (name, _friendly) in enumerate(rows, 1):
        if name.lower() == distro.lower():
            return str(i)
    sys.exit(f"{distro} is not in the menu {rows} - pick a distribution that wsl --list --online offers")


def run_bat(distro, round_name, dev_tools=False):
    was_installed = distro.lower() in [n.lower() for n in registered()]
    print(f"=== REAL WSL {round_name}: wsl-setup.bat, {distro} "
          f"{'already registered' if was_installed else 'not installed yet'} ===", flush=True)
    num = menu_number(distro)
    con = Console(["cmd.exe", "/c", os.path.join(REPO, "wsl-setup.bat")], REPO, dict(os.environ))
    dev = ([[DEV, "y"], ["Dev-tools setup finished.", None], [KEY, ""]] if dev_tools else [[DEV, "n"]])
    err = con.drive([
        [MENU, num], [UPROMPT, USER], [PWD1, PW], [PWD2, PW],
        ["Registration complete.", None], [KEY, ""]] + dev + [[AGAIN, "n"], ["Done.", None], [KEY, ""]])
    out = con.text()
    log = os.path.join(tempfile.gettempdir(), f"real-wsl-{round_name}.txt")
    open(log, "w", encoding="utf-8").write(out)
    before = failed
    check(err is None, f"driver: {err}")
    if was_installed:
        check("is already installed - skipping install," in out, "not detected as already installed")
    else:
        check("Installing " in out and "already installed - skipping install" not in out, "did not run the install")
        check(distro.lower() in [n.lower() for n in registered()], f"{distro} not registered after the install")
    for s in (f'[OK] User "{USER}" is registered in', f'[OK] "{USER}" is set as the default user',
              '[OK] Typing "wsl" in any cmd/PowerShell window now logs straight'):
        check(s in out, f"console lacks {s!r}")
    check("[ERROR]" not in out and "[WARN]" not in out, "console shows an [ERROR] or [WARN]")
    return failed > before, out


def check_distro(distro):
    rc, o = wsl(distro, "root", "getent", "passwd", USER)
    check(rc == 0 and o.startswith(USER + ":"), f"getent passwd {USER}: rc={rc} {o!r}")
    # The stored hash must verify against exactly the typed password.
    perl = ("my @p = getpwnam($ENV{U}); my $h = $p[1]; "
            "exit((length($h) > 1 && crypt($ENV{PWCHK}, $h) eq $h) ? 0 : 1)")
    rc, o = wsl(distro, "root", "perl", "-e", perl,
                env={"U": USER, "PWCHK": PW, "WSLENV": "U:PWCHK"})
    check(rc == 0, f"password hash does not match the typed password (rc={rc} {o!r})")
    rc, o = wsl(distro, USER, "sudo", "-n", "id", "-u")
    check(rc == 0 and o == "0", f"passwordless sudo: rc={rc} {o!r}")
    rc, o = wsl(distro, "root", "cat", "/etc/sudoers.d/" + USER)
    check(o == f"{USER} ALL=(ALL) NOPASSWD:ALL", f"sudoers file: {o!r}")
    rc, o = wsl(distro, "root", "sh", "-c", "ls -A /tmp | grep '^wsl_setup_' || true")
    check(o == "", f"temp scripts left in /tmp: {o!r}")
    r = subprocess.run(["wsl.exe", "-d", distro, "--exec", "whoami"], capture_output=True,
                       env=dict(os.environ, WSL_UTF8="1"), timeout=120)
    check(r.stdout.decode("utf-8", "replace").replace("\0", "").strip() == USER, f"default user is not {USER}")
    r = subprocess.run(["wsl.exe", "--exec", "whoami"], capture_output=True,
                       env=dict(os.environ, WSL_UTF8="1"), timeout=120)
    check(r.stdout.decode("utf-8", "replace").replace("\0", "").strip() == USER, "plain `wsl` does not open as the new user")


def check_dev_tools(distro):
    """setup-dev-tools.sh really ran in the distro, as the new user."""
    rc, o = wsl(distro, USER, "bash", "-c", ". ~/.nvm/nvm.sh && node -v")
    check(rc == 0 and o.startswith("v"), f"node via nvm: rc={rc} {o!r}")
    for tool in ("gh", "docker"):
        rc, o = wsl(distro, USER, tool, "--version")
        check(rc == 0, f"{tool} --version: rc={rc} {o!r}")
    rc, o = wsl(distro, "root", "id", "-nG", USER)
    check("docker" in o.split(), f"{USER} not in the docker group: {o!r}")
    # Both scripts write wsl.conf; neither may clobber the other's key.
    rc, o = wsl(distro, "root", "cat", "/etc/wsl.conf")
    lines = [l.strip() for l in o.splitlines()]
    check(f"default={USER}" in lines and "systemd=true" in lines, f"wsl.conf lost a key: {o!r}")


def main():
    distro = os.environ.get("WSL_DISTRO", "Debian")
    print(f"registered before the test: {registered()}", flush=True)
    shown = []
    for rnd in ("first-run", "re-run"):
        dev_tools = rnd == "re-run"   # round 2 also installs the dev tools for real
        broke, out = run_bat(distro, rnd, dev_tools)
        check_distro(distro)
        if dev_tools:
            before = failed
            check_dev_tools(distro)
            broke = broke or failed > before
        if broke:
            shown.append((rnd, out))
    for rnd, out in shown:
        print(f"----- {rnd} console -----\n{out}\n-----")
    print(f"\n REAL WSL RESULTS: {passed} passed, {failed} failed", flush=True)
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
