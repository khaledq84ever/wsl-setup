# wsl-setup

![wsl-setup](assets/banner-1-terminal.svg)

One-shot, fully automated WSL + dev tools installer for a Windows PC. Run one `.bat` file as admin and end up with Ubuntu-on-WSL2, a non-root user with passwordless sudo, Node.js (via nvm), Docker, and GitHub CLI already authenticated.

## Usage

1. Clone or download this repo onto your Windows machine.
2. Run `wsl-setup.bat` (right-click → Run as administrator, or just double-click — it self-elevates).
3. You'll be prompted twice, both masked and both stay entirely on your machine:
   - A password for the new WSL Linux user (default username `khaled`).
   - A GitHub Personal Access Token (create one first at https://github.com/settings/tokens/new with `repo`, `workflow`, `read:org` scopes — or leave it blank to skip).

That's it. No other prompts.

```
wsl-setup.bat [distro] [username]
```

Defaults to `Ubuntu` / `khaled` if no arguments are given.

## CLI reference

Run from `cmd.exe` or PowerShell, from inside the cloned repo folder. All fully non-interactive except the two masked prompts described above.

```bat
:: default: Ubuntu + user "khaled"
wsl-setup.bat

:: explicit distro + username
wsl-setup.bat Ubuntu khaled
wsl-setup.bat Debian khaled

:: check what distro names are available on your machine first
wsl --list --online
```

Clone + run in one go (PowerShell, as admin):

```powershell
git clone https://github.com/khaledq84ever/wsl-setup.git
cd wsl-setup
.\wsl-setup.bat
```

Re-running is safe and idempotent — it skips any step already done (existing distro, existing user, existing dev tools, existing `gh` auth) and just fills in whatever's missing.

To run only the dev-tools half (nvm/Node, Docker, `gh`) inside a WSL distro you already have set up, skip `wsl-setup.bat` entirely and run `setup-dev-tools.sh` directly from a WSL shell:

```bash
bash setup-dev-tools.sh
```

## Lightweight distro option

`Debian` is a lighter alternative to `Ubuntu` for WSL — same `apt` package manager, same commands, smaller base image, and it's Ubuntu's own upstream base. `setup-dev-tools.sh` is apt-based and distro-agnostic, so it runs unmodified on Debian too:

```bat
wsl-setup.bat Debian khaled
```

Confirm the exact Store name first with `wsl --list --online`.

## What it does

`wsl-setup.bat`:
- Installs WSL2 + Ubuntu headlessly (`wsl --install --no-launch`, no OOBE console).
- If the machine needs WSL/Virtualization features enabled first, enables them and auto-reboots (10s warning) — re-run the script after reboot to finish.
- Creates the Linux user non-interactively, grants passwordless `sudo`, sets it as the WSL default user.
- Runs `setup-dev-tools.sh` inside WSL.
- Authenticates `gh` non-interactively via the token you enter (`gh auth login --with-token` + `gh auth setup-git`, so plain `git push`/`clone` over HTTPS also just works).
- Safe to re-run: skips any step that's already done (existing user, existing installs, existing `gh` auth).

`setup-dev-tools.sh` (runs inside WSL):
- nvm + Node.js LTS
- Docker Engine (via `get.docker.com`), plus enables `systemd` in `/etc/wsl.conf` so `dockerd` persists across shells
- GitHub CLI (`gh`)

## Notes

- The password/token never pass through any AI chat or log — they're entered locally via a masked PowerShell prompt at run time and forwarded into WSL only via `WSLENV` (env-var forwarding), never as command-line arguments.
- After the dev-tools step, WSL restarts once more to activate systemd. If you re-run the script later, that restart happens again — harmless, just closes and reopens your WSL session.
- Tested end-to-end (not just read-through): the WSL-side install steps in a real Ubuntu Docker container as a non-root sudo user, and the batch script's full control flow (fresh install, idempotent re-run, reboot-needed fallback) via Wine's `cmd.exe` with stubbed Windows commands.
