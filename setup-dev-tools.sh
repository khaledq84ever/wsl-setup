#!/usr/bin/env bash
set -euo pipefail

echo "============================================"
echo " Dev tools setup (inside WSL)"
echo "============================================"

sudo apt-get update -y
sudo apt-get install -y curl git ca-certificates gnupg build-essential

# ---- Node.js via nvm ----
if [ ! -d "$HOME/.nvm" ]; then
    echo "--- Installing nvm ---"
    curl -fsSL --retry 3 --retry-delay 2 https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.6/install.sh | bash
fi
export NVM_DIR="$HOME/.nvm"
# shellcheck disable=SC1091
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
# Only install Node when there is no default yet - avoids a network round-trip
# and a redundant reinstall on every re-run (this script is meant to be re-runnable).
if ! nvm which default >/dev/null 2>&1; then
    echo "--- Installing Node LTS ---"
    nvm install --lts
    nvm alias default 'lts/*'
else
    echo "--- Node already installed ($(nvm which default)) - skipping ---"
fi

# ---- Docker Engine ----
DOCKER_GROUP_ADDED=0
if ! command -v docker >/dev/null 2>&1; then
    echo "--- Installing Docker ---"
    curl -fsSL --retry 3 --retry-delay 2 https://get.docker.com | sudo sh
    sudo usermod -aG docker "$USER"
    DOCKER_GROUP_ADDED=1
fi

# enable systemd so dockerd persists across shells (needs wsl --shutdown to take effect)
NEEDS_RESTART=0
if [ ! -f /etc/wsl.conf ] || ! grep -q '^systemd=true' /etc/wsl.conf; then
    echo "--- Enabling systemd in /etc/wsl.conf ---"
    if [ -f /etc/wsl.conf ] && grep -q '^\[boot\]' /etc/wsl.conf; then
        # [boot] section already exists - add systemd under it instead of
        # appending a duplicate [boot] section.
        sudo sed -i '/^\[boot\]/a systemd=true' /etc/wsl.conf
    else
        printf '[boot]\nsystemd=true\n' | sudo tee -a /etc/wsl.conf >/dev/null
    fi
    NEEDS_RESTART=1
fi

# ---- GitHub CLI ----
if ! command -v gh >/dev/null 2>&1; then
    echo "--- Installing GitHub CLI ---"
    curl -fsSL --retry 3 --retry-delay 2 https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
    sudo chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | \
        sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
    sudo apt-get update -y
    sudo apt-get install -y gh
fi

echo
echo "============================================"
echo " Done. Versions:"
node -v 2>/dev/null || echo "node: (open a new shell first)"
docker --version 2>/dev/null || true
gh --version 2>/dev/null || true
echo "============================================"

if [ "$DOCKER_GROUP_ADDED" = "1" ]; then
    echo
    echo "You were added to the 'docker' group. For docker to work without sudo,"
    echo "open a new shell (or run 'newgrp docker') so the group membership applies."
fi

if [ "${NEEDS_RESTART:-0}" = "1" ]; then
    echo
    echo "systemd was just enabled for Docker to work properly."
    echo "Run 'wsl --shutdown' in PowerShell, then reopen your WSL terminal."
fi
