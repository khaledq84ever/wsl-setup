#!/usr/bin/env bash
#
# setup-dev-tools.sh - install nvm/Node (LTS), Docker Engine and the GitHub CLI
# inside a Debian/Ubuntu WSL distro. Safe to re-run: every step is skipped when
# it is already done.
#
# The script only runs its main body when executed directly. When sourced (as
# test/run-tests.sh does) it just defines its functions, so the harness can
# exercise the real wsl.conf logic instead of a hand-maintained copy.
set -euo pipefail

# Command used for privileged writes. Overridable only so the test harness can
# run enable_systemd() unprivileged; defaults to sudo.
SUDO="${SUDO-sudo}"

# Ensure `[boot] systemd=true` is present in the given wsl.conf, without
# duplicating sections or keys and without touching any other section.
# Returns 0 if the file was changed, 1 if systemd was already enabled.
enable_systemd() {
    local conf="$1" nl=""
    if [ -f "$conf" ] && grep -Eq '^[[:space:]]*systemd[[:space:]]*=[[:space:]]*true[[:space:]]*$' "$conf"; then
        return 1
    fi
    if [ -f "$conf" ] && grep -Eq '^[[:space:]]*systemd[[:space:]]*=' "$conf"; then
        # An explicit systemd=false (or anything else): flip it in place rather
        # than adding a second, conflicting systemd= line.
        $SUDO sed -i -E 's/^[[:space:]]*systemd[[:space:]]*=.*/systemd=true/' "$conf"
    elif [ -f "$conf" ] && grep -q '^\[boot\]' "$conf"; then
        # [boot] section already exists - add systemd under it instead of
        # appending a duplicate [boot] section.
        $SUDO sed -i '/^\[boot\]/a systemd=true' "$conf"
    else
        # If the file does not end in a newline, appending "[boot]" would glue
        # it onto the last line (e.g. "default=dev[boot]") and break both keys.
        if [ -s "$conf" ] && [ -n "$(tail -c1 "$conf")" ]; then
            nl=$'\n'
        fi
        printf '%s[boot]\nsystemd=true\n' "$nl" | $SUDO tee -a "$conf" >/dev/null
    fi
    return 0
}

main() {
    echo "============================================"
    echo " Dev tools setup (inside WSL)"
    echo "============================================"

    # Everything below (apt, the Docker apt repo, the gh apt repo) is
    # Debian/Ubuntu-specific. wsl-setup.bat offers this script for any distro,
    # so fail clearly up front instead of halfway through on Fedora/Arch/etc.
    if ! command -v apt-get >/dev/null 2>&1; then
        echo "ERROR: this script supports Debian/Ubuntu-based distros only (apt-get not found)." >&2
        echo "       Install Node, Docker and gh with your distro's package manager instead." >&2
        exit 1
    fi

    # $USER is not guaranteed to be set when launched via `wsl.exe -- bash ...`,
    # and `set -u` would abort on it - ask the system instead.
    local me
    me=$(id -un)

    # noninteractive: a package that asks a debconf question (tzdata etc.)
    # would otherwise stall the unattended run started by wsl-setup.bat.
    export DEBIAN_FRONTEND=noninteractive
    sudo -E apt-get update -y
    sudo -E apt-get install -y curl git ca-certificates gnupg build-essential

    # ---- Node.js via nvm ----
    if [ ! -d "$HOME/.nvm" ]; then
        echo "--- Installing nvm ---"
        curl -fsSL --retry 3 --retry-delay 2 https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.8/install.sh | bash
    fi
    export NVM_DIR="$HOME/.nvm"
    # nvm.sh is not written for `set -u`; relax it while nvm runs.
    set +u
    # shellcheck disable=SC1091
    [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
    # Only install Node when there is no default yet - avoids a network
    # round-trip and a redundant reinstall on every re-run.
    if ! nvm which default >/dev/null 2>&1; then
        echo "--- Installing Node LTS ---"
        nvm install --lts
        nvm alias default 'lts/*'
    else
        echo "--- Node already installed ($(nvm which default)) - skipping ---"
    fi
    set -u

    # ---- Docker Engine ----
    local docker_group_added=0
    if ! command -v docker >/dev/null 2>&1; then
        echo "--- Installing Docker ---"
        curl -fsSL --retry 3 --retry-delay 2 https://get.docker.com | sudo sh
    fi
    # Checked separately from the install so a re-run after a half-finished
    # first run still adds the group.
    if getent group docker >/dev/null 2>&1 && [[ " $(id -nG "$me") " != *" docker "* ]]; then
        sudo usermod -aG docker "$me"
        docker_group_added=1
    fi

    # enable systemd so dockerd persists across shells (needs wsl --shutdown)
    local needs_restart=0
    if enable_systemd /etc/wsl.conf; then
        echo "--- Enabled systemd in /etc/wsl.conf ---"
        needs_restart=1
    fi

    # ---- GitHub CLI ----
    if ! command -v gh >/dev/null 2>&1; then
        echo "--- Installing GitHub CLI ---"
        sudo mkdir -p -m 755 /etc/apt/keyrings
        curl -fsSL --retry 3 --retry-delay 2 https://cli.github.com/packages/githubcli-archive-keyring.gpg \
            | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null
        sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
            | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
        sudo -E apt-get update -y
        sudo -E apt-get install -y gh
    fi

    echo
    echo "============================================"
    echo " Done. Versions:"
    node -v 2>/dev/null || echo "node: (open a new shell first)"
    docker --version 2>/dev/null || true
    gh --version 2>/dev/null | head -1 || true
    echo "============================================"

    if [ "$docker_group_added" = "1" ]; then
        echo
        echo "You were added to the 'docker' group. For docker to work without sudo,"
        echo "open a new shell (or run 'newgrp docker') so the group membership applies."
    fi

    if [ "$needs_restart" = "1" ]; then
        echo
        echo "systemd was just enabled for Docker to work properly."
        echo "Run 'wsl --shutdown' in PowerShell, then reopen your WSL terminal."
    fi
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
