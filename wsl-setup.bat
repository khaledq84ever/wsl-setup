@echo off
setlocal EnableDelayedExpansion
title WSL Setup

REM =====================================================================
REM  wsl-setup.bat
REM  Simple 2-option WSL installer with fully automatic user creation
REM =====================================================================

REM --- Self-elevate to Administrator ---
net session >nul 2>&1
if not "%errorlevel%"=="0" (
    echo This tool needs Administrator rights. Requesting elevation...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

REM --- Check Windows version supports WSL (needs Win10 build 19041+ or Win11) ---
for /f "usebackq delims=" %%b in (`powershell -NoProfile -Command "[System.Environment]::OSVersion.Version.Build"`) do set "winBuild=%%b"
if !winBuild! LSS 19041 (
    cls
    echo =========================================================
    echo   [ERROR] Windows build !winBuild! is too old for WSL.
    echo =========================================================
    echo.
    echo   WSL needs Windows 10 build 19041 or higher, or Windows 11.
    echo   Update Windows first, then run this tool again. See:
    echo   https://learn.microsoft.com/windows/wsl/install-manual
    echo.
    pause
    exit /b
)

:MENU
cls
echo =========================================================
echo                 WSL AUTO SETUP
echo =========================================================
echo.
echo   First time installing WSL on this PC? A restart may be
echo   needed partway through - if this tool stops and says so,
echo   just restart and run it again; it will continue safely.
echo.
echo   1.  Ubuntu   (Ubuntu, latest LTS - full-featured, larger)
echo   2.  Debian   (Debian GNU/Linux - small and lightweight)
echo   3.  Wine     (install Wine into a distro you already have)
echo   0.  Exit
echo.

set "choice="
set /p choice="Choose an option: "

if "%choice%"=="0" goto END
if "%choice%"=="1" (
    set "selectedName=Ubuntu"
    set "selectedFriendly=Ubuntu (latest LTS)"
    goto GOTCHOICE
)
if "%choice%"=="2" (
    set "selectedName=Debian"
    set "selectedFriendly=Debian GNU/Linux"
    goto GOTCHOICE
)
if "%choice%"=="3" goto WINEMENU

echo.
echo [ERROR] "%choice%" is not a valid option.
echo.
pause
goto MENU

:GOTCHOICE
echo.
echo =========================================================
echo   Selected: !selectedFriendly!   [wsl.exe --install -d !selectedName!]
echo =========================================================
echo.
echo   Set up the Linux account now - it will be created
echo   automatically, no need to type anything during install.
echo.

set "wslUser="
set /p wslUser="  New Linux username: "
if "!wslUser!"=="" (
    echo [ERROR] Username cannot be empty.
    pause
    goto MENU
)
if /i "!wslUser!"=="root" (
    echo [ERROR] "root" already exists in every distro - pick a different,
    echo         new username so a real account actually gets created.
    pause
    goto MENU
)

for /f "usebackq delims=" %%p in (`powershell -NoProfile -Command "$s = Read-Host -AsSecureString '  New Linux password'; $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($s); [Runtime.InteropServices.Marshal]::PtrToStringAuto($b)"`) do set "wslPass=%%p"

if "!wslPass!"=="" (
    echo [ERROR] Password cannot be empty.
    pause
    goto MENU
)

echo.
echo Checking whether !selectedFriendly! is already installed ...
set "listfile3=%TEMP%\wsl_precheck_list.txt"
powershell -NoProfile -Command "(wsl.exe -l -q) | Out-File -FilePath '%listfile3%' -Encoding ascii" >nul 2>&1
set "alreadyInstalled=0"
if exist "%listfile3%" (
    for /f "usebackq tokens=* delims=" %%a in ("%listfile3%") do (
        if /i "%%a"=="!selectedName!" set "alreadyInstalled=1"
    )
)

if "!alreadyInstalled!"=="1" (
    echo !selectedFriendly! is already installed - skipping install,
    echo continuing straight to account setup.
) else (
    echo Installing !selectedFriendly! ...
    echo ^(--web-download is used to avoid a known WSL bug where install
    echo   can hang at 0.0%% - see Microsoft's WSL install docs^)
    wsl.exe --install -d "!selectedName!" --no-launch --web-download
    if not "!errorlevel!"=="0" (
        echo [ERROR] wsl.exe --install failed for "!selectedName!".
        echo         If this is the very first WSL install on this PC, Windows
        echo         may need a restart to finish enabling WSL. Restart, then
        echo         run this tool again.
        set "wslPass="
        pause
        goto MENU
    )
)

echo.
echo Waiting for !selectedFriendly! to finish initializing ...
echo ^(a first-ever WSL launch on this PC can take several minutes -
echo   it is extracting and booting the distro for the first time^)

set "waitScript=%TEMP%\wsl_wait_progress.ps1"
(
    echo param^([string]$DistroName^)
    echo $rebootKeys = @^(
    echo     'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
    echo     'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\PendingFileRenameOperations'
    echo ^)
    echo for ^($i = 0; $i -lt 60; $i++^) {
    echo     $elapsed = $i * 5
    echo     $pct = [Math]::Min^(100, [Math]::Round^($elapsed / 300 * 100^)^)
    echo     Write-Progress -Activity "Waiting for $DistroName to finish initializing" -Status "$elapsed sec / 300 sec (first-time boot can take a while)" -PercentComplete $pct
    echo     ^& wsl.exe -d $DistroName -u root -- true 2^>$null
    echo     if ^($LASTEXITCODE -eq 0^) { Write-Progress -Activity done -Completed; exit 0 }
    echo     foreach ^($k in $rebootKeys^) {
    echo         if ^(Test-Path $k^) { Write-Progress -Activity done -Completed; exit 2 }
    echo     }
    echo     Start-Sleep -Seconds 5
    echo }
    echo Write-Progress -Activity done -Completed
    echo exit 1
) > "!waitScript!"

powershell -NoProfile -ExecutionPolicy Bypass -File "!waitScript!" -DistroName "!selectedName!"
set "waitResult=!errorlevel!"

if "!waitResult!"=="0" goto READY

if "!waitResult!"=="2" (
    echo [ERROR] Windows needs a restart to finish enabling WSL.
    echo         A pending-restart flag was detected - !selectedFriendly! cannot
    echo         finish starting until you reboot. Restart your PC, then run
    echo         this tool again and pick the same option - it will pick up
    echo         where it left off.
    set "wslPass="
    pause
    goto MENU
)

echo [ERROR] !selectedFriendly! did not become ready after 5 minutes.
echo         Try launching it manually first: wsl -d !selectedName!
echo         If that also hangs, Windows may need a restart to finish
echo         enabling WSL. Restart your PC, then run this tool again
echo         and pick the same option - it will pick up where it left off.
set "wslPass="
pause
goto MENU

:READY
echo Creating user "!wslUser!" automatically ...
echo Granting passwordless sudo so system commands run without a prompt ...
wsl.exe -d "!selectedName!" -u root -- bash -c "id -u '!wslUser!' >/dev/null 2>&1 || useradd -m -s /bin/bash '!wslUser!'; echo '!wslUser!:!wslPass!' | chpasswd; usermod -aG sudo '!wslUser!' 2>/dev/null; printf '%s ALL=(ALL) NOPASSWD:ALL\n' '!wslUser!' > /etc/sudoers.d/'!wslUser!'; chmod 0440 /etc/sudoers.d/'!wslUser!'; printf '[user]\ndefault=%s\n' '!wslUser!' > /etc/wsl.conf"

set "wslPass="

echo Restarting !selectedFriendly! so the new default user takes effect ...
wsl.exe --terminate "!selectedName!" >nul 2>&1

echo.
echo =========================================================
echo   Verifying registration
echo =========================================================
REM --- Right after --terminate the WSL service can briefly report
REM     WSL_E_DISTRO_NOT_FOUND even though the distro is fine - retry
REM     instead of failing on the first check.
set "verifyOk=0"
for /l %%i in (1,1,10) do (
    if "!verifyOk!"=="0" (
        wsl.exe -d "!selectedName!" -u "!wslUser!" -- id -un >nul 2>&1
        if "!errorlevel!"=="0" (
            set "verifyOk=1"
        ) else (
            timeout /t 2 >nul
        )
    )
)

if "!verifyOk!"=="1" (
    echo [OK] User "!wslUser!" is registered in !selectedFriendly!.
) else (
    echo [WARN] Could not confirm user "!wslUser!". Check manually with:
    echo        wsl -d "!selectedName!" cat /etc/passwd
    pause
    goto ASKAGAIN
)

for /f "usebackq delims=" %%w in (`wsl.exe -d "!selectedName!" -- whoami`) do set "defUser=%%w"
if /i "!defUser!"=="!wslUser!" (
    echo [OK] "!wslUser!" is set as the default user in !selectedFriendly!.
) else (
    echo [WARN] Default user may not be applied yet ^(got "!defUser!"^). Try:
    echo        wsl --terminate "!selectedName!"  then  wsl -d !selectedName!
)

echo Making !selectedFriendly! the default so plain "wsl" opens it ...
wsl.exe --set-default "!selectedName!" >nul 2>&1

for /f "usebackq delims=" %%c in (`wsl.exe -- whoami 2^>nul`) do set "cleanCheck=%%c"
if /i "!cleanCheck!"=="!wslUser!" (
    echo [OK] Typing "wsl" in any cmd/PowerShell window now logs straight
    echo      into !selectedFriendly! as "!wslUser!" - no prompts, no errors.
) else (
    echo [WARN] "wsl" did not come up clean as "!wslUser!" ^(got "!cleanCheck!"^).
    echo        Check with: wsl --status  and  wsl -l -v
)

set "wslUser="
set "wslPass="

echo Creating start-wsl.bat next to this script for quick launching ...
(
    echo @echo off
    echo title WSL
    echo wsl.exe
) > "%~dp0start-wsl.bat"

echo.
echo =========================================================
echo   Registration complete. No username/password was written
echo   to any file, log, or disk - only used in memory to create
echo   the account, then cleared. Closing in 5 seconds...
echo =========================================================
timeout /t 5 >nul
exit /b

:ASKAGAIN
echo.
set /p again="Install another distribution? (y/n): "
if /i "!again!"=="y" goto MENU
goto END

:WINEMENU
echo.
echo =========================================================
echo   Install Wine
echo =========================================================
echo.
echo   Looking for WSL distros already installed ...

set "listfile2=%TEMP%\wsl_installed_list.txt"
powershell -NoProfile -Command "(wsl.exe -l -q) | Out-File -FilePath '%listfile2%' -Encoding ascii" >nul 2>&1

set wcount=0
if exist "%listfile2%" (
    for /f "usebackq tokens=* delims=" %%a in ("%listfile2%") do (
        if not "%%a"=="" (
            set /a wcount+=1
            set "wdistro_!wcount!=%%a"
        )
    )
)

if "%wcount%"=="0" (
    echo.
    echo [ERROR] No WSL distro is installed yet. Install one first ^(option 1 or 2^).
    echo.
    pause
    goto MENU
)

if "%wcount%"=="1" (
    set "wineTarget=!wdistro_1!"
    echo   Using the only distro found: !wineTarget!
) else (
    echo.
    echo   Multiple distros found - choose one for Wine:
    for /l %%i in (1,1,%wcount%) do (
        echo   %%i.  !wdistro_%%i!
    )
    echo.
    set "wchoice="
    set /p wchoice="Enter a number: "
    set "wvalid=0"
    for /l %%i in (1,1,%wcount%) do (
        if "!wchoice!"=="%%i" set "wvalid=1"
    )
    if "!wvalid!"=="0" (
        echo [ERROR] Not a valid option.
        pause
        goto MENU
    )
    set "wineTarget=!wdistro_%wchoice%!"
)

echo.
echo Installing Wine into "!wineTarget!" - this runs directly as root,
echo so there is no sudo password prompt. Output is shown live below.
echo.

wsl.exe -d "!wineTarget!" -u root -- bash -c "dpkg --add-architecture i386 && apt-get update && apt-get install -y wine wine32 wine64 winetricks"
if not "!errorlevel!"=="0" (
    echo.
    echo [ERROR] Wine install failed inside "!wineTarget!". See the output above for details.
    pause
    goto MENU
)

echo.
echo =========================================================
echo   Verifying Wine
echo =========================================================
for /f "usebackq delims=" %%v in (`wsl.exe -d "!wineTarget!" -- wine --version 2^>nul`) do set "wineVer=%%v"
if not "!wineVer!"=="" (
    echo [OK] Wine installed: !wineVer!
) else (
    echo [WARN] Could not confirm Wine version. Try manually:
    echo        wsl -d "!wineTarget!" -- wine --version
)

echo.
echo =========================================================
echo   Done. Closing in 5 seconds...
echo =========================================================
timeout /t 5 >nul
exit /b

:END
echo.
echo =========================================================
echo   Done.
echo =========================================================
echo.
pause
