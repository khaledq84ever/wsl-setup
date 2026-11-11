#!/usr/bin/env bash
# `check && ok || bad` is safe throughout this file: ok and bad always return 0.
# shellcheck disable=SC2015
#
# run-e2e.sh - run the REAL wsl-setup.bat end to end under Wine's cmd.exe:
# distro list -> menu number -> install -> username/password -> account setup
# -> default user -> verification, with typed input fed in like a user would.
#
# What is real: wsl-setup.bat (run by Wine's cmd.exe), list-distros.ps1, every
# inline PowerShell snippet that can run on Linux (run by pwsh), and
# setup-user.sh (run by bash, with useradd/chpasswd stubbed).
# What is faked: wsl.exe (fake_windows.py keeps a tiny model of distros, users
# and /etc/wsl.conf), the registry "is it installed" lookup, the Windows build
# number, and fltmc's "you are admin". proxy.c bridges cmd.exe to those fakes
# because Wine drops the exit code of Linux programs it launches.
#
# Caveat: Wine's cmd.exe is a reimplementation, not Microsoft's. This proves
# the flow and the logic; a real Windows smoke test is still the final word.
#
# Needs: wine (WINE=...), a MinGW gcc (MINGW_CC=...), pwsh (PWSH=...), python3.
# Exits 0 with "SKIPPED" when any of them is missing.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
WINE="${WINE:-wine}"
MINGW_CC="${MINGW_CC:-x86_64-w64-mingw32-gcc}"
PWSH="${PWSH:-pwsh}"
for t in "$WINE" "$MINGW_CC" "$PWSH" python3; do
    command -v "$t" >/dev/null 2>&1 || { echo "=== E2E SKIPPED: $t not found ==="; exit 0; }
done
export PWSH

WORK=$(mktemp -d)
DAEMON=""
cleanup() { [ -n "$DAEMON" ] && kill "$DAEMON" 2>/dev/null; [ -n "${E2E_KEEP:-}" ] && echo "kept $WORK" || rm -rf "$WORK"; }
trap cleanup EXIT

export WINEPREFIX="${E2E_WINEPREFIX:-$WORK/prefix}"
if [ ! -d "$WINEPREFIX/drive_c" ]; then
    echo "--- creating Wine prefix (first run only, slow) ---"
    "$WINE" wineboot -i >/dev/null 2>&1 || true
fi
# Ubuntu's PE user32.dll imports zlib1.dll, which Wine only loads from the
# prefix's system32 - copy it there if the distro ships it elsewhere.
for z in /usr/x86_64-w64-mingw32/lib/zlib1.dll "$HOME/opt/wine/usr/x86_64-w64-mingw32/lib/zlib1.dll"; do
    if [ -f "$z" ] && [ -d "$WINEPREFIX/drive_c/windows/system32" ] && [ ! -f "$WINEPREFIX/drive_c/windows/system32/zlib1.dll" ]; then
        cp "$z" "$WINEPREFIX/drive_c/windows/system32/"
    fi
done

# shellcheck disable=SC1003  # '\\' is a literal backslash for tr, not an escape attempt
winpath() { printf 'Z:%s' "$1" | tr / '\\'; }

# One proxy binary, three names.
mkdir -p "$WORK/bin"
"$MINGW_CC" -municode -O2 -o "$WORK/bin/wsl.exe" "$HERE/proxy.c"
cp "$WORK/bin/wsl.exe" "$WORK/bin/powershell.exe"
cp "$WORK/bin/wsl.exe" "$WORK/bin/fltmc.exe"

pass=0; fail=0; FAIL_BEFORE=0
ok()  { pass=$((pass + 1)); }
bad() { [ "${SKIPPED:-0}" = 1 ] && return 0; fail=$((fail + 1)); echo "  FAIL [$SCEN]: $1"; }

