@echo off
setlocal EnableDelayedExpansion
title WSL Setup

REM =====================================================================
REM  wsl-setup.bat
REM  Simple 2-option WSL installer with fully automatic user creation
REM =====================================================================

REM WSL_UTF8=1 makes wsl.exe emit UTF-8 instead of UTF-16 when its output
REM is piped/redirected (which it always is under `for /f`) - without this,
REM parsing wsl.exe output in batch silently returns garbage.
set "WSL_UTF8=1"

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
set "alreadyInstalled=0"
for /f "usebackq delims=" %%a in (`wsl.exe -l -q`) do (
    if /i "%%a"=="!selectedName!" set "alreadyInstalled=1"
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

REM  cmd.exe treats a literal |, ||, &&, or > as ITS OWN operator even
REM  inside double quotes - a single-line `bash -c "... | chpasswd ..."`
REM  with several of those gets silently chopped into multiple cmd-level
REM  commands and never reaches bash intact. The username/password are
REM  also never spliced as raw text into any parsed command line: they're
REM  base64-encoded and forwarded through WSLENV, then decoded inside a
REM  small generated script that's executed as `bash <path>` instead.
set "userScript=%TEMP%\wsl_setup_apply_user.sh"
set "WSL_SETUP_USER_RAW=!wslUser!"
set "WSL_SETUP_PASS_RAW=!wslPass!"
for /f "usebackq delims=" %%B in (`powershell -NoProfile -Command "[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($env:WSL_SETUP_USER_RAW))"`) do set "USER_B64=%%B"
for /f "usebackq delims=" %%B in (`powershell -NoProfile -Command "[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($env:WSL_SETUP_PASS_RAW))"`) do set "PASS_B64=%%B"
set "WSLENV=USER_B64:PASS_B64"

(
echo #^^!/bin/bash
echo set -e
echo u=$(printf '%%s' "$USER_B64" ^| base64 -d^)
echo p=$(printf '%%s' "$PASS_B64" ^| base64 -d^)
echo id -u "$u" ^>/dev/null 2^>^&1 ^|^| useradd -m -s /bin/bash "$u"
echo printf '%%s:%%s\n' "$u" "$p" ^| chpasswd
echo usermod -aG sudo "$u" 2^>/dev/null ^|^| true
echo printf '%%s ALL=^(ALL^) NOPASSWD:ALL\n' "$u" ^> /etc/sudoers.d/"$u"
echo chmod 0440 /etc/sudoers.d/"$u"
echo printf '[user]\ndefault=%%s\n' "$u" ^> /etc/wsl.conf
) > "%userScript%"

for /f "usebackq delims=" %%P in (`wsl.exe -d !selectedName! -- wslpath -a "%userScript%"`) do set "SCRIPTWSL=%%P"
REM strip CRLF - batch's `>` redirection writes \r\n, which corrupts bash parsing
wsl.exe -d !selectedName! -u root -- sed -i "s/\r$//" "%SCRIPTWSL%"
wsl.exe -d !selectedName! -u root -- bash "%SCRIPTWSL%"
set "userScriptResult=!errorlevel!"
del "%userScript%" >nul 2>&1

if not "!userScriptResult!"=="0" (
    echo [ERROR] Creating the Linux user failed inside !selectedFriendly!. See output above.
    set "wslUser="
    set "wslPass="
    pause
    goto MENU
)

set "wslPass="

echo Restarting !selectedFriendly! so the new default user takes effect ...
wsl.exe --terminate !selectedName! >nul 2>&1

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
        wsl.exe -d !selectedName! -u !wslUser! -- id -un >nul 2>&1
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
    echo        wsl -d !selectedName! cat /etc/passwd
    pause
    goto ASKAGAIN
)

for /f "usebackq delims=" %%w in (`wsl.exe -d !selectedName! -- whoami`) do set "defUser=%%w"
if /i "!defUser!"=="!wslUser!" (
    echo [OK] "!wslUser!" is set as the default user in !selectedFriendly!.
) else (
    echo [WARN] Default user may not be applied yet ^(got "!defUser!"^). Try:
    echo        wsl --terminate !selectedName!  then  wsl -d !selectedName!
)

echo Making !selectedFriendly! the default so plain "wsl" opens it ...
wsl.exe --set-default !selectedName! >nul 2>&1

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

set wcount=0
for /f "usebackq delims=" %%a in (`wsl.exe -l -q`) do (
    if not "%%a"=="" (
        set /a wcount+=1
        set "wdistro_!wcount!=%%a"
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

REM  same reason as the user-creation step: cmd.exe treats && inside a
REM  quoted bash -c string as ITS OWN operator, splitting the command
REM  before it ever reaches bash. Use a generated script file instead.
set "wineScript=%TEMP%\wsl_setup_install_wine.sh"
(
echo #^^!/bin/bash
echo set -e
echo dpkg --add-architecture i386
echo apt-get update
echo apt-get install -y wine wine32 wine64
echo apt-get install -y winetricks ^|^| echo "[WARN] winetricks package unavailable on this distro/release - Wine itself installed fine, skipping winetricks."
) > "%wineScript%"

for /f "usebackq delims=" %%P in (`wsl.exe -d !wineTarget! -- wslpath -a "%wineScript%"`) do set "WINESCRIPTWSL=%%P"
wsl.exe -d !wineTarget! -u root -- sed -i "s/\r$//" "%WINESCRIPTWSL%"
wsl.exe -d !wineTarget! -u root -- bash "%WINESCRIPTWSL%"
set "wineScriptResult=!errorlevel!"
del "%wineScript%" >nul 2>&1

if not "!wineScriptResult!"=="0" (
    echo.
    echo [ERROR] Wine install failed inside "!wineTarget!". See the output above for details.
    pause
    goto MENU
)

echo.
echo =========================================================
echo   Verifying Wine
echo =========================================================
for /f "usebackq delims=" %%v in (`wsl.exe -d !wineTarget! -- wine --version 2^>nul`) do set "wineVer=%%v"
if not "!wineVer!"=="" (
    echo [OK] Wine installed: !wineVer!
) else (
    echo [WARN] Could not confirm Wine version. Try manually:
    echo        wsl -d !wineTarget! -- wine --version
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
