#!/usr/bin/env bash
#
# run-tests.sh - exercise the WSL-setup shell logic without root or a real
# distro, 100 iterations per scenario ("each way").
#
# What is REAL vs REPLICA:
#   * setup-user.sh is run FOR REAL (the actual shipped file), with useradd/
#     chpasswd/usermod stubbed on PATH and /etc paths redirected to a temp dir
#     via the WSL_CONF_FILE / WSL_SUDOERS_DIR overrides the script honours.
#   * setup-dev-tools.sh is SOURCED (its main body only runs when executed
#     directly), and its real enable_systemd() is called on temp files with
#     SUDO="" - no replica to drift out of sync.
#
# NOTE: wsl-setup.bat itself is NOT exercised here - it needs Windows + real WSL.
# This harness covers the bash it runs inside the distro, which is where the
# correctness-critical logic lives.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
ITER="${ITER:-100}"

pass=0
fail=0
declare -a FAILMSGS=()

ok()   { pass=$((pass + 1)); }
bad()  { fail=$((fail + 1)); FAILMSGS+=("$1"); }

# ---- stub user-management tools so setup-user.sh runs unprivileged ----
STUB=$(mktemp -d)
WORKROOT=$(mktemp -d)
trap 'rm -rf "$STUB" "$WORKROOT"' EXIT
# useradd/usermod take no stdin; chpasswd reads a line - it MUST drain stdin,
# or the upstream printf gets SIGPIPE (which under pipefail aborts the real
# script we are testing).
for t in useradd usermod; do
    printf '#!/bin/sh\nexit 0\n' > "$STUB/$t"
    chmod +x "$STUB/$t"
done
# It also records what it received, so the exact user:password line can be
# asserted (catches any mangling of special characters on the way through).
# shellcheck disable=SC2016  # $VAR is meant to expand inside the stub, not here
printf '#!/bin/sh\ncat > "${CHPASSWD_LOG:-/dev/null}"\nexit 0\n' > "$STUB/chpasswd"
chmod +x "$STUB/chpasswd"
# `id -u <user>` decides create-vs-skip. Default: user missing (exit 1).
cat > "$STUB/id" <<'EOF'
#!/bin/sh
[ "${TEST_USER_EXISTS:-0}" = "1" ] && exit 0
exit 1
EOF
chmod +x "$STUB/id"

# Run the REAL setup-user.sh against a throwaway /etc. Args: workdir username
# shellcheck disable=SC2016  # literal $(no): must reach chpasswd unexpanded
TEST_PASS='P@ss :w/ord!^&%x%"q'"'"'$(no)'
run_setup_user() {
    local wd="$1" user="$2"
    mkdir -p "$wd/sudoers.d"
    PATH="$STUB:$PATH" \
    CHPASSWD_LOG="$wd/chpasswd.in" \
    USER_B64="$(printf '%s' "$user" | base64)" \
    PASS_B64="$(printf '%s' "$TEST_PASS" | base64 -w0)" \
    WSL_CONF_FILE="$wd/wsl.conf" \
    WSL_SUDOERS_DIR="$wd/sudoers.d" \
    bash "$REPO/setup-user.sh"
}

# A rotating set of usernames, all valid per wsl-setup.bat's ^[a-z_][a-z0-9_-]*$
USERS=(dev my_user dev-box a_b-c2 ubuntu_ test1 _hidden x)
pick_user() { echo "${USERS[$(( $1 % ${#USERS[@]} ))]}"; }

# Shared invariants for every setup-user.sh run.
check_common() {
    local wd="$1" user="$2" ctx="$3"
    local sfile="$wd/sudoers.d/$user"
    [ -f "$sfile" ] || { bad "$ctx: sudoers file missing"; return; }
    grep -qxF "$user ALL=(ALL) NOPASSWD:ALL" "$sfile" || { bad "$ctx: sudoers content wrong"; return; }
    [ "$(stat -c '%a' "$sfile")" = "440" ] || { bad "$ctx: sudoers mode != 440"; return; }
    grep -q '^\[user\]' "$wd/wsl.conf" || { bad "$ctx: [user] section missing"; return; }
    grep -qx "default=$user" "$wd/wsl.conf" || { bad "$ctx: default=$user missing"; return; }
    [ "$(grep -c '^default=' "$wd/wsl.conf")" = "1" ] || { bad "$ctx: not exactly one default= line"; return; }
    [ "$(cat "$wd/chpasswd.in")" = "$user:$TEST_PASS" ] || { bad "$ctx: chpasswd got a mangled user:password line"; return; }
    ok
}

