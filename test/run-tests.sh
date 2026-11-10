#!/usr/bin/env bash
#
# run-tests.sh - exercise the WSL-setup shell logic without root or a real
# distro, 100 iterations per scenario ("each way").
#
# What is REAL vs REPLICA:
#   * setup-user.sh is run FOR REAL (the actual shipped file), with useradd/
#     chpasswd/usermod stubbed on PATH and /etc paths redirected to a temp dir
#     via the WSL_CONF_FILE / WSL_SUDOERS_DIR overrides the script honours.
#   * The setup-dev-tools.sh wsl.conf logic is tested via a REPLICA function
#     (that script can't be sourced without running apt). A drift check asserts
#     the replica still matches the real lines, so it fails loudly if the shipped
#     logic changes.
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
printf '#!/bin/sh\ncat >/dev/null 2>&1\nexit 0\n' > "$STUB/chpasswd"
chmod +x "$STUB/chpasswd"
# `id -u <user>` decides create-vs-skip. Default: user missing (exit 1).
cat > "$STUB/id" <<'EOF'
#!/bin/sh
[ "${TEST_USER_EXISTS:-0}" = "1" ] && exit 0
exit 1
EOF
chmod +x "$STUB/id"

# Run the REAL setup-user.sh against a throwaway /etc. Args: workdir username
run_setup_user() {
    local wd="$1" user="$2"
    mkdir -p "$wd/sudoers.d"
    PATH="$STUB:$PATH" \
    USER_B64="$(printf '%s' "$user" | base64)" \
    PASS_B64="$(printf '%s' 'P@ss :w/ord!' | base64)" \
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

# ---- setup-dev-tools.sh wsl.conf logic (REPLICA + drift check) ----
echo "=== DRIFT CHECK: replica matches shipped setup-dev-tools.sh ==="
if grep -Fq "sed -i '/^\[boot\]/a systemd=true'" "$REPO/setup-dev-tools.sh" \
   && grep -Fq "grep -q '^systemd=true'" "$REPO/setup-dev-tools.sh"; then
    ok
else
    bad "DRIFT: setup-dev-tools.sh wsl.conf logic changed - update this replica"
fi

# Replica of setup-dev-tools.sh lines ~40-50, operating on an arbitrary file.
dev_enable_systemd() {
    local conf="$1"
    if [ ! -f "$conf" ] || ! grep -q '^systemd=true' "$conf"; then
        if [ -f "$conf" ] && grep -q '^\[boot\]' "$conf"; then
            sed -i '/^\[boot\]/a systemd=true' "$conf"
        else
            printf '[boot]\nsystemd=true\n' >> "$conf"
        fi
    fi
}

echo "=== DEV WAYS: enable-systemd across 4 states, ${ITER}x each ==="
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
done

echo
echo "============================================"
echo " RESULTS: $pass passed, $fail failed"
echo "============================================"
if [ "$fail" -ne 0 ]; then
    printf ' FAIL: %s\n' "${FAILMSGS[@]}" | sort | uniq -c | sort -rn | head -20 || true
    exit 1
fi
echo " All checks passed."
