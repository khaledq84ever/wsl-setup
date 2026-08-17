# wsl-setup

![wsl-setup](assets/banner.svg)

Fully automatic WSL setup for a Windows PC. Run one `.bat` file, pick a distro from a 3-item menu, and it does the rest — no interactive WSL setup wizard, no typing anything except a username/password once.

## Usage

1. Clone or download this repo onto your Windows machine.
2. Run `wsl-setup.bat` (double-click it, or run from `cmd.exe`). It self-elevates to Administrator via UAC.
3. Pick an option:
   - `1` Ubuntu (latest LTS)
   - `2` Debian (lighter/smaller than Ubuntu)
   - `3` Wine (installs into a distro you already have)
4. For options 1/2, enter a new Linux username and password when prompted (password input is masked).
5. The script installs the distro (`wsl --install -d <name> --no-launch --web-download`), waits for it to become ready, then creates the Linux user itself — `useradd`, `chpasswd`, adds to `sudo`, and grants **passwordless sudo** (`/etc/sudoers.d/<user>`, validated with `visudo -c`) so system commands run without a prompt.
6. It sets that user as the distro's default user, sets the distro as the **machine's** default (`wsl --set-default`), and verifies that typing plain `wsl` in any terminal drops straight into that user with no prompts.
7. It writes/refreshes `start-wsl.bat` next to itself — a one-line launcher (`wsl.exe`) for quick access afterward.
8. On success the window closes itself after a few seconds; on any error it pauses so you can read what went wrong.

## What it does differently from the built-in `wsl --install` wizard

- **No plaintext credentials anywhere.** The password lives only in the running script's memory, is passed straight to `wsl.exe` to create the account, then is cleared (`set "wslPass="`) immediately after use. Nothing is written to a log, temp file, or disk.
- **Bypasses two documented first-install pitfalls:** uses `--web-download` (Microsoft's own fix for installs hanging at 0.0%) and checks the Windows build number up front (WSL needs build 19041+), instead of failing partway with a confusing error.
- **Explains the reboot case.** A first-ever WSL install on a machine can require a Windows restart partway through; if that happens, the script says so plainly and tells you to just re-run it afterward.

## Wine option

Choose `3` from the menu to install Wine (`wine`, `wine32`, `wine64`, `winetricks`) into an already-installed distro. If more than one distro is installed, you're asked which one. It runs as `root` inside WSL (not via `sudo`), so there's no password prompt, and `apt` output is shown live in the same window.

`setup-dev-tools.sh` (nvm/Node, Docker, GitHub CLI — run separately inside a WSL distro, not chained by `wsl-setup.bat`):

```bash
bash setup-dev-tools.sh
```

## Notes

- The created Linux user has **passwordless sudo** — convenient for a personal dev machine, but means any process running as that user can act as root without a password. Don't use this on a shared or security-sensitive machine.
- Re-running the script against a distro that's already installed is safe — user creation is idempotent (`id -u ... || useradd ...`).
