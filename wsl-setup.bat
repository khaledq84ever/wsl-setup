@echo off
setlocal EnableDelayedExpansion
title WSL Full Setup Wizard

set "SCRIPT_PATH=%~f0"
set "CRED_FILE=%~dp0credentials.txt"
set "STATE_FILE=%~dp0wsl_setup_state.txt"
set "RUNONCE_KEY=HKCU\Software\Microsoft\Windows\CurrentVersion\RunOnce"
set "RUNONCE_NAME=WSLFullSetup"

echo ================================================
echo   WSL Full Setup Wizard
echo ================================================
echo.

rem ==========================================================
rem  Figure out if we're resuming after a reboot
rem ==========================================================
set "RESUME_STAGE=START"
if exist "%STATE_FILE%" (
    set /p RESUME_STAGE=<"%STATE_FILE%"
)

if /i "!RESUME_STAGE!"=="AFTER_ENABLE" (
    echo Resuming setup after restart...
    echo.
    if exist "%CRED_FILE%" (
        for /f "usebackq tokens=1,2 delims==" %%A in ("%CRED_FILE%") do (
            if /i "%%A"=="Username" set "USERNAME=%%B"
            if /i "%%A"=="Password" set "PASSWORD=%%B"
        )
    )
    goto DISTROMENU
)

rem ==========================================================
rem  Step 1: collect username / password
rem ==========================================================
echo Step 1: Set the username and password you'll use.
echo (You'll enter the same ones inside your new Linux distro the first time it opens.)
echo.
set /p "USERNAME=Enter username: "
set /p "PASSWORD=Enter password: "
echo.
echo ----------------------------
echo Username: %USERNAME%
echo Password: %PASSWORD%
echo ----------------------------
echo.

(
    echo Username=%USERNAME%
    echo Password=%PASSWORD%
) > "%CRED_FILE%"
echo Credentials saved to "%CRED_FILE%"
echo.

rem ==========================================================
rem  Step 2: check whether WSL is already enabled
rem  (only elevate to Administrator if we actually need to
rem  enable WSL - installing a distro on an already-enabled
rem  machine does not require admin rights)
rem ==========================================================
echo Step 2: Checking WSL status on this machine...
set "NEED_ENABLE=0"

where wsl.exe >nul 2>&1
if errorlevel 1 (
    set "NEED_ENABLE=1"
) else (
    wsl.exe --status >nul 2>&1
    if errorlevel 1 set "NEED_ENABLE=1"
)

if "%NEED_ENABLE%"=="1" (
    net session >nul 2>&1
    if not "%errorlevel%"=="0" (
        echo Administrator rights are needed to enable WSL on this machine.
        echo Requesting elevation...
        echo AFTER_ENABLE> "%STATE_FILE%"
        reg add "%RUNONCE_KEY%" /v "%RUNONCE_NAME%" /t REG_SZ /d "\"%SCRIPT_PATH%\"" /f >nul
        powershell -NoProfile -Command "Start-Process -FilePath '%SCRIPT_PATH%' -Verb RunAs"
        exit /b
    )

    echo WSL is not fully set up yet on this machine. Enabling it now...
    echo ^(this installs the WSL2 kernel and required Windows features^)
    echo.
    wsl.exe --install --no-distribution

    echo.
    echo A restart is required to finish enabling WSL.
    echo AFTER_ENABLE> "%STATE_FILE%"
    reg add "%RUNONCE_KEY%" /v "%RUNONCE_NAME%" /t REG_SZ /d "\"%SCRIPT_PATH%\"" /f >nul

    choice /M "Restart now to continue setup automatically"
    if errorlevel 2 (
        echo.
        echo OK - please restart your PC yourself when ready.
        echo This script will continue automatically the next time you log in.
        pause
        exit /b
    ) else (
        echo Restarting in 5 seconds...
        shutdown /r /t 5
        exit /b
    )
) else (
    echo WSL is already enabled on this machine. No admin/restart needed.
    echo.
)

rem ==========================================================
rem  Step 3: choose and install a Linux distro
rem ==========================================================
:DISTROMENU
if exist "%STATE_FILE%" del "%STATE_FILE%" >nul 2>&1
reg delete "%RUNONCE_KEY%" /v "%RUNONCE_NAME%" /f >nul 2>&1

set "DISTRO1=Ubuntu"
set "DISTRO2=Ubuntu-26.04"
set "DISTRO3=Ubuntu-24.04"
set "DISTRO4=Ubuntu-22.04"
set "DISTRO5=openSUSE-Tumbleweed"
set "DISTRO6=openSUSE-Leap-16.0"
set "DISTRO7=SUSE-Linux-Enterprise-15-SP7"
set "DISTRO8=SUSE-Linux-Enterprise-16.0"
set "DISTRO9=kali-linux"
set "DISTRO10=Debian"
set "DISTRO11=AlmaLinux-8"
set "DISTRO12=AlmaLinux-9"
set "DISTRO13=AlmaLinux-Kitten-10"
set "DISTRO14=AlmaLinux-10"
set "DISTRO15=archlinux"
set "DISTRO16=FedoraLinux-44"
set "DISTRO17=FedoraLinux-43"
set "DISTRO18=eLxr"
set "DISTRO19=OracleLinux_7_9"
set "DISTRO20=OracleLinux_8_10"
set "DISTRO21=OracleLinux_9_5"
set "DISTRO22=SUSE-Linux-Enterprise-15-SP6"
set "DISTROCOUNT=22"

echo Step 3: Choose a Linux distro to install
echo ================================================
for /l %%i in (1,1,%DISTROCOUNT%) do (
    echo %%i. !DISTRO%%i!
)
echo.

:ASKDISTRO
set "CHOICE="
set /p "CHOICE=Enter the number of the distro you want: "

echo %CHOICE%| findstr /r "^[1-9][0-9]*$" >nul
if errorlevel 1 (
    echo Invalid input, please enter a number.
    goto ASKDISTRO
)
if %CHOICE% GTR %DISTROCOUNT% (
    echo Number out of range, try again.
    goto ASKDISTRO
)

call set "SELECTED=%%DISTRO%CHOICE%%%"
echo.
echo You chose: %SELECTED%
echo Installing...
echo.

wsl.exe --install -d %SELECTED%

echo.
echo ================================================
echo   Almost done!
echo ================================================
echo %SELECTED% will now open in its own window to finish setup.
echo When it asks you to create a UNIX username and password, use:
echo.
echo   Username: %USERNAME%
echo   Password: %PASSWORD%
echo.
echo (these are the same ones you entered at the start, saved in "%CRED_FILE%")
echo.
pause
