@echo off
REM start-wsl.bat - open your default WSL distro in an Administrator window.
REM Same elevation as wsl-setup.bat: fltmc only succeeds when elevated, and
REM the path goes to PowerShell via an env var, so folder names with an
REM apostrophe still work.
fltmc >nul 2>&1
if not "%errorlevel%"=="0" (
    set "WSL_START_SELF=%~f0"
    powershell -NoProfile -Command "try { Start-Process -FilePath $env:WSL_START_SELF -Verb RunAs -ErrorAction Stop } catch { exit 1 }"
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
wsl.exe
