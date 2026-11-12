#!/usr/bin/env python3
"""fake_windows.py - the Linux side of the wsl-setup.bat end-to-end test.

Modes:
  serve REQDIR   answer requests from proxy.exe (wsl / powershell / fltmc)
  wsl ARGS...    act as wsl.exe directly; used by the Linux `wsl.exe` shim that
                 pwsh scripts (list-distros.ps1, the install/wait scripts)
                 start themselves

State lives in $E2E_STATE (a directory):
  state.json     installed distros, the default distro, a scenario knob
  calls.jsonl    one line per wsl.exe call: argv + which env vars WSL forwarded
  root-<distro>/ the distro's filesystem (/etc/wsl.conf, /etc/sudoers.d, ...)

The fake wsl.exe implements only what wsl-setup.bat uses. Like real WSL, it
forwards into the "distro" only the env vars named in WSLENV, which is what
makes the credential-leak assertion meaningful.
"""
import json, os, random, re, shutil, string, subprocess, sys, time
try:
    import fcntl
except ImportError:  # Windows
    fcntl = None
    import msvcrt

ON_WINDOWS = os.name == "nt"

STATE = os.environ.get("E2E_STATE", "")
E2E_BASH = os.environ.get("E2E_BASH", "bash")
HERE = os.path.dirname(os.path.abspath(__file__))
WINEPREFIX = os.environ.get("WINEPREFIX", "")

# What `wsl --list --online` prints. Index = menu number in wsl-setup.bat.
ONLINE = [
    ("AlmaLinux-9", "AlmaLinux OS 9"),
    ("Debian", "Debian GNU/Linux"),
    ("FedoraLinux-42", "Fedora Linux 42"),
    ("Ubuntu", "Ubuntu"),
    ("Ubuntu-22.04", "Ubuntu 22.04 LTS"),
    ("Ubuntu-24.04", "Ubuntu 24.04 LTS"),
    ("archlinux", "Arch Linux"),
    ("kali-linux", "Kali Linux Rolling"),
]


# ---------------------------------------------------------------- state ----
class Locked:
    def __enter__(self):
        self.f = open(os.path.join(STATE, "lock"), "a+")
        if fcntl:
            fcntl.flock(self.f, fcntl.LOCK_EX)
        else:
            self.f.seek(0)
            msvcrt.locking(self.f.fileno(), msvcrt.LK_LOCK, 1)
        p = os.path.join(STATE, "state.json")
        self.s = json.load(open(p)) if os.path.exists(p) else {}
        self.s.setdefault("installed", [])
        self.s.setdefault("default", None)
        return self.s

    def __exit__(self, *a):
        json.dump(self.s, open(os.path.join(STATE, "state.json"), "w"), indent=1)
        if fcntl:
            fcntl.flock(self.f, fcntl.LOCK_UN)
        else:
            self.f.seek(0)
            msvcrt.locking(self.f.fileno(), msvcrt.LK_UNLCK, 1)
        self.f.close()


def distro_root(name):
    r = os.path.join(STATE, "root-" + name)
    for d in ("etc/sudoers.d", "tmp"):
        os.makedirs(os.path.join(r, d), exist_ok=True)
    return r


def win_to_unix(p):
    """Wine maps Z: to / and C: to $WINEPREFIX/drive_c. On real Windows the
    "distro" can read Windows paths directly, so they pass through."""
    if ON_WINDOWS:
        return p
    p = p.replace("\\", "/")
    m = re.match(r"^([A-Za-z]):(/.*)?$", p)
    if not m:
        return p
    rest = m.group(2) or "/"
    if m.group(1).lower() == "z":
        return rest
    return os.path.join(WINEPREFIX, "drive_" + m.group(1).lower()) + rest


def forwarded_env(env):
    """Only vars listed in WSLENV cross into the distro (flags like /u ignored)."""
    names = [n.split("/")[0] for n in env.get("WSLENV", "").split(":") if n]
    return {n: env[n] for n in names if n in env}


def read_conf_default(root):
    try:
        txt = open(os.path.join(root, "etc/wsl.conf")).read()
    except OSError:
        return None
    sect = None
    for line in txt.splitlines():
        line = line.strip()
        if line.startswith("["):
            sect = line.strip("[]").lower()
        elif sect == "user" and line.startswith("default="):
            return line.split("=", 1)[1].strip()
    return None


LXSS = r"Software\Microsoft\Windows\CurrentVersion\Lxss"


