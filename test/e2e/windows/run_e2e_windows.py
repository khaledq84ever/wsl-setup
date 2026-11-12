#!/usr/bin/env python3
"""run_e2e_windows.py - run the REAL wsl-setup.bat on REAL Windows: Microsoft's
cmd.exe and Windows PowerShell 5.1, inside a real console (ConPTY via
pywinpty), typing answers when each prompt appears. Only wsl.exe is faked
(WslShim.cs -> ../fake_windows.py); the registry check, fltmc, Read-Host,
the build-number check and every PowerShell script run for real.

This is the counterpart of ../run-e2e.sh (Wine). Unlike Wine it can also
check the menu text itself.

It hides C:\\Windows\\System32\\wsl.exe for the duration (so nothing can reach
the real one) and therefore refuses to run unless E2E_WINDOWS_CI=1 - meant
for throwaway CI machines, not your PC.

Needs: Windows, Python 3 with pywinpty, Git for Windows (bash).
"""
import json, os, re, shutil, subprocess, sys, tempfile, threading, time, uuid, winreg

if os.environ.get("E2E_WINDOWS_CI") != "1":
    sys.exit("refusing to run: set E2E_WINDOWS_CI=1 (this test hides System32\\wsl.exe; CI machines only)")

from winpty import PtyProcess  # pip install pywinpty

HERE = os.path.dirname(os.path.abspath(__file__))
E2E = os.path.dirname(HERE)
REPO = os.path.dirname(os.path.dirname(E2E))
FAKE = os.path.join(E2E, "fake_windows.py")
SYS_WSL = os.path.join(os.environ["SystemRoot"], "System32", "wsl.exe")
LXSS = r"Software\Microsoft\Windows\CurrentVersion\Lxss"
STEP_TIMEOUT = float(os.environ.get("E2E_STEP_TIMEOUT", "180"))
# An OSC (window title etc.) ends at BEL or at ST (ESC \\) and never spans
# another ESC: matching "up to the next BEL" let one ST-terminated title
# swallow all console text up to the BEL in a later bash prompt.
ANSI = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b[=>()][0-9A-Za-z]?")

passed = failed = 0
SCEN = ""


def ok():
    global passed
    passed += 1


def bad(msg):
    global failed
    failed += 1
    print(f"  FAIL [{SCEN}]: {msg}", flush=True)


def find_bash():
    for c in (os.environ.get("E2E_BASH"), r"C:\Program Files\Git\bin\bash.exe"):
        if c and os.path.exists(c):
            return c
    sys.exit("Git Bash not found (set E2E_BASH)")


def build_shim(bindir):
    csc = os.path.join(os.environ["SystemRoot"], r"Microsoft.NET\Framework64\v4.0.30319\csc.exe")
    subprocess.run([csc, "/nologo", "/out:" + os.path.join(bindir, "wsl.exe"),
                    os.path.join(HERE, "WslShim.cs")], check=True)


def hide_system_wsl():
    """Rename System32\\wsl.exe away so every lookup lands on the fake.
    Returns the hidden path (or None if there was nothing to hide)."""
    if not os.path.exists(SYS_WSL):
        return None
    hidden = SYS_WSL + ".e2e-hidden"
    subprocess.run(["takeown", "/f", SYS_WSL], check=True, capture_output=True)
    subprocess.run(["icacls", SYS_WSL, "/grant", "Administrators:F"], check=True, capture_output=True)
    os.replace(SYS_WSL, hidden)
    return hidden


def clear_fake_lxss():
    try:
        k = winreg.OpenKey(winreg.HKEY_CURRENT_USER, LXSS, 0, winreg.KEY_ALL_ACCESS)
    except OSError:
        return
    subs = []
    i = 0
    while True:
        try:
            subs.append(winreg.EnumKey(k, i)); i += 1
        except OSError:
            break
    for sname in subs:
        sk = winreg.OpenKey(k, sname)
        try:
            fake = winreg.QueryValueEx(sk, "E2EFake")[0] == 1
        except OSError:
            fake = False
        winreg.CloseKey(sk)
        if fake:
            winreg.DeleteKey(k, sname)
    winreg.CloseKey(k)


