#!/usr/bin/env bash
#
# setup-user.sh - create/configure the WSL Linux account, run as root inside the
# target distro by wsl-setup.bat. The username and password are passed in
# base64-encoded via the environment (USER_B64 / PASS_B64, forwarded through
# WSLENV) so they never land on a command line or on disk in cleartext.
#
# Idempotent: safe to run more than once. Only the account setup is done here;
# the distro install and default-user wiring stay in wsl-setup.bat.
#
# The /etc and user-management entry points are indirected through variables so
# the test harness can exercise this exact file without root or a real distro.
# In production the defaults below are used unchanged.
set -euo pipefail

: "${USER_B64:?USER_B64 not set - run via wsl-setup.bat}"
: "${PASS_B64:?PASS_B64 not set - run via wsl-setup.bat}"

# Overridable only for testing; default to the real system locations.
CONF_FILE="${WSL_CONF_FILE:-/etc/wsl.conf}"
SUDOERS_DIR="${WSL_SUDOERS_DIR:-/etc/sudoers.d}"
SUDO_CMD="${WSL_SUDO_CMD:-sudo}"

# --- make sure sudo exists ---
# Some minimal WSL images ship without sudo. Without it the NOPASSWD rule below
# is useless (and /etc/sudoers.d may not even exist), so install it first.
# Best-effort: a failure here is reported but does not abort account creation.
if ! command -v "$SUDO_CMD" >/dev/null 2>&1; then
    echo "sudo is not installed in this distro - installing it ..."
    if command -v apt-get >/dev/null 2>&1; then
        { apt-get update -y && DEBIAN_FRONTEND=noninteractive apt-get install -y sudo; } || echo "WARN: could not install sudo via apt-get" >&2
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y sudo || echo "WARN: could not install sudo via dnf" >&2
    elif command -v pacman >/dev/null 2>&1; then
        pacman -Syu --noconfirm --needed sudo || echo "WARN: could not install sudo via pacman" >&2
    elif command -v zypper >/dev/null 2>&1; then
        zypper --non-interactive install sudo || echo "WARN: could not install sudo via zypper" >&2
    else
        echo "WARN: no known package manager found - install sudo manually" >&2
    fi
fi

u=$(printf '%s' "$USER_B64" | base64 -d)
p=$(printf '%s' "$PASS_B64" | base64 -d)

# --- account ---
# Create the user only if missing (idempotent re-run).
id -u "$u" >/dev/null 2>&1 || useradd -m -s /bin/bash "$u"
# Set/refresh the password from stdin - never on the command line.
printf '%s:%s\n' "$u" "$p" | chpasswd
# Add to the admin group. Debian/Ubuntu use 'sudo'; Fedora/Arch/openSUSE use
# 'wheel'. Membership is best-effort - the NOPASSWD rule below is what actually
# grants sudo, so this must not abort the script if the group is absent.
usermod -aG sudo "$u" 2>/dev/null || usermod -aG wheel "$u" 2>/dev/null || true

# --- passwordless sudo ---
# The username is validated by wsl-setup.bat against ^[a-z_][a-z0-9_-]*$ before
# we get here, so it contains no sudoers- or sed-special characters.
mkdir -p "$SUDOERS_DIR"
printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$u" > "$SUDOERS_DIR/$u"
chmod 0440 "$SUDOERS_DIR/$u"

# --- default user in wsl.conf, WITHOUT clobbering other sections ---
# A plain `> wsl.conf` would wipe a [boot] systemd=true that setup-dev-tools.sh
# may have added, silently disabling Docker's init on the next boot. Instead,
# set default= under [user] in place and leave every other section intact.
if [ -f "$CONF_FILE" ]; then
    if grep -q '^\[user\]' "$CONF_FILE"; then
        if grep -q '^default=' "$CONF_FILE"; then
            sed -i "s/^default=.*/default=$u/" "$CONF_FILE"
        else
            sed -i "/^\[user\]/a default=$u" "$CONF_FILE"
        fi
    else
        printf '\n[user]\ndefault=%s\n' "$u" >> "$CONF_FILE"
    fi
else
    printf '[user]\ndefault=%s\n' "$u" > "$CONF_FILE"
fi
