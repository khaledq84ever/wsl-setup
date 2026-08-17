@echo off
setlocal enabledelayedexpansion

:: ---- self-elevate to admin ----
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator privileges...
    powershell -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)

set "DISTRO=%~1"
if "%DISTRO%"=="" set "DISTRO=Ubuntu"
set "WSLUSER=%~2"
if "%WSLUSER%"=="" set "WSLUSER=khaled"

echo ============================================
echo  WSL Auto Setup
echo  Distro:   %DISTRO%
echo  Username: %WSLUSER%
echo ============================================

:: keep the WSL launcher itself current so flags like --no-launch behave
wsl --update >nul 2>&1

:: ---- ensure distro is registered ----
wsl -d %DISTRO% -- true >nul 2>&1
if %errorlevel% neq 0 (
    echo Installing %DISTRO% ^(no OOBE prompt^)...
    wsl --install -d %DISTRO% --no-launch
    wsl -d %DISTRO% -- true >nul 2>&1
    if !errorlevel! neq 0 (
        echo.
        echo WSL/virtualization features aren't ready yet - enabling them now.
        dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart
        dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart
        echo.
        echo A REBOOT is required - rebooting automatically in 10 seconds.
        echo Save any open work now. Re-run this script after reboot to finish.
        shutdown /r /t 10
        goto :end
    )
)

:: ---- create user if missing (fully non-interactive) ----
wsl -d %DISTRO% -u root -- id -u %WSLUSER% >nul 2>&1
if %errorlevel% neq 0 (
    echo.
    echo Creating Linux user "%WSLUSER%"...
    for /f "usebackq delims=" %%P in (`powershell -NoProfile -Command "$s=Read-Host -AsSecureString 'Password for %WSLUSER% in WSL'; [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($s))"`) do set "WSLPASS=%%P"
    if "!WSLPASS!"=="" (
        echo No password entered - aborting.
        goto :end
    )
    set "WSLENV=WSLPASS"

    wsl -d %DISTRO% -u root -- bash -c "useradd -m -s /bin/bash -G sudo %WSLUSER%"
    wsl -d %DISTRO% -u root -- bash -c "echo \"%WSLUSER%:$WSLPASS\" | chpasswd"
    wsl -d %DISTRO% -u root -- bash -c "echo '%WSLUSER% ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/%WSLUSER% && chmod 440 /etc/sudoers.d/%WSLUSER%"
    wsl -d %DISTRO% -u root -- bash -c "sed -i '/^\[user\]/,+1d' /etc/wsl.conf 2>/dev/null; printf '[user]\ndefault=%WSLUSER%\n\n' >> /etc/wsl.conf"

    set "WSLPASS="
    echo Restarting %DISTRO% to apply default user...
    wsl --terminate %DISTRO%
) else (
    echo User %WSLUSER% already exists - skipping account creation.
)

:: ---- run dev tools setup (nvm/Node, Docker, gh) - no prompts, passwordless sudo ----
set "SH=%~dp0setup-dev-tools.sh"
if not exist "%SH%" (
    echo setup-dev-tools.sh not found next to this script - skipping dev tools.
    goto :end
)
echo.
echo Running dev tools setup inside %DISTRO% ^(nvm/Node, Docker, gh^)...
wsl -d %DISTRO% -- bash -c "bash \"$(wslpath '%SH%')\""

echo.
echo Restarting WSL once more to activate systemd for Docker...
wsl --shutdown
timeout /t 3 /nobreak >nul
wsl -d %DISTRO% -- bash -c "whoami; node -v; docker --version; gh --version"

:: ---- GitHub auth (non-interactive, via Personal Access Token) ----
wsl -d %DISTRO% -- bash -c "gh auth status" >nul 2>&1
if %errorlevel% neq 0 (
    echo.
    echo GitHub CLI isn't authenticated yet.
    echo Create a token first ^(if you don't have one^): https://github.com/settings/tokens/new
    echo   Recommended scopes: repo, workflow, read:org
    echo.
    for /f "usebackq delims=" %%T in (`powershell -NoProfile -Command "$s=Read-Host -AsSecureString 'GitHub Personal Access Token (leave empty to skip)'; [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($s))"`) do set "GHTOKEN=%%T"

    if not "!GHTOKEN!"=="" (
        set "WSLENV=GHTOKEN"
        wsl -d %DISTRO% -- bash -c "echo \"$GHTOKEN\" | gh auth login --hostname github.com --git-protocol https --with-token"
        wsl -d %DISTRO% -- bash -c "gh auth setup-git"
        set "GHTOKEN="
        wsl -d %DISTRO% -- bash -c "gh auth status"
    ) else (
        echo Skipped - run 'gh auth login' manually inside WSL later.
    )
)

:end
echo.
echo Setup finished.