def pre_register(name):
    k = winreg.CreateKey(winreg.HKEY_CURRENT_USER, LXSS + "\\{" + str(uuid.uuid4()) + "}")
    winreg.SetValueEx(k, "DistributionName", 0, winreg.REG_SZ, name)
    winreg.SetValueEx(k, "E2EFake", 0, winreg.REG_DWORD, 1)
    winreg.CloseKey(k)


class Console:
    """The .bat in a real console. text() is everything shown, ANSI stripped."""

    def __init__(self, cmdline, cwd, env):
        self.p = PtyProcess.spawn(cmdline, cwd=cwd, env=env, dimensions=(60, 220))
        self.raw = []
        self.lock = threading.Lock()
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        while True:
            try:
                chunk = self.p.read(4096)
            except EOFError:
                return
            except Exception:
                if not self.p.isalive():
                    return
                time.sleep(0.05); continue
            with self.lock:
                self.raw.append(chunk)

    def text(self):
        with self.lock:
            t = "".join(self.raw)
        return ANSI.sub("", t).replace("\r", "")

    def drive(self, steps):
        pos = 0
        for expect, answer, *limit in steps:   # optional 3rd item: this step's own timeout
            deadline = time.time() + (limit[0] if limit else STEP_TIMEOUT)
            while True:
                t = self.text()
                i = t.find(expect, pos)
                if i >= 0:
                    pos = i + len(expect)
                    break
                if not self.p.isalive():
                    time.sleep(0.5)
                    return f"script exited while waiting for {expect!r}"
                if time.time() > deadline:
                    self.p.terminate(force=True)   # never leave a console running behind a failed step
                    return f"timed out waiting for {expect!r}"
                time.sleep(0.05)
            if answer is None:
                continue
            time.sleep(0.3)
            self.p.write(answer + "\r")
        deadline = time.time() + STEP_TIMEOUT
        while self.p.isalive() and time.time() < deadline:
            time.sleep(0.2)
        if self.p.isalive():
            self.p.terminate(force=True)
            return "script did not exit after the last answer"
        time.sleep(0.5)
        return None


def run_scenario(name, state, steps, work, bindir, bash, bat="wsl-setup.bat"):
    global SCEN
    SCEN = name
    st = os.path.join(work, name)
    app = os.path.join(st, "app")
    os.makedirs(os.path.join(st, "req"))
    os.makedirs(app)
    for f in os.listdir(REPO):
        if f.endswith((".bat", ".sh", ".ps1")):
            shutil.copy(os.path.join(REPO, f), app)
    json.dump(state, open(os.path.join(st, "state.json"), "w"))
    open(os.path.join(st, "calls.jsonl"), "w").close()
    clear_fake_lxss()
    for d in state.get("installed", []):
        pre_register(d)
    env = dict(os.environ)
    env.update({"E2E_STATE": st, "E2E_PYTHON": sys.executable, "E2E_FAKE": FAKE, "E2E_BASH": bash,
                "PATH": bindir + os.pathsep + os.environ["PATH"]})
    # A list, not a string: pywinpty quotes each argument itself.
    con = Console(["cmd.exe", "/c", os.path.join(app, bat)], app, env)
    err = con.drive(steps)
    out = con.text()
    open(os.path.join(st, "out.txt"), "w", encoding="utf-8").write(out)
    if err:
        bad("driver: " + err)
    return st, out


def calls(st):
    return [json.loads(l) for l in open(os.path.join(st, "calls.jsonl"))]


def installs(st):
    return [c["argv"][c["argv"].index("-d") + 1] for c in calls(st) if c["argv"][:1] == ["--install"]]


def leak(st):
    cs = calls(st)
    idx = [i for i, c in enumerate(cs)
           if c["argv"][-2:-1] == ["bash"] and c["argv"][-1].startswith("/tmp/wsl_setup_user.")]
    if not idx:
        return "NO-SETUP-CALL"
    others = [c for i, c in enumerate(cs) if i not in idx
              and ("PASS_B64" in c["forwarded"] or "USER_B64" in c["forwarded"])]
    if others:
        return f"LEAK {others[:1]}"
    return "ok" if all("PASS_B64" in cs[i]["forwarded"] for i in idx) else "NOT-FORWARDED"