# run_scenario NAME STATE_JSON STEPS_JSON
# STEPS_JSON: [[console text to wait for, answer], ...] - see driver.py.
# Leaves the console output in $OUT and the fake's state in $ST.
run_scenario() {
    SCEN=$1
    if [ -n "${E2E_ONLY:-}" ] && [ "$SCEN" != "$E2E_ONLY" ]; then OUT=/dev/null; ST=/nonexistent; SKIPPED=1; return 0; fi
    SKIPPED=0
    ST="$WORK/$SCEN"; APP="$ST/app"
    mkdir -p "$ST/req" "$ST/pwsh-cwd" "$APP"
    cp "$REPO"/*.bat "$REPO"/*.sh "$REPO"/*.ps1 "$APP/"
    printf '%s' "$2" > "$ST/state.json"
    : > "$ST/calls.jsonl"
    E2E_STATE="$ST" python3 "$HERE/fake_windows.py" serve "$ST/req" &
    DAEMON=$!
    OUT="$ST/out.txt"
    ( cd "$APP"
      E2E_STATE="$ST" E2E_REQDIR="$(winpath "$ST/req")" WINEPATH="$(winpath "$WORK/bin")" \
        python3 "$HERE/driver.py" "$OUT" "$ST/req" "$3" -- "$WINE" cmd /c "$(winpath "$APP/wsl-setup.bat")" ) \
        || bad "driver: script did not follow the expected prompts (see console below)"
    kill "$DAEMON" 2>/dev/null; wait "$DAEMON" 2>/dev/null || true; DAEMON=""
    # strip ANSI colour codes and CRs for matching
    sed -i -e 's/\x1b\[[0-9;]*[A-Za-z]//g' -e 's/\r//g' "$OUT"
    [ -n "${E2E_SHOW:-}" ] && { echo "----- $SCEN console -----"; cat "$OUT"; echo "-----"; }
    return 0
}
# Call after a scenario's assertions: dump its console only if one failed.
end_scenario() {
    if [ "${SKIPPED:-0}" != 1 ] && [ "$fail" -gt "$FAIL_BEFORE" ] && [ -z "${E2E_SHOW:-}" ]; then
        echo "----- $SCEN console -----"; cat "$OUT"; echo "-----"
    fi
    FAIL_BEFORE=$fail
}
has()    { grep -qF -- "$1" "$OUT" && ok || bad "console lacks: $1"; }
hasnt()  { grep -qxF -- "$1" "$OUT" && bad "console has line: $1" || ok; }
calls()  { python3 - "$ST/calls.jsonl" "$@" <<'PY'
import json, sys
calls = [json.loads(l) for l in open(sys.argv[1])]
what = sys.argv[2]
if what == "installs":
    print(" ".join(c["argv"][c["argv"].index("-d") + 1] for c in calls if c["argv"][:1] == ["--install"]))
elif what == "leak":
    # Credentials may only be forwarded up to and including the setup-user.sh run.
    idx = [i for i, c in enumerate(calls) if c["argv"][-2:-1] == ["bash"] and c["argv"][-1].startswith("/tmp/wsl_setup_user.")]
    if not idx: print("NO-SETUP-CALL"); sys.exit()
    # Exactly the setup-user.sh run(s) may see the credentials - no other call.
    others = [c for i, c in enumerate(calls) if i not in idx
              and ("PASS_B64" in c["forwarded"] or "USER_B64" in c["forwarded"])]
    seen = all("PASS_B64" in calls[i]["forwarded"] for i in idx)
    print("ok" if seen and not others else f"LEAK {others[:1]}" if others else "NOT-FORWARDED")
elif what == "fwdcount":
    print(sum(1 for c in calls if "PASS_B64" in c["forwarded"] or "USER_B64" in c["forwarded"]))
elif what == "tmpnames":
    # Every script the .bat ran from /tmp: must be a random mktemp name, never
    # a fixed one another user could have created first.
    import re
    ran = [c["argv"][-1] for c in calls if c["argv"][-2:-1] == ["bash"]]
    bad = [r for r in ran if not re.fullmatch(r"/tmp/wsl_setup_(user|devtools)\.[A-Za-z0-9]{8}", r)]
    print("ok" if ran and not bad and len(set(ran)) == len(ran) else f"BAD {ran}")
elif what == "setdefault":
    print(" ".join(c["argv"][1] for c in calls if c["argv"][:1] == ["--set-default"]))
PY
}

PW='P@ss!w^rd %x% "q"'
# JSON-quote the password once for the step lists.
PWJ=$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]+"\n"+sys.argv[1]))' "$PW")
MENU='"Choose an option: "'; USER='"New Linux username: "'; KEY='"Press any key"'
DEV='"[y/n]: "'; AGAIN='"(y/n): "'

# NOTE: Wine's cmd.exe cannot print the menu entries themselves (it fails the
# standard `for /l ... (1,1,!N!)` and `!NAME_%%i!` idioms that real cmd.exe
# supports), so the menu is checked by what each number actually installs.
# The list parsing itself is covered by test/list-distros.tests.ps1.

echo "=== E2E 1: live list (UTF-16), bad input first, then menu 6 -> Ubuntu-24.04 ==="
run_scenario happy '{"installed":[],"online":"utf16"}' "[
  [$MENU, \"99\"], [$KEY, \"\"],
  [$MENU, \"1&echo INJECTED\"], [$KEY, \"\"],
  [$MENU, \"6\"],
  [$USER, \"Dev\"], [$USER, \"dev\"],
  [\"@PASSWORD\", \"abc\nabd\"], [\"@PASSWORD\", $PWJ],
  [\"Registration complete.\", null], [$KEY, \"\"], [$DEV, \"y\"],
  [\"Dev-tools setup finished.\", null], [$KEY, \"\"], [$AGAIN, \"n\"], [\"Done.\", null], [$KEY, \"\"]]"
has '"99" is not a valid option.'
has '"1&echo INJECTED" is not a valid option.'
hasnt 'INJECTED'
has 'Selected: Ubuntu 24.04 LTS   [wsl.exe --install -d Ubuntu-24.04]'
has '"Dev" is not a valid Linux username.'
has 'The passwords did not match'
has 'Installing Ubuntu 24.04 LTS'
[ "$(calls installs)" = "Ubuntu-24.04" ] && ok || bad "installed [$(calls installs)], want Ubuntu-24.04"
[ "$(cat "$ST/root-Ubuntu-24.04/chpasswd.log" 2>/dev/null)" = "dev:$PW" ] && ok || bad "chpasswd got [$(cat "$ST/root-Ubuntu-24.04/chpasswd.log" 2>/dev/null)]"
grep -qx 'default=dev' "$ST/root-Ubuntu-24.04/etc/wsl.conf" 2>/dev/null && ok || bad "wsl.conf default=dev missing"
grep -qxF 'dev ALL=(ALL) NOPASSWD:ALL' "$ST/root-Ubuntu-24.04/etc/sudoers.d/dev" 2>/dev/null && ok || bad "sudoers rule missing"
[ "$(calls setdefault)" = "Ubuntu-24.04" ] && ok || bad "set-default [$(calls setdefault)]"
[ "$(calls leak)" = "ok" ] && ok || bad "credential forwarding: $(calls leak)"
has '[OK] User "dev" is registered in Ubuntu 24.04 LTS.'
has '[OK] "dev" is set as the default user'
has '[OK] Typing "wsl" in any cmd/PowerShell window now logs straight'
has 'Registration complete.'
# Dev tools: same script arrived intact and ran as the new user, not root.
DT=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["user"], d["same"])' "$ST/devtools.json" 2>/dev/null || echo missing)
[ "$DT" = "dev True" ] && ok || bad "dev tools run: [$DT], want 'dev True'"
has '[OK] Dev-tools setup finished.'
# WSL itself: checked before the menu, and its state shown after setup.
has '[OK] WSL is installed - version 2.6.1.0'
has 'Default Distribution: Ubuntu-24.04'
has '* Ubuntu-24.04'
has 'To open Ubuntu 24.04 LTS later as Administrator, run start.bat next to'
# start.bat is shipped, never rewritten by the .bat.
cmp -s "$REPO/start.bat" "$ST/app/start.bat" && ok || bad "start.bat was modified"
[ "$(calls tmpnames)" = "ok" ] && ok || bad "temp script names: $(calls tmpnames)"
[ -z "$(ls -A "$ST/root-Ubuntu-24.04/tmp")" ] && ok || bad "left behind in /tmp: $(ls -A "$ST/root-Ubuntu-24.04/tmp")"

end_scenario

echo "=== E2E 2: re-run on an already-installed distro (menu 2 -> Debian) ==="
run_scenario rerun '{"installed":["Debian"],"online":"utf16"}' "[
  [$MENU, \"2\"], [$USER, \"dev\"], [\"@PASSWORD\", $PWJ],
  [\"Registration complete.\", null], [$KEY, \"\"], [$DEV, \"n\"], [$AGAIN, \"n\"], [\"Done.\", null], [$KEY, \"\"]]"
has 'Debian GNU/Linux is already installed - skipping install,'
[ -z "$(calls installs)" ] && ok || bad "re-run tried to install [$(calls installs)]"
[ "$(cat "$ST/root-Debian/chpasswd.log" 2>/dev/null)" = "dev:$PW" ] && ok || bad "re-run chpasswd [$(cat "$ST/root-Debian/chpasswd.log" 2>/dev/null)]"
has 'Registration complete.'

end_scenario

echo "=== E2E 3: online list unavailable -> fallback menu, 1 -> Ubuntu ==="
run_scenario offline '{"installed":[],"online":"fail","no_store_wsl":true}' "[
  [\"Could not read the live distro list\", null], [$KEY, \"\"],
  [$MENU, \"1\"], [$USER, \"dev\"], [\"@PASSWORD\", $PWJ],
  [\"Registration complete.\", null], [$KEY, \"\"], [$DEV, \"n\"], [$AGAIN, \"n\"], [\"Done.\", null], [$KEY, \"\"]]"
has 'WININET_E_NAME_NOT_RESOLVED'
# No Store WSL answering --version, and Linux pwsh cannot ask Windows about
# the WSL feature -> an honest "could not check", not a wrong claim.
has '[INFO] Could not check whether WSL is installed - continuing anyway.'
has 'Selected: Ubuntu - latest LTS   [wsl.exe --install -d Ubuntu]'
[ "$(calls installs)" = "Ubuntu" ] && ok || bad "installed [$(calls installs)], want Ubuntu"
has 'Registration complete.'

end_scenario

echo "=== E2E 4: install another - second distro, list fetched only once ==="
run_scenario another '{"installed":[],"online":"utf8"}' "[
  [$MENU, \"4\"], [$USER, \"dev\"], [\"@PASSWORD\", $PWJ],
  [\"Registration complete.\", null], [$KEY, \"\"], [$DEV, \"n\"], [$AGAIN, \"y\"],
  [$MENU, \"2\"], [$USER, \"ops\"], [\"@PASSWORD\", $PWJ],
  [\"Registration complete.\", null], [$KEY, \"\"], [$DEV, \"n\"], [$AGAIN, \"n\"], [\"Done.\", null], [$KEY, \"\"]]"
[ "$(calls installs)" = "Ubuntu Debian" ] && ok || bad "installed [$(calls installs)], want 'Ubuntu Debian'"
n=$(grep -c '"--list", "--online"' "$ST/calls.jsonl" || true)
[ "$n" = "1" ] && ok || bad "online list fetched $n times, want 1"
grep -qx 'default=ops' "$ST/root-Debian/etc/wsl.conf" 2>/dev/null && ok || bad "second distro default user not ops"
[ "$(grep -c 'Registration complete.' "$OUT")" = "2" ] && ok || bad "expected two completed registrations"

end_scenario

echo "=== E2E 5: script cannot be copied into the distro -> clean stop, nothing run ==="
run_scenario copyfail '{"installed":["Debian"],"online":"utf16","mktemp_fail":true}' "[
  [$MENU, \"2\"], [$USER, \"dev\"], [\"@PASSWORD\", $PWJ],
  [\"Could not copy setup-user.sh\", null], [$KEY, \"\"], [$MENU, \"0\"], [\"Done.\", null], [$KEY, \"\"]]"
has 'Could not copy setup-user.sh into Debian GNU/Linux - no account'
[ ! -e "$ST/root-Debian/chpasswd.log" ] && ok || bad "an account was touched although the copy failed"
[ "$(calls fwdcount)" = "0" ] && ok || bad "credentials forwarded to $(calls fwdcount) call(s) although nothing should run"
[ "$(grep -c 'Registration complete.' "$OUT")" = "0" ] && ok || bad "reported success after a failed copy"

end_scenario

echo
echo "============================================"
echo " E2E RESULTS: $pass passed, $fail failed"
echo "============================================"
[ "$fail" -eq 0 ]
