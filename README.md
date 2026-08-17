# wsl-setup

![wsl-setup](assets/banner.svg)

Interactive, guided WSL setup wizard for a Windows PC. Run one `.bat` file and it walks you through: entering a username/password, enabling WSL on the machine if it isn't already (with an auto-resume after the required reboot), and picking a Linux distro from a numbered menu to install.

## Usage

1. Clone or download this repo onto your Windows machine.
2. Run `wsl-setup.bat` (just double-click it, or run from `cmd.exe`).
3. Enter a username and password when prompted. **These are shown on screen in plain text as you type and saved in plain text to `credentials.txt` next to the script** — this is intentional for this interactive variant, not a bug. Don't reuse a real/sensitive password here.
4. If WSL isn't enabled yet on this machine, the script requests admin rights, enables it, and offers to restart. If you restart, it automatically continues where it left off after you log back in (via a one-time registry `RunOnce` entry) — no need to re-run it yourself.
5. Pick a distro from the numbered menu (1–22, e.g. `1` for Ubuntu, `10` for Debian) and it installs it via `wsl --install -d <name>`.
6. When the new distro opens for the first time to create its own Linux user, use the same username/password you entered in step 3.

If WSL is already enabled on the machine (the common case), no admin elevation or reboot happens at all — it goes straight from credentials to the distro menu.

## What it does

`wsl-setup.bat`:
- Prompts for a username/password (plain text, saved locally to `credentials.txt`).
- Checks `wsl --status`; only elevates to Administrator and enables WSL2 + required Windows features if it isn't already set up.
- If a reboot is required, sets a `RunOnce` registry entry so the script auto-resumes after login instead of needing to be re-run manually.
- Shows a numbered menu of every distro currently available via `wsl --list --online` and installs the one you pick.

`setup-dev-tools.sh` (nvm/Node, Docker, GitHub CLI — run separately inside a WSL distro, no longer auto-chained by `wsl-setup.bat`):

```bash
bash setup-dev-tools.sh
```

## Notes

- Password is intentionally shown and stored in plain text (`credentials.txt`) by design for this interactive flow — delete that file when you're done if you don't want it lingering.
- `credentials.txt` and `wsl_setup_state.txt` are working files the script creates next to itself; safe to delete once setup is finished.