def read(path):
    try:
        return open(path, encoding="utf-8").read()
    except OSError:
        return ""


def check(cond, msg):
    ok() if cond else bad(msg)


def main():
    work = tempfile.mkdtemp(prefix="wsl-e2e-")
    bindir = os.path.join(work, "bin")
    os.makedirs(bindir)
    bash = find_bash()
    build_shim(bindir)
    hidden = hide_system_wsl()
    PW = 'P@ss!w^rd %x% "q"'
    MENU, USER, KEY = "Choose an option: ", "New Linux username: ", "Press any key"
    PWD1, PWD2 = "New Linux password", "Confirm password"
    DEV = "[y/n]: "
    finish = [["Registration complete.", None], [KEY, ""], [DEV, "n"], [MENU, "0"], ["Done.", None], [KEY, ""]]
    shown = []
    try:
        print("=== WIN E2E 1: live list (UTF-16), bad input, menu 6 -> Ubuntu-24.04 ===", flush=True)
        st, out = run_scenario("happy", {"installed": [], "online": "utf16"}, [
            [MENU, "7"], [KEY, ""], [MENU, "1"], [MENU, "99"], [KEY, ""], [MENU, "1&echo INJECTED"], [KEY, ""], [MENU, "6"],
            [USER, "Dev"], [USER, "dev"],
            [PWD1, "abc"], [PWD2, "abd"], [PWD1, PW], [PWD2, PW],
            ["Registration complete.", None], [KEY, ""], [DEV, "y"],
            ["Dev-tools setup finished.", None], [KEY, ""], [MENU, "0"], ["Done.", None], [KEY, ""]],
            work, bindir, bash)
        before = failed
        # Real cmd.exe can print the menu (Wine cannot) - check it exactly.
        for line in ("1.  AlmaLinux OS 9", "6.  Ubuntu 24.04 LTS", "8.  Kali Linux Rolling", "0.  Exit"):
            check(line in out, f"menu lacks {line!r}")
        check('"99" is not a valid option.' in out, "99 not rejected")
        check('"1&echo INJECTED" is not a valid option.' in out, "injection input not rejected")
        check(not re.search(r"(?m)^INJECTED\s*$", out), "INJECTED was executed")
        check("Selected: Ubuntu 24.04 LTS   [wsl.exe --install -d Ubuntu-24.04]" in out, "wrong selection")
        check('"Dev" is not a valid Linux username.' in out, "Dev not rejected")
        check("The passwords did not match" in out, "mismatch not reported")
        check(installs(st) == ["Ubuntu-24.04"], f"installed {installs(st)}")
        root = os.path.join(st, "root-Ubuntu-24.04")
        check(read(os.path.join(root, "chpasswd.log")).strip("\n") == "dev:" + PW,
              f"chpasswd got {read(os.path.join(root, 'chpasswd.log'))!r}")
        check("default=dev" in read(os.path.join(root, "etc", "wsl.conf")).splitlines(), "wsl.conf default=dev missing")
        check(read(os.path.join(root, "etc", "sudoers.d", "dev")).strip() == "dev ALL=(ALL) NOPASSWD:ALL", "sudoers rule")
        check([c["argv"][1] for c in calls(st) if c["argv"][:1] == ["--set-default"]] == ["Ubuntu-24.04"], "set-default")
        check(leak(st) == "ok", "credential forwarding: " + leak(st))
        check('"7" is not a valid option.' in out, "bad main-menu choice not rejected")
        for s in ('[OK] User "dev" is registered in Ubuntu 24.04 LTS.', '[OK] "dev" is set as the default user',
                  '[OK] Typing "wsl" in any cmd/PowerShell window now logs straight'):
            check(s in out, f"console lacks {s!r}")
        dt = json.loads(read(os.path.join(st, "devtools.json")) or "{}")
        check(dt == {"user": "dev", "same": True}, f"dev tools run {dt}, want user dev + identical script")
        check("[OK] Dev-tools setup finished." in out, "dev tools OK line missing")
        for s in ("[OK] WSL is installed - version 2.6.1.0", "Default Distribution: Ubuntu-24.04",
                  "* Ubuntu-24.04", "To open Ubuntu 24.04 LTS later as Administrator, run start.bat next to"):
            check(s in out, f"console lacks {s!r}")
        check(open(os.path.join(REPO, "start.bat"), "rb").read()
              == open(os.path.join(st, "app", "start.bat"), "rb").read(), "start.bat was modified")
        # Scripts run from /tmp must use random mktemp names and be removed.
        ran = [c["argv"][-1] for c in calls(st) if c["argv"][-2:-1] == ["bash"]]
        check(len(ran) == 2 and len(set(ran)) == 2
              and all(re.fullmatch(r"/tmp/wsl_setup_(user|devtools)\.[A-Za-z0-9]{8}", r) for r in ran),
              f"temp script names {ran}")
        check(os.listdir(os.path.join(root, "tmp")) == [], f"left in /tmp: {os.listdir(os.path.join(root, 'tmp'))}")
        if failed > before: shown.append(st)

        print("=== WIN E2E 2: re-run, Debian already registered (real registry lookup) ===", flush=True)
        st, out = run_scenario("rerun", {"installed": ["Debian"], "online": "utf16"}, [
            [MENU, "1"], [MENU, "2"], [USER, "dev"], [PWD1, PW], [PWD2, PW],
            ["Registration complete.", None], [KEY, ""], [DEV, "n"],
            # Post-install menu: bad input, then 1 = Start WSL now, back to the menu, 0 = Exit.
            [MENU, "y"], [MENU, "1"], ["fake shell as dev", None], [MENU, "0"], ["Done.", None], [KEY, ""]],
            work, bindir, bash)
        before = failed
        for line in ("Setup finished. What next?", "1.  Start WSL now", "2.  Install another distro"):
            check(line in out, f"post-install menu lacks {line!r}")
        check('"y" is not a valid option.' in out, "bad post-install choice not rejected")
        check([c["argv"] for c in calls(st)][-2:] == [["--", "true"], []],
              f"Start WSL now did not open the shell last: {[c['argv'] for c in calls(st)][-2:]}")
        check(out.count("Setup finished. What next?") == 3, "post-install menu did not come back after the shell")
        check("Debian GNU/Linux is already installed - skipping install," in out, "not detected as installed")
        check(installs(st) == [], f"re-run installed {installs(st)}")
        check(read(os.path.join(st, "root-Debian", "chpasswd.log")).strip("\n") == "dev:" + PW, "re-run chpasswd")
        if failed > before: shown.append(st)

        print("=== WIN E2E 3: online list unavailable -> fallback menu, 1 -> Ubuntu ===", flush=True)
        st, out = run_scenario("offline", {"installed": [], "online": "fail", "no_store_wsl": True}, [
            [MENU, "1"], ["Could not read the live distro list", None], [KEY, ""],
            [MENU, "1"], [USER, "dev"], [PWD1, PW], [PWD2, PW]] + finish, work, bindir, bash)
        before = failed
        check("WININET_E_NAME_NOT_RESOLVED" in out, "wsl.exe error not shown")
        # No --version answer: real Windows then asks for the WSL feature,
        # which is on for the runner -> the built-in-WSL line.
        check("[OK] WSL is installed - built-in Windows version" in out, "feature-based WSL check not shown")
        check("1.  Ubuntu - latest LTS" in out and "2.  Debian" in out, "fallback menu not shown")
        check(installs(st) == ["Ubuntu"], f"installed {installs(st)}")
        if failed > before: shown.append(st)

        print("=== WIN E2E 4: install another; list fetched once ===", flush=True)
        st, out = run_scenario("another", {"installed": [], "online": "utf8"}, [
            [MENU, "1"], [MENU, "4"], [USER, "dev"], [PWD1, PW], [PWD2, PW],
            ["Registration complete.", None], [KEY, ""], [DEV, "n"], [MENU, "2"],
            [MENU, "2"], [USER, "ops"], [PWD1, PW], [PWD2, PW]] + finish, work, bindir, bash)
        before = failed
        check(installs(st) == ["Ubuntu", "Debian"], f"installed {installs(st)}")
        n = sum(1 for c in calls(st) if c["argv"][:2] == ["--list", "--online"])
        check(n == 1, f"online list fetched {n} times")
        check("default=ops" in read(os.path.join(st, "root-Debian", "etc", "wsl.conf")).splitlines(), "second default user")
        check(out.count("Registration complete.") == 2, "two registrations expected")
        if failed > before: shown.append(st)

        print("=== WIN E2E 5: script cannot be copied into the distro -> clean stop ===", flush=True)
        st, out = run_scenario("copyfail", {"installed": ["Debian"], "online": "utf16", "mktemp_fail": True}, [
            [MENU, "1"], [MENU, "2"], [USER, "dev"], [PWD1, PW], [PWD2, PW],
            ["Could not copy setup-user.sh", None], [KEY, ""], [MENU, "0"], ["Done.", None], [KEY, ""]],
            work, bindir, bash)
        before = failed
        check("Could not copy setup-user.sh into Debian GNU/Linux - no account" in out, "copy failure not reported")
        check(not os.path.exists(os.path.join(st, "root-Debian", "chpasswd.log")), "account touched after failed copy")
        check(not any("PASS_B64" in c["forwarded"] or "USER_B64" in c["forwarded"] for c in calls(st)),
              "credentials forwarded although nothing should run")
        check("Registration complete." not in out, "reported success after a failed copy")
        if failed > before: shown.append(st)

        print("=== WIN E2E 6: start.bat, no distro for this account -> says why, waits ===", flush=True)
        st, out = run_scenario("start-nodistro", {"installed": [], "default": ""}, [[KEY, ""]],
                               work, bindir, bash, bat="start.bat")
        before = failed
        check("[ERROR] No Linux distro is installed for this Windows account" in out, "no-distro case not explained")
        check("Restart Windows, run wsl-setup.bat again" in out, "restart hint missing")
        check(not any(c["argv"] == [] for c in calls(st)), "opened a shell although no distro is registered")
        if failed > before: shown.append(st)

        print("=== WIN E2E 7: start.bat, distro registered but WSL cannot start it ===", flush=True)
        st, out = run_scenario("start-broken", {"installed": ["Debian"], "default": "Gone"}, [[KEY, ""]],
                               work, bindir, bash, bat="start.bat")
        before = failed
        check("There is no distribution with the supplied name." in out, "wsl.exe's own error not shown")
        check("[ERROR] WSL could not start" in out, "start failure not explained")
        check("Default Distribution: Gone" in out, "wsl --status not shown")
        check(not any(c["argv"] == [] for c in calls(st)), "opened a shell although WSL cannot start")
        if failed > before: shown.append(st)

        print("=== WIN E2E 8: start.bat, working distro -> opens the shell, no pause ===", flush=True)
        st, out = run_scenario("start-ok", {"installed": ["Debian"], "default": "Debian"}, [
            ["fake shell as root", None]], work, bindir, bash, bat="start.bat")
        before = failed
        check([c["argv"] for c in calls(st)] == [["--", "true"], []], f"wsl calls {[c['argv'] for c in calls(st)]}")
        check("[ERROR]" not in out and KEY not in out, "error or pause on the working path")
        if failed > before: shown.append(st)

        print("=== WIN E2E 9: main menu 2 = Start WSL, then 1 -> distro list -> 0 Back -> 0 Exit ===", flush=True)
        st, out = run_scenario("menu-start", {"installed": ["Debian"], "default": "Debian", "online": "utf8"}, [
            [MENU, "2"], ["fake shell as root", None], [MENU, "1"], [MENU, "0"], [MENU, "0"], ["Done.", None], [KEY, ""]], work, bindir, bash)
        before = failed
        check("1.  Install a Linux distro" in out and "2.  Start WSL - open the distro you already installed" in out,
              "main menu entries missing")
        check("0.  Back" in out, "distro list has no Back entry")
        check([] in [c["argv"] for c in calls(st)], "Start WSL did not run plain wsl")
        check(installs(st) == [], f"Start WSL installed {installs(st)}")
        if failed > before: shown.append(st)
    finally:
        clear_fake_lxss()
        if hidden:
            os.replace(hidden, SYS_WSL)
    for st in shown:
        print(f"----- {os.path.basename(st)} console -----")
        print(read(os.path.join(st, "out.txt")))
        print("-----")
    print(f"\n WIN E2E RESULTS: {passed} passed, {failed} failed", flush=True)
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