echo "=== WAY 1: fresh machine (no /etc/wsl.conf), ${ITER}x ==="
for i in $(seq 1 "$ITER"); do
    wd="$WORKROOT/w1_$i"; mkdir -p "$wd"
    u=$(pick_user "$i")
    run_setup_user "$wd" "$u" >/dev/null 2>&1
    # must be exactly the two expected lines, nothing else
    if [ "$(cat "$wd/wsl.conf")" = "$(printf '[user]\ndefault=%s' "$u")" ]; then
        check_common "$wd" "$u" "way1#$i"
    else
        bad "way1#$i: fresh wsl.conf not exactly [user]/default"
    fi
done

echo "=== WAY 2: preserve existing [boot] systemd=true (the clobber bug), ${ITER}x ==="
for i in $(seq 1 "$ITER"); do
    wd="$WORKROOT/w2_$i"; mkdir -p "$wd"
    u=$(pick_user "$i")
    printf '[boot]\nsystemd=true\n' > "$wd/wsl.conf"   # as if setup-dev-tools.sh ran first
    run_setup_user "$wd" "$u" >/dev/null 2>&1
    if grep -qx 'systemd=true' "$wd/wsl.conf" && grep -q '^\[boot\]' "$wd/wsl.conf"; then
        check_common "$wd" "$u" "way2#$i"
    else
        bad "way2#$i: systemd=true / [boot] was clobbered"
    fi
done

echo "=== WAY 3: idempotent re-run (run twice, user already exists), ${ITER}x ==="
for i in $(seq 1 "$ITER"); do
    wd="$WORKROOT/w3_$i"; mkdir -p "$wd"
    u1=$(pick_user "$i"); u2=$(pick_user "$((i + 1))")
    printf '[boot]\nsystemd=true\n' > "$wd/wsl.conf"
    run_setup_user "$wd" "$u1" >/dev/null 2>&1
    TEST_USER_EXISTS=1 run_setup_user "$wd" "$u2" >/dev/null 2>&1   # second pass, different default
    # exactly one default= (updated to u2), systemd still there, no dup [user]
    if [ "$(grep -c '^default=' "$wd/wsl.conf")" = "1" ] \
       && grep -qx "default=$u2" "$wd/wsl.conf" \
       && grep -qx 'systemd=true' "$wd/wsl.conf" \
       && [ "$(grep -c '^\[user\]' "$wd/wsl.conf")" = "1" ]; then
        check_common "$wd" "$u2" "way3#$i"
    else
        bad "way3#$i: re-run not idempotent (dup/clobber/stale default)"
    fi
done

echo "=== WAY 4: existing [user] section with no default= key, ${ITER}x ==="
for i in $(seq 1 "$ITER"); do
    wd="$WORKROOT/w4_$i"; mkdir -p "$wd"
    u=$(pick_user "$i")
    printf '[boot]\nsystemd=true\n[user]\n' > "$wd/wsl.conf"   # [user] present, no default=
    run_setup_user "$wd" "$u" >/dev/null 2>&1
    # default must be inserted under [user]; systemd kept; no duplicate [user]
    if grep -qx 'systemd=true' "$wd/wsl.conf" \
       && [ "$(grep -c '^\[user\]' "$wd/wsl.conf")" = "1" ]; then
        check_common "$wd" "$u" "way4#$i"
    else
        bad "way4#$i: [user]-without-default handled wrong"
    fi
done

echo "=== WAY 5: sudo missing -> installed via the distro package manager, ${ITER}x ==="
# A stub apt-get records that it was asked to install sudo; WSL_SUDO_CMD points
# the "is sudo installed?" probe at a name that cannot exist. Also removes the
# sudoers.d dir up front to prove the script creates it.
# shellcheck disable=SC2016
printf '#!/bin/sh\necho "$*" >> "${APT_LOG:-/dev/null}"\nexit 0\n' > "$STUB/apt-get"
chmod +x "$STUB/apt-get"
for i in $(seq 1 "$ITER"); do
    wd="$WORKROOT/w5_$i"; mkdir -p "$wd"
    u=$(pick_user "$i")
    mkdir -p "$wd/sudoers.d"; rmdir "$wd/sudoers.d"
    PATH="$STUB:$PATH" CHPASSWD_LOG="$wd/chpasswd.in" APT_LOG="$wd/apt.log" \
    WSL_SUDO_CMD="no-such-sudo-$i" \
    USER_B64="$(printf '%s' "$u" | base64)" PASS_B64="$(printf '%s' "$TEST_PASS" | base64 -w0)" \
    WSL_CONF_FILE="$wd/wsl.conf" WSL_SUDOERS_DIR="$wd/sudoers.d" \
    bash "$REPO/setup-user.sh" >/dev/null 2>&1 || true
    if grep -q 'install -y sudo' "$wd/apt.log" 2>/dev/null; then
        check_common "$wd" "$u" "way5#$i"
    else
        bad "way5#$i: missing sudo was not installed"
    fi
