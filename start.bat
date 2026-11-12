@echo off
setlocal
REM start.bat - open your default WSL distro in an Administrator window, after
REM wsl-setup.bat has run. Double-click it, or run it from cmd. If WSL cannot
REM start, the window stays open and says why, instead of flashing shut.
REM
REM Same elevation as wsl-setup.bat: fltmc only succeeds when elevated, and
REM the path goes to PowerShell via an env var, so folder names with an
REM apostrophe still work. Distros belong to one Windows account, so this
REM opens the distros of the account that approves the UAC prompt - the same
REM one wsl-setup.bat installed them for.
REM
REM Usage: start.bat [distro]   - with no name it opens the default distro.
REM wsl-setup.bat passes the name of the distro it has just set up, so its
REM "Start WSL now" opens exactly that one even if another is the default.
set "WSL_START_DISTRO=%~1"
fltmc >nul 2>&1
if not "%errorlevel%"=="0" (
    set "WSL_START_SELF=%~f0"
    powershell -NoProfile -Command "$a = @{ FilePath = $env:WSL_START_SELF; Verb = 'RunAs' }; if ($env:WSL_START_DISTRO) { $a.ArgumentList = $env:WSL_START_DISTRO }; try { Start-Process @a -ErrorAction Stop } catch { exit 1 }"
    if errorlevel 1 (
        echo Administrator rights were not granted - WSL was not started.
        pause
    )
    exit /b
)
title WSL - Administrator
REM An elevated window starts in System32; start in this folder instead, as
REM a double-click without elevation would.
cd /d "%~dp0"

where wsl.exe >nul 2>&1
if errorlevel 1 goto NOWSL

REM  Every installed distro has a DistributionName value under this key, for
REM  this Windows account only (the same lookup wsl-setup.bat uses). findstr
REM  decides, because reg.exe's own exit code for "0 matches" is not reliable.
reg query "HKCU\Software\Microsoft\Windows\CurrentVersion\Lxss" /s /v DistributionName 2>nul | findstr /i /c:"DistributionName" >nul
if errorlevel 1 goto NODISTRO

REM  A quick no-op first: if the distro cannot start, wsl.exe prints its own
REM  error here and the reason is still on screen for the hints below.
if defined WSL_START_DISTRO goto NAMED
REM  Not `if errorlevel 1`: wsl.exe exits with -1 for its own errors (such
REM  as WSL_E_DISTRO_NOT_FOUND), and -1 is not ">= 1".
wsl.exe -- true
if not "%errorlevel%"=="0" goto CANTSTART

wsl.exe
exit /b

:NAMED
REM  The name goes onto the wsl.exe command line as it is - wsl.exe looks
REM  for a distro whose name includes the quotes if it is quoted - so only
REM  a plain distro name is let through. Checked from an env var, never
REM  spliced into the PowerShell command.
powershell -NoProfile -Command "if ($env:WSL_START_DISTRO -cmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') { exit 0 } else { exit 1 }"
if errorlevel 1 goto BADNAME
wsl.exe -d %WSL_START_DISTRO% -- true
if not "%errorlevel%"=="0" goto CANTSTART

wsl.exe -d %WSL_START_DISTRO%
exit /b

:BADNAME
echo.
echo [ERROR] That is not a distro name. Use a name from:  wsl --list --verbose
goto FAIL

:NOWSL
echo.
echo [ERROR] wsl.exe was not found - WSL is not installed on this PC yet.
echo         Run wsl-setup.bat first. If it asks for a restart, restart
echo         Windows and run wsl-setup.bat again.
goto FAIL

:NODISTRO
echo.
echo [ERROR] No Linux distro is installed for this Windows account:
whoami
echo.
echo   Why this happens:
echo   1. wsl-setup.bat stopped and asked for a restart. The first run only
echo      turns WSL on. Restart Windows, run wsl-setup.bat again and pick
echo      the same distro - it finishes the install.
echo   2. wsl-setup.bat was approved with a different Administrator account
echo      than this window. A distro belongs to the account that installed
echo      it. Approve the prompt with that same account, or run
echo      wsl-setup.bat again and install the distro for this one.
echo.
echo   What WSL itself reports:
wsl.exe --list --verbose
goto FAIL

:CANTSTART
echo.
echo [ERROR] WSL could not start - its own message is just above.
echo.
echo   Common fixes:
echo   - Restart Windows, then run start.bat again. A first WSL install
echo     is not finished until the PC has restarted.
echo   - Error 0x80370102 or "Virtual Machine Platform": turn virtualization
echo     on in the BIOS/UEFI setup. In a virtual machine, turn on nested
echo     virtualization for it.
echo   - Run:  wsl --update
echo.
echo   What WSL itself reports:
wsl.exe --status
wsl.exe --list --verbose
goto FAIL

:FAIL
echo.
pause
exit /b 1