def register_lxss(name):
    """On real Windows, record the distro where wsl-setup.bat's registry
    check looks, like WSL does. E2EFake marks keys the test may delete."""
    if not ON_WINDOWS:
        return
    import uuid, winreg
    k = winreg.CreateKey(winreg.HKEY_CURRENT_USER, LXSS + "\\{" + str(uuid.uuid4()) + "}")
    winreg.SetValueEx(k, "DistributionName", 0, winreg.REG_SZ, name)
    winreg.SetValueEx(k, "E2EFake", 0, winreg.REG_DWORD, 1)
    winreg.CloseKey(k)


def users(root):
    try:
        return [l.strip() for l in open(os.path.join(root, "etc/passwd")) if l.strip()]
    except OSError:
        return []


# ------------------------------------------------------------- wsl.exe ----
def fake_wsl(argv, env):
    """Returns (stdout_bytes, stderr_bytes, rc)."""
    fwd = forwarded_env(env)
    with open(os.path.join(STATE, "calls.jsonl"), "a") as f:
        f.write(json.dumps({"argv": argv, "forwarded": sorted(fwd)}) + "\n")
    out = lambda s: (s.encode(), b"", 0)
    err = lambda s, rc=1: (b"", s.encode(), rc)

    if argv[:2] == ["--list", "--online"]:
        with Locked() as s:
            mode = s.get("online", "utf16")
        if mode == "fail":
            msg = ("Failed to fetch the list distribution from 'https://raw.githubusercontent.com/"
                   "microsoft/WSL/master/distributions/DistributionInfo.json'.\r\n"
                   "Error code: Wsl/WININET_E_NAME_NOT_RESOLVED\r\n")
            return msg.encode("utf-16-le"), b"", 1
        text = ("The following is a list of valid distributions that can be installed.\r\n"
                "Install using 'wsl.exe --install <Distro>'.\r\n\r\n"
                + "NAME                            FRIENDLY NAME\r\n"
                + "".join(f"{n:<32}{fr}\r\n" for n, fr in ONLINE))
        # Old wsl.exe behaviour: UTF-16LE, no BOM, even with WSL_UTF8=1 set.
        return text.encode("utf-16-le" if mode == "utf16" else "utf-8"), b"", 0

    if argv == ["--version"]:
        # Store WSL; real wsl.exe prints UTF-16LE here when piped.
        with Locked() as s:
            if s.get("no_store_wsl"):
                return err("Invalid command line option: --version\r\n", 1)
        return ("WSL version: 2.6.1.0\r\nKernel version: 6.6.87.2-1\r\n"
                "WSLg version: 1.0.66\r\n").encode("utf-16-le"), b"", 0
    if argv == ["--status"]:
        with Locked() as s:
            d = s["default"]
        return out(f"Default Distribution: {d}\r\nDefault Version: 2\r\n")
    if argv == ["--list", "--verbose"]:
        with Locked() as s:
            d, names = s["default"], list(s["installed"])
        rows = "".join(f"{'*' if n == d else ' '} {n:<20}Stopped         2\r\n" for n in names)
        return out("  NAME                  STATE           VERSION\r\n" + rows)
    if argv and argv[0] == "--install":
        name = argv[argv.index("-d") + 1]
        # "install_fail" in the state: the download fails, with wsl.exe's
        # own exit code -1.
        with Locked() as s:
            if s.get("install_fail"):
                return err("Error code: Wsl/InstallDistro/WININET_E_CANNOT_CONNECT\r\n", -1)
        with Locked() as s:
            if name not in s["installed"]:
                s["installed"].append(name)
        distro_root(name)
        register_lxss(name)
        return out(f"Downloading: {name}\r\n[==========] 100.0%\r\nInstalled {name}.\r\n")
    if argv and argv[0] == "--set-default":
        with Locked() as s:
            s["default"] = argv[1]
        return out("")
    if argv and argv[0] == "--terminate":
        return out("")

    # -d NAME / -u USER / -- CMD...
    distro = user = None
    i = 0
    while i < len(argv) and argv[i] != "--":
        if argv[i] == "-d":
            distro = argv[i + 1]; i += 2
        elif argv[i] == "-u":
            user = argv[i + 1]; i += 2
        else:
            i += 1
    cmd = argv[i + 1:]
    with Locked() as s:
        installed = list(s["installed"])
        distro = distro or s["default"]
    if distro not in installed:
        # Real wsl.exe exits with -1 here, which `if errorlevel 1` does not catch.
        return err("There is no distribution with the supplied name.\r\n", -1)
    root = distro_root(distro)
    if user is None:
        user = read_conf_default(root) or "root"
    if user != "root" and user not in users(root):
        return err(f"<3>WSL ERROR: User not found: {user}\n", 1)

    def m(p):  # distro path -> host path (forward slashes: also fine for Git Bash)
        return os.path.join(root, p.lstrip("/")).replace("\\", "/")

    if not cmd:
        # Bare `wsl`: the interactive shell start.bat opens.
        return out(f"fake shell as {user}\n")
    if cmd == ["true"]:
        # "never_ready" in the state: the distro is registered but cannot
        # start - wsl.exe's own error and exit code, every time.
        with Locked() as s:
            if s.get("never_ready"):
                return err("Error code: Wsl/Service/CreateInstance/E_FAIL\r\n", -1)
        return out("")
    if cmd[:2] == ["wslpath", "-a"]:
        return out(win_to_unix(cmd[2]) + "\n")
    if cmd[:1] == ["whoami"] or cmd == ["id", "-un"]:
        return out(user + "\n")
    if cmd[:1] == ["mktemp"] and len(cmd) == 2 and cmd[1].startswith("/tmp/"):
        # Like the real one: random name in place of the trailing Xs, file
        # created empty and private. "mktemp_fail" in the state makes it fail.
        with Locked() as s:
            if s.get("mktemp_fail"):
                return err("mktemp: failed to create file via template\n", 1)
        stem = cmd[1].rstrip("X")
        name = stem + "".join(random.choice(string.ascii_letters + string.digits)
                              for _ in range(len(cmd[1]) - len(stem)))
        fd = os.open(m(name), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        os.close(fd)
        return out(name + "\n")
    # "wsl_fail": ["cp:wsl_setup_user", ...] in the state makes a matching
    # command fail the way wsl.exe itself fails (not the Linux program): its
    # own message and exit code -1, which `if errorlevel 1` does not catch.
    with Locked() as s:
        wsl_fail = list(s.get("wsl_fail", []))
    for rule in wsl_fail:
        name, _, needle = rule.partition(":")
        if cmd[:1] == [name] and needle in " ".join(cmd[1:]):
            return err("Catastrophic failure\r\nError code: Wsl/Service/E_UNEXPECTED\r\n", -1)
    if cmd[:1] == ["cp"]:
        if not os.path.exists(m(cmd[2])):
            # The .bat must only ever copy onto a file mktemp just made.
            return err(f"fake wsl: cp target {cmd[2]!r} was not created by mktemp\n", 1)
        shutil.copyfile(cmd[1], m(cmd[2]))
        return out("")
    if cmd[:2] == ["sed", "-i"]:
        # The only sed the .bat uses: strip CRs from a CRLF checkout.
        if cmd[2] != "s/\\r$//":
            return err(f"fake wsl: unexpected sed expression {cmd[2]!r}\n", 127)
        data = open(m(cmd[3]), "rb").read().replace(b"\r\n", b"\n")
        open(m(cmd[3]), "wb").write(data)
        return out("")
    if cmd[:2] == ["rm", "-f"]:
        try:
            os.remove(m(cmd[2]))
        except OSError:
            pass
        return out("")
    if cmd[:1] == ["bash"] and len(cmd) == 2 and cmd[1].startswith("/tmp/wsl_setup_devtools."):
        # Don't really install Node/Docker/gh. Prove the plumbing instead: the
        # script that arrived (after wslpath/cp/sed) must be byte-identical
        # to the repo's LF setup-dev-tools.sh, and record who ran it.
        repo = os.path.join(HERE, "..", "..", "setup-dev-tools.sh")
        want = open(repo, "rb").read().replace(b"\r\n", b"\n")
        got = open(m(cmd[1]), "rb").read()
        with open(os.path.join(STATE, "devtools.json"), "w") as f:
            json.dump({"user": user, "same": got == want}, f)
        return out("fake dev tools ran\n")
    if cmd[:1] == ["bash"] and len(cmd) == 2:
        if ON_WINDOWS:  # Git Bash; it converts this Windows-style PATH itself
            git_usr = os.path.join(os.path.dirname(os.path.dirname(E2E_BASH)), "usr", "bin")
            path = os.path.join(HERE, "stubs") + ";" + git_usr
        else:
            path = os.path.join(HERE, "stubs") + ":/usr/bin:/bin"
        child = {"PATH": path, "HOME": "/root",
                 "E2E_ROOT": root,
                 "WSL_CONF_FILE": m("/etc/wsl.conf"),
                 "WSL_SUDOERS_DIR": m("/etc/sudoers.d")}
        child.update(fwd)
        if ON_WINDOWS:
            child["SYSTEMROOT"] = os.environ.get("SYSTEMROOT", r"C:\\Windows")
        r = subprocess.run([E2E_BASH, m(cmd[1])], env=child, capture_output=True)
        return r.stdout, r.stderr, r.returncode
    return err(f"fake wsl: unsupported command {cmd!r}\n", 127)


# ------------------------------------------------------ powershell.exe ----
def fake_powershell(argv, env, stdin_lines):
    joined = " ".join(argv)
    # Things pwsh on Linux cannot answer like Windows would:
    if "OSVersion.Version.Build" in joined:
        return b"19045\r\n", b"", 0
    if "\\Lxss" in joined:  # "is this distro registered?" registry lookup
        n = next((v for k, v in env.items() if k.upper() == "WSL_SETUP_DISTRO"), "")
        with Locked() as s:
            hit = n.lower() in [d.lower() for d in s["installed"]]
        return b"", b"", 0 if hit else 1
    if "-Verb RunAs" in joined:
        return b"", b"fake: elevation should not be needed (fltmc says admin)\n", 1

    args = list(argv)
    pre = ""
    for k, a in enumerate(args):
        if k and args[k - 1] == "-File":
            args[k] = win_to_unix(a)
        if "Read-Host -AsSecureString" in a:
            # The real password snippet, fed from the two stdin lines proxy.exe read.
            a = a.replace("Read-Host -AsSecureString '  New Linux password'", "(S $env:E2E_P1)")
            a = a.replace("Read-Host -AsSecureString '  Confirm password'", "(S $env:E2E_P2)")
            pre = ("function S($t) { $x = [securestring]::new(); "
                   "foreach ($c in $t.ToCharArray()) { $x.AppendChar($c) }; $x }; ")
            args[k] = pre + a
    child = dict(os.environ)
    for k, v in env.items():
        if k.upper() not in ("PATH", "HOME", "TEMP", "TMP", "PWD") and not k.startswith("="):
            child[k] = v
    child["PATH"] = os.path.join(HERE, "linuxbin") + ":" + os.environ["PATH"]
    if stdin_lines is not None:
        p1, p2 = (stdin_lines + ["", ""])[:2]
        child["E2E_P1"], child["E2E_P2"] = p1, p2
    pwsh = os.environ.get("PWSH", "pwsh")
    # Windows PowerShell's own switches that pwsh also accepts pass straight through.
    r = subprocess.run([pwsh] + args, env=child, capture_output=True,
                       cwd=os.path.join(STATE, "pwsh-cwd"))
    return r.stdout, r.stderr, r.returncode


# ------------------------------------------------------------- serving ----
def read_nul(path):
    data = open(path, "rb").read().decode("utf-8", "replace")
    return [x for x in data.split("\0") if x != ""] if data else []


def handle(reqdir):
    argv = read_nul(os.path.join(reqdir, "args"))
    env = {}
    for kv in read_nul(os.path.join(reqdir, "env")):
        if "=" in kv[1:]:
            k, v = kv.split("=", 1) if not kv.startswith("=") else ("=" + kv[1:].split("=", 1)[0], "")
            env[k] = v
    sp = os.path.join(reqdir, "stdin")
    stdin_lines = open(sp).read().split("\n") if os.path.exists(sp) else None
    tool, args = argv[0], argv[1:]
    try:
        if tool == "wsl":
            o, e, rc = fake_wsl(args, env)
        elif tool == "powershell":
            o, e, rc = fake_powershell(args, env, stdin_lines)
        elif tool == "fltmc":
            o, e, rc = b"", b"", 0  # "we are elevated"
        else:
            o, e, rc = b"", f"fake: unknown tool {tool}\n".encode(), 127
    except Exception as ex:  # surface handler bugs in the test output
        o, e, rc = b"", f"fake handler crashed: {ex!r}\n".encode(), 125
    open(os.path.join(reqdir, "stdout"), "wb").write(o)
    open(os.path.join(reqdir, "stderr"), "wb").write(e)
    open(os.path.join(reqdir, "rc"), "w").write(str(rc & 0xFFFFFFFF if rc >= 0 else 1))
    open(os.path.join(reqdir, "done"), "w").close()


def serve(reqdir):
    seen = set()
    while True:
        for d in sorted(os.listdir(reqdir)):
            if d.endswith(".req") and d not in seen:
                seen.add(d)
                handle(os.path.join(reqdir, d))
        time.sleep(0.02)


if __name__ == "__main__":
    if sys.argv[1] == "serve":
        serve(sys.argv[2])
    elif sys.argv[1] == "wsl":
        o, e, rc = fake_wsl(sys.argv[2:], dict(os.environ))
        sys.stdout.buffer.write(o); sys.stderr.buffer.write(e)
        sys.exit(rc)
