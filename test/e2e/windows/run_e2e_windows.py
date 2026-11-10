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
ANSI = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07]*\x07|\x1b[=>()][0-9A-Za-z]?")

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
        for expect, answer in steps:
            deadline = time.time() + STEP_TIMEOUT
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


def run_scenario(name, state, steps, work, bindir, bash):
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
    con = Console(f'cmd.exe /c "{os.path.join(app, "wsl-setup.bat")}"', app, env)
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
    idx = [i for i, c in enumerate(cs) if c["argv"][-2:] == ["bash", "/tmp/wsl_setup_user.sh"]]
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
    DEV, AGAIN = "[y/n]: ", "(y/n): "
    finish = [["Registration complete.", None], [KEY, ""], [DEV, "n"], [AGAIN, "n"], ["Done.", None], [KEY, ""]]
    shown = []
    try:
        print("=== WIN E2E 1: live list (UTF-16), bad input, menu 6 -> Ubuntu-24.04 ===", flush=True)
        st, out = run_scenario("happy", {"installed": [], "online": "utf16"}, [
            [MENU, "99"], [KEY, ""], [MENU, "1&echo INJECTED"], [KEY, ""], [MENU, "6"],
            [USER, "Dev"], [USER, "dev"],
            [PWD1, "abc"], [PWD2, "abd"], [PWD1, PW], [PWD2, PW]] + finish, work, bindir, bash)
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
        for s in ('[OK] User "dev" is registered in Ubuntu 24.04 LTS.', '[OK] "dev" is set as the default user',
                  '[OK] Typing "wsl" in any cmd/PowerShell window now logs straight'):
            check(s in out, f"console lacks {s!r}")
        if failed > before: shown.append(st)

        print("=== WIN E2E 2: re-run, Debian already registered (real registry lookup) ===", flush=True)
        st, out = run_scenario("rerun", {"installed": ["Debian"], "online": "utf16"}, [
            [MENU, "2"], [USER, "dev"], [PWD1, PW], [PWD2, PW]] + finish, work, bindir, bash)
        before = failed
        check("Debian GNU/Linux is already installed - skipping install," in out, "not detected as installed")
        check(installs(st) == [], f"re-run installed {installs(st)}")
        check(read(os.path.join(st, "root-Debian", "chpasswd.log")).strip("\n") == "dev:" + PW, "re-run chpasswd")
        if failed > before: shown.append(st)

        print("=== WIN E2E 3: online list unavailable -> fallback menu, 1 -> Ubuntu ===", flush=True)
        st, out = run_scenario("offline", {"installed": [], "online": "fail"}, [
            ["Could not read the live distro list", None], [KEY, ""],
            [MENU, "1"], [USER, "dev"], [PWD1, PW], [PWD2, PW]] + finish, work, bindir, bash)
        before = failed
        check("WININET_E_NAME_NOT_RESOLVED" in out, "wsl.exe error not shown")
        check("1.  Ubuntu - latest LTS" in out and "2.  Debian" in out, "fallback menu not shown")
        check(installs(st) == ["Ubuntu"], f"installed {installs(st)}")
        if failed > before: shown.append(st)

        print("=== WIN E2E 4: install another; list fetched once ===", flush=True)
        st, out = run_scenario("another", {"installed": [], "online": "utf8"}, [
            [MENU, "4"], [USER, "dev"], [PWD1, PW], [PWD2, PW],
            ["Registration complete.", None], [KEY, ""], [DEV, "n"], [AGAIN, "y"],
            [MENU, "2"], [USER, "ops"], [PWD1, PW], [PWD2, PW]] + finish, work, bindir, bash)
        before = failed
        check(installs(st) == ["Ubuntu", "Debian"], f"installed {installs(st)}")
        n = sum(1 for c in calls(st) if c["argv"][:2] == ["--list", "--online"])
        check(n == 1, f"online list fetched {n} times")
        check("default=ops" in read(os.path.join(st, "root-Debian", "etc", "wsl.conf")).splitlines(), "second default user")
        check(out.count("Registration complete.") == 2, "two registrations expected")
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