done
rm -f "$STUB/apt-get"

# ---- setup-dev-tools.sh wsl.conf logic: the REAL function, sourced ----
SUDO=""   # write directly - no sudo in the harness
# shellcheck source=SCRIPTDIR/../setup-dev-tools.sh
source "$REPO/setup-dev-tools.sh"
dev_enable_systemd() { enable_systemd "$1" || true; }

echo "=== DEV WAYS: enable-systemd across 7 states, ${ITER}x each ==="
for i in $(seq 1 "$ITER"); do
    # a) no file
    f="$WORKROOT/d_a_$i"; dev_enable_systemd "$f"
    if grep -qx 'systemd=true' "$f"; then ok; else bad "devA#$i: no-file"; fi
    # b) [user] only -> appends [boot], keeps [user]
    f="$WORKROOT/d_b_$i"; printf '[user]\ndefault=dev\n' > "$f"; dev_enable_systemd "$f"
    if grep -qx 'systemd=true' "$f" && grep -qx 'default=dev' "$f"; then ok; else bad "devB#$i: user-only"; fi
    # c) existing [boot] with another key -> insert under it, no dup section
    f="$WORKROOT/d_c_$i"; printf '[boot]\ncommand=echo hi\n' > "$f"; dev_enable_systemd "$f"
    if grep -qx 'systemd=true' "$f" && [ "$(grep -c '^\[boot\]' "$f")" = "1" ]; then ok; else bad "devC#$i: existing-boot"; fi
    # d) already has systemd -> idempotent, no second line
    f="$WORKROOT/d_d_$i"; printf '[boot]\nsystemd=true\n' > "$f"; dev_enable_systemd "$f"
    if [ "$(grep -c '^systemd=true' "$f")" = "1" ]; then ok; else bad "devD#$i: already-systemd dup"; fi
    # e) explicit systemd=false -> flipped in place, never two systemd= lines
    f="$WORKROOT/d_e_$i"; printf '[boot]\nsystemd=false\n[user]\ndefault=dev\n' > "$f"; dev_enable_systemd "$f"
    if grep -qx 'systemd=true' "$f" && [ "$(grep -c 'systemd' "$f")" = "1" ] && grep -qx 'default=dev' "$f"; then ok; else bad "devE#$i: systemd=false not flipped"; fi
    # f) last line has no trailing newline -> [boot] must start on its own line
    f="$WORKROOT/d_f_$i"; printf '[user]\ndefault=dev' > "$f"; dev_enable_systemd "$f"
    if grep -qx 'default=dev' "$f" && grep -qx '\[boot\]' "$f" && grep -qx 'systemd=true' "$f"; then ok; else bad "devF#$i: glued onto unterminated last line"; fi
    # g) return code: 0 when it changed the file, 1 when already enabled
    f="$WORKROOT/d_g_$i"; rm -f "$f"
    if enable_systemd "$f" && ! enable_systemd "$f"; then ok; else bad "devG#$i: wrong return code"; fi
done

# ---- the PowerShell embedded in wsl-setup.bat (needs pwsh; skipped if absent) ----
PWSH_BIN="${PWSH:-$(command -v pwsh || true)}"
if [ -n "$PWSH_BIN" ] && [ -x "$PWSH_BIN" ]; then
    for t in bat-powershell.ps1 list-distros.tests.ps1 install-wait.tests.ps1; do
        if "$PWSH_BIN" -NoProfile -File "$HERE/$t"; then ok; else bad "$t reported failures (see above)"; fi
    done
else
    echo "=== PS checks SKIPPED: pwsh not found (set PWSH=/path/to/pwsh to run them) ==="
fi

# ---- full end-to-end run of wsl-setup.bat under Wine (opt-in: slow) ----
if [ -n "${E2E:-}" ]; then
    if bash "$HERE/e2e/run-e2e.sh"; then ok; else bad "e2e/run-e2e.sh reported failures (see above)"; fi
else
    echo "=== E2E SKIPPED: set E2E=1 (needs wine, a MinGW gcc and pwsh) ==="
fi

echo
echo "============================================"
echo " RESULTS: $pass passed, $fail failed"
echo "============================================"
if [ "$fail" -ne 0 ]; then
    printf ' FAIL: %s\n' "${FAILMSGS[@]}" | sort | uniq -c | sort -rn | head -20 || true
    exit 1
fi
echo " All checks passed."
