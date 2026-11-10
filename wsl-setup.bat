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

REM  Remember any WSLENV the user already had, so the credential forwarding
REM  below can be added on top of it and then removed again cleanly.
set "origWSLENV=%WSLENV%"

REM --- ANSI colors (modern Windows Terminal / conhost both support this
REM     natively - no registry tweak needed on Win10 1909+/Win11). Falls
REM     back to harmless raw escape-looking text on truly ancient consoles.
for /f %%E in ('echo prompt $E^|cmd') do set "ESC=%%E"
set "CLR_RESET=%ESC%[0m"
set "CLR_CYAN=%ESC%[96m"
set "CLR_GREEN=%ESC%[92m"
set "CLR_YELLOW=%ESC%[93m"
set "CLR_RED=%ESC%[91m"
set "CLR_BOLD=%ESC%[1m"

REM --- Self-elevate to Administrator ---
REM  fltmc only succeeds elevated and, unlike `net session`, does not depend on
REM  the Server service - with that service stopped, `net session` always
REM  fails and the script would re-launch itself elevated forever.
REM  The script path goes to PowerShell via an env var, not spliced into the
REM  command string, so a folder name containing an apostrophe still works.
fltmc >nul 2>&1
if not "%errorlevel%"=="0" (
    echo This tool needs Administrator rights. Requesting elevation...
    set "WSL_SETUP_SELF=%~f0"
    powershell -NoProfile -Command "try { Start-Process -FilePath $env:WSL_SETUP_SELF -Verb RunAs -ErrorAction Stop } catch { exit 1 }"
    if errorlevel 1 (
        echo.
        echo %CLR_RED%[ERROR]%CLR_RESET% Administrator rights were not granted - nothing was changed.
        echo         Re-run it and click "Yes" on the UAC prompt, or right-click
        echo         wsl-setup.bat and choose "Run as administrator".
        echo.
        pause
    )
    exit /b
)

REM --- Check Windows version supports WSL (needs Win10 build 19041+ or Win11) ---
for /f "usebackq delims=" %%b in (`powershell -NoProfile -Command "[System.Environment]::OSVersion.Version.Build"`) do set "winBuild=%%b"
REM  If PowerShell returned nothing, skip the check rather than crash on a
REM  malformed `if  LSS 19041` - wsl.exe will report a too-old build itself.
if not defined winBuild set "winBuild=99999"
if !winBuild! LSS 19041 (
    cls
    echo %CLR_CYAN%=========================================================%CLR_RESET%
    echo   %CLR_RED%[ERROR]%CLR_RESET% Windows build !winBuild! is too old for WSL.
    echo %CLR_CYAN%=========================================================%CLR_RESET%
    echo.
    echo   WSL needs Windows 10 build 19041 or higher, or Windows 11.
    echo   Update Windows first, then run this tool again. See:
    echo   https://learn.microsoft.com/windows/wsl/install-manual
    echo.
    pause
    exit /b
)

:MENU
REM  The distro list only needs fetching once per run - error paths and
REM  "install another" come back here, and wsl.exe --list --online is slow.
if defined DISTROCOUNT goto SHOWMENU
cls
echo %CLR_CYAN%=========================================================%CLR_RESET%
echo                 %CLR_BOLD%%CLR_CYAN%WSL AUTO SETUP%CLR_RESET%
echo %CLR_CYAN%=========================================================%CLR_RESET%
echo.
echo   First time installing WSL on this PC? A restart may be
echo   needed partway through - if this tool stops and says so,
echo   just restart and run it again; it will continue safely.
echo.
echo   Fetching the list of available distros ...

REM  Parsing happens in list-distros.ps1, not here: wsl.exe prints UTF-16 when
REM  piped unless it is new enough to honour WSL_UTF8, and cmd cannot read
REM  UTF-16, so on older builds the list always came back empty. The script
REM  decodes the raw bytes, copes with any intro length or language, and
REM  prints NAME^|FRIENDLY lines. If it finds nothing, it shows what wsl.exe
REM  said on stderr, which for /f does not capture.
set "DISTROCOUNT=0"
if not exist "%~dp0list-distros.ps1" (
    echo.
    echo %CLR_YELLOW%[WARN]%CLR_RESET% list-distros.ps1 is missing next to this script.
    goto DISTROFALLBACK
)
for /f "usebackq tokens=1,* delims=|" %%D in (`powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0list-distros.ps1"`) do (
    set /a DISTROCOUNT+=1
    set "DISTRONAME_!DISTROCOUNT!=%%D"
    set "DISTROFRIENDLY_!DISTROCOUNT!=%%E"
)

:DISTROFALLBACK
REM  The live list can legitimately fail (no internet/DNS, or wsl.exe not
REM  fully initialized yet on a brand-new machine - exactly when this tool
REM  is most likely to be run). Rather than dying here, fall back to a
REM  known-good fixed menu so the tool always reaches a working install
REM  path. The pause matters: the menu below starts with cls, which would
REM  otherwise wipe this warning and wsl.exe's own error before anyone
REM  could read them.
if "!DISTROCOUNT!"=="0" (
    echo.
    echo %CLR_YELLOW%[WARN]%CLR_RESET% Could not read the live distro list from 'wsl.exe --list --online'.
    echo         Falling back to a fixed menu - this doesn't need the
    echo         online list and works even with no network access yet.
    echo.
    set "DISTRONAME_1=Ubuntu"
    set "DISTROFRIENDLY_1=Ubuntu - latest LTS"
    set "DISTRONAME_2=Debian"
    set "DISTROFRIENDLY_2=Debian"
    set "DISTROCOUNT=2"
    pause
)

:SHOWMENU
cls
echo %CLR_CYAN%=========================================================%CLR_RESET%
echo                 %CLR_BOLD%%CLR_CYAN%WSL AUTO SETUP%CLR_RESET%
echo %CLR_CYAN%=========================================================%CLR_RESET%
echo.
echo   Choose a distro to install:
echo.
for /l %%i in (1,1,!DISTROCOUNT!) do (
    echo   %%i.  !DISTROFRIENDLY_%%i!
)
echo   0.  Exit
echo.

set "choice="
set /p choice="Choose an option: "

if "!choice!"=="0" goto END

REM  Validated without percent-expanding the choice into a parsed line: a typed
REM  "1&something" would otherwise run as a command in this elevated window.
set "CHK_VAL=!choice!"
set "CHK_RE=^[1-9][0-9]{0,3}$"
call :MATCHRE
if errorlevel 1 goto BADCHOICE
REM  Digits only from here on. A number past the end of the list simply has no
REM  DISTRONAME_n, which also covers the old GTR check, including numbers
REM  too big for cmd's 32-bit compare.
if not defined DISTRONAME_!choice! goto BADCHOICE
set "selectedName=!DISTRONAME_%choice%!"
set "selectedFriendly=!DISTROFRIENDLY_%choice%!"
goto GOTCHOICE

:BADCHOICE
echo.
echo %CLR_RED%[ERROR]%CLR_RESET% "!choice!" is not a valid option.
echo.
pause
goto MENU

:GOTCHOICE
echo.
echo %CLR_CYAN%=========================================================%CLR_RESET%
echo   Selected: !selectedFriendly!   [wsl.exe --install -d !selectedName!]
echo %CLR_CYAN%=========================================================%CLR_RESET%
echo.
echo   Set up the Linux account now - it will be created
echo   automatically, no need to type anything during install.
echo.

:ASKUSER
set "wslUser="
set /p wslUser="  New Linux username: "
if "!wslUser!"=="" (
    echo %CLR_RED%[ERROR]%CLR_RESET% Username cannot be empty.
    goto ASKUSER
)
if /i "!wslUser!"=="root" (
    echo %CLR_RED%[ERROR]%CLR_RESET% "root" already exists in every distro - pick a different,
    echo         new username so a real account actually gets created.
    goto ASKUSER
)

REM  Validate the username against Linux useradd rules BEFORE installing a whole
REM  distro, so an invalid name fails fast here with a clear message instead of
REM  blowing up cryptically mid-setup when `useradd` rejects it. Rules: start
REM  with a lowercase letter or underscore, then lowercase letters/digits/hyphen/
REM  underscore, max 32 chars. The check runs in PowerShell on an env var
REM  (see :MATCHRE) - not `echo ... | findstr`: findstr's [a-z] also matches
REM  most UPPERCASE letters, and the left side of a cmd pipe runs with delayed
REM  expansion off, so the value may not even reach findstr intact.
set "CHK_VAL=!wslUser!"
set "CHK_RE=^[a-z_][a-z0-9_-]*$"
call :MATCHRE
if errorlevel 1 (
    echo %CLR_RED%[ERROR]%CLR_RESET% "!wslUser!" is not a valid Linux username.
    echo         Use only lowercase letters, digits, hyphen and underscore, and
    echo         start with a lowercase letter or underscore ^(e.g. "dev", "my_user"^).
    goto ASKUSER
)
if not "!wslUser:~32!"=="" (
    echo %CLR_RED%[ERROR]%CLR_RESET% Username is too long - Linux usernames are max 32 characters.
    goto ASKUSER
)

REM  The password is read, confirmed and base64-encoded entirely inside
REM  PowerShell - only the base64 text ever comes back into this script.
REM  Passing the raw password through `set` would corrupt it: with delayed
REM  expansion on, cmd silently strips every "!" (and carets next to it), so
REM  a password like "Pass!word" would end up as something the user never
REM  typed. Base64 has no cmd-special characters. "ERR:" can never be valid
REM  base64 output, so it is safe to use as an error marker.
:ASKPASS
set "PASS_B64="
for /f "usebackq delims=" %%p in (`powershell -NoProfile -Command "$a = Read-Host -AsSecureString '  New Linux password'; $b = Read-Host -AsSecureString '  Confirm password'; $p1 = [Net.NetworkCredential]::new('', $a).Password; $p2 = [Net.NetworkCredential]::new('', $b).Password; if ($p1.Length -eq 0) { 'ERR:EMPTY' } elseif ($p1 -cne $p2) { 'ERR:MISMATCH' } else { [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($p1)) }"`) do set "PASS_B64=%%p"

if "!PASS_B64!"=="ERR:EMPTY" (
    echo %CLR_RED%[ERROR]%CLR_RESET% Password cannot be empty.
    goto ASKPASS
)
if "!PASS_B64!"=="ERR:MISMATCH" (
    echo %CLR_RED%[ERROR]%CLR_RESET% The passwords did not match - try again.
    goto ASKPASS
)
if "!PASS_B64!"=="" (
    echo %CLR_RED%[ERROR]%CLR_RESET% Could not read the password via PowerShell.
    pause
    goto MENU
)

echo.
echo Checking whether !selectedFriendly! is already installed ...
REM  Ask the registry instead of parsing `wsl.exe -l -q`: older wsl.exe builds
REM  ignore WSL_UTF8 and print UTF-16, which `for /f` reads as garbage, so the
REM  check silently said "not installed" and a re-run then died trying to
REM  install a distro that already exists. Every registered distro has a
REM  DistributionName value under this key; the lookup is case-insensitive.
set "alreadyInstalled=0"
powershell -NoProfile -Command "$n = '!selectedName!'; $hit = Get-ChildItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss' -ErrorAction SilentlyContinue | Where-Object { $_.GetValue('DistributionName') -eq $n }; if ($hit) { exit 0 } else { exit 1 }"
if "!errorlevel!"=="0" set "alreadyInstalled=1"

if "!alreadyInstalled!"=="1" (
    echo !selectedFriendly! is already installed - skipping install,
    echo continuing straight to account setup.
) else (
    echo Installing !selectedFriendly! ...
    echo ^(--web-download is used to avoid a known WSL bug where install
    echo   can hang at 0.0%% - see Microsoft's WSL install docs^)

    set "installLog=%TEMP%\wsl_setup_install.log"
    set "installErrLog=%TEMP%\wsl_setup_install_err.log"
    set "installScript=%TEMP%\wsl_setup_install_progress.ps1"
    if exist "!installLog!" del "!installLog!" >nul 2>&1
    if exist "!installErrLog!" del "!installErrLog!" >nul 2>&1
    (
    echo $proc = Start-Process -FilePath 'wsl.exe' -ArgumentList '--install','-d','!selectedName!','--no-launch','--web-download' -RedirectStandardOutput '!installLog!' -RedirectStandardError '!installErrLog!' -PassThru -NoNewWindow
    echo $spinner = @^('^|','/','-','\'^)
    echo $i = 0
    echo while ^(-not $proc.HasExited^) {
    echo     $elapsed = [Math]::Round^(^(^(Get-Date^) - $proc.StartTime^).TotalSeconds^)
    echo     $pct = -1
    echo     if ^(Test-Path '!installLog!'^) {
    echo         $lastLine = Get-Content '!installLog!' -Tail 5 -ErrorAction SilentlyContinue ^| Where-Object { $_ -match '[\d.]+%%' } ^| Select-Object -Last 1
    echo         if ^($lastLine -match '[\d.]+%%'^) { $pct = [Math]::Min^(100, [double]^($Matches[0].TrimEnd^('%%'^)^)^) }
    echo     }
    echo     if ^($pct -ge 0^) {
    echo         Write-Progress -Activity "Downloading !selectedFriendly!" -Status "$pct%% - ${elapsed}s elapsed" -PercentComplete $pct
    echo     } else {
    echo         Write-Progress -Activity "Downloading !selectedFriendly!" -Status "$^($spinner[$i %% 4]^)  ${elapsed}s elapsed ^(waiting for progress data^)" -PercentComplete -1
    echo     }
    echo     $i++
    echo     Start-Sleep -Milliseconds 300
    echo }
    echo Write-Progress -Activity done -Completed
    echo exit $proc.ExitCode
    ) > "!installScript!"
    powershell -NoProfile -ExecutionPolicy Bypass -File "!installScript!"
    set "installResult=!errorlevel!"
    del "!installScript!" >nul 2>&1

    if not "!installResult!"=="0" (
        echo %CLR_RED%[ERROR]%CLR_RESET% wsl.exe --install failed for "!selectedName!".
        echo         If this is the very first WSL install on this PC, Windows
        echo         may need a restart to finish enabling WSL. Restart, then
        echo         run this tool again. Details:
        type "!installLog!" 2>nul
        type "!installErrLog!" 2>nul
        del "!installLog!" "!installErrLog!" >nul 2>&1
        call :CLEARCREDS
        pause
        goto MENU
    )
    del "!installLog!" "!installErrLog!" >nul 2>&1
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
    echo %CLR_RED%[ERROR]%CLR_RESET% Windows needs a restart to finish enabling WSL.
    echo         A pending-restart flag was detected - !selectedFriendly! cannot
    echo         finish starting until you reboot. Restart your PC, then run
    echo         this tool again and pick the same option - it will pick up
    echo         where it left off.
    call :CLEARCREDS
    pause
    goto MENU
)

echo %CLR_RED%[ERROR]%CLR_RESET% !selectedFriendly! did not become ready after 5 minutes.
echo         Try launching it manually first: wsl -d !selectedName!
echo         If that also hangs, Windows may need a restart to finish
echo         enabling WSL. Restart your PC, then run this tool again
echo         and pick the same option - it will pick up where it left off.
call :CLEARCREDS
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
REM  base64-encoded and forwarded through WSLENV, then decoded inside the
REM  shipped setup-user.sh, which is executed as `bash <path>` instead.
if not exist "%~dp0setup-user.sh" (
    echo %CLR_RED%[ERROR]%CLR_RESET% setup-user.sh is missing next to this script.
    echo         Download the whole repo, not just wsl-setup.bat, then re-run.
    call :CLEARCREDS
    pause
    goto MENU
)

set "WSL_SETUP_USER_RAW=!wslUser!"
set "USER_B64="
for /f "usebackq delims=" %%B in (`powershell -NoProfile -Command "[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($env:WSL_SETUP_USER_RAW))"`) do set "USER_B64=%%B"
set "WSL_SETUP_USER_RAW="
if defined origWSLENV (
    set "WSLENV=USER_B64:PASS_B64:!origWSLENV!"
) else (
    set "WSLENV=USER_B64:PASS_B64"
)

REM  Copy the shipped setup-user.sh into the distro, strip any CR (a CRLF
REM  checkout on Windows would otherwise break bash parsing), and run it as
REM  root. It reads USER_B64/PASS_B64 from the environment, forwarded above via
REM  WSLENV. Running `bash <path>` with no shell metacharacters on the command
REM  line avoids cmd.exe mangling a pipe, redirect, or && even inside quotes.
REM  Every value captured with `for /f` below is cleared first: when nothing
REM  comes back, `for /f` leaves the variable untouched, and on a second
REM  "install another" round a stale value from the first distro would be
REM  silently reused - e.g. reporting [OK] for a user check that failed.
set "SCRIPTWSL="
for /f "usebackq delims=" %%P in (`wsl.exe -d !selectedName! -- wslpath -a "%~dp0setup-user.sh"`) do set "SCRIPTWSL=%%P"
if not defined SCRIPTWSL (
    echo %CLR_RED%[ERROR]%CLR_RESET% Could not map setup-user.sh into !selectedFriendly! with wslpath.
    echo         This happens when the repo is on a drive WSL cannot see, such
    echo         as some network shares. Copy the folder to C:\ and re-run.
    call :CLEARCREDS
    pause
    goto MENU
)
wsl.exe -d !selectedName! -u root -- cp "!SCRIPTWSL!" /tmp/wsl_setup_user.sh
wsl.exe -d !selectedName! -u root -- sed -i "s/\r$//" /tmp/wsl_setup_user.sh
wsl.exe -d !selectedName! -u root -- bash /tmp/wsl_setup_user.sh
set "userScriptResult=!errorlevel!"
wsl.exe -d !selectedName! -u root -- rm -f /tmp/wsl_setup_user.sh >nul 2>&1

REM  Stop forwarding the credentials NOW. Otherwise every later wsl.exe call in
REM  this window - including setup-dev-tools.sh, which pipes installers from
REM  the internet into a shell - would still receive PASS_B64 in its env.
call :CLEARCREDS

if not "!userScriptResult!"=="0" (
    echo %CLR_RED%[ERROR]%CLR_RESET% Creating the Linux user failed inside !selectedFriendly!. See output above.
    set "wslUser="
    pause
    goto MENU
)

echo Restarting !selectedFriendly! so the new default user takes effect ...
wsl.exe --terminate !selectedName! >nul 2>&1

echo.
echo %CLR_CYAN%=========================================================%CLR_RESET%
echo   Verifying registration
echo %CLR_CYAN%=========================================================%CLR_RESET%
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
    echo %CLR_GREEN%[OK]%CLR_RESET% User "!wslUser!" is registered in !selectedFriendly!.
) else (
    echo %CLR_YELLOW%[WARN]%CLR_RESET% Could not confirm user "!wslUser!". Check manually with:
    echo        wsl -d !selectedName! cat /etc/passwd
    pause
    goto ASKAGAIN
)

set "defUser="
for /f "usebackq delims=" %%w in (`wsl.exe -d !selectedName! -- whoami 2^>nul`) do set "defUser=%%w"
if /i "!defUser!"=="!wslUser!" (
    echo %CLR_GREEN%[OK]%CLR_RESET% "!wslUser!" is set as the default user in !selectedFriendly!.
) else (
    echo %CLR_YELLOW%[WARN]%CLR_RESET% Default user may not be applied yet ^(got "!defUser!"^). Try:
    echo        wsl --terminate !selectedName!  then  wsl -d !selectedName!
)

echo Making !selectedFriendly! the default so plain "wsl" opens it ...
wsl.exe --set-default !selectedName! >nul 2>&1

set "cleanCheck="
for /f "usebackq delims=" %%c in (`wsl.exe -- whoami 2^>nul`) do set "cleanCheck=%%c"
if /i "!cleanCheck!"=="!wslUser!" (
    echo %CLR_GREEN%[OK]%CLR_RESET% Typing "wsl" in any cmd/PowerShell window now logs straight
    echo      into !selectedFriendly! as "!wslUser!" - no prompts, no errors.
) else (
    echo %CLR_YELLOW%[WARN]%CLR_RESET% "wsl" did not come up clean as "!wslUser!" ^(got "!cleanCheck!"^).
    echo        Check with: wsl --status  and  wsl -l -v
)

set "wslUser="

echo Creating start-wsl.bat next to this script for quick launching ...
(
    echo @echo off
    echo title WSL
    echo wsl.exe
) > "%~dp0start-wsl.bat"

echo.
echo %CLR_GREEN%=========================================================%CLR_RESET%
echo   Registration complete. No username/password was written
echo   to any file, log, or disk - only used in memory to create
echo   the account, then cleared.
echo %CLR_GREEN%=========================================================%CLR_RESET%
echo.
pause

REM --- Optional: run setup-dev-tools.sh inside the new distro ---
REM  Offered here (not chained automatically) so the core WSL setup stays fast
REM  and self-contained; dev tools are a separate, slower, network-heavy step.
REM  Runs as the distro's default user (the account just created) - no -u needed,
REM  and the NOPASSWD sudo granted above lets its apt/docker steps run unattended.
if exist "%~dp0setup-dev-tools.sh" (
    echo.
    set "devChoice="
    set /p devChoice="Install dev tools now inside !selectedFriendly! - Node, Docker, GitHub CLI? [y/n]: "
    if /i "!devChoice!"=="y" (
        echo.
        echo Running setup-dev-tools.sh inside !selectedFriendly! ...
        REM  Resolve the Windows path to a WSL path, copy it in, strip CR - the file
        REM  may be checked out with CRLF on Windows - then run it as 'bash path'
        REM  with no shell metacharacters on the command line, which cmd.exe would
        REM  otherwise mangle even inside quotes. Note: no parens in these in-block
        REM  comments on purpose - cmd counts them against the enclosing block.
        set "DEVSCRIPTWSL="
        for /f "usebackq delims=" %%S in (`wsl.exe -d !selectedName! -- wslpath -a "%~dp0setup-dev-tools.sh"`) do set "DEVSCRIPTWSL=%%S"
        wsl.exe -d !selectedName! -- cp "!DEVSCRIPTWSL!" /tmp/wsl_setup_devtools.sh
        wsl.exe -d !selectedName! -u root -- sed -i "s/\r$//" /tmp/wsl_setup_devtools.sh
        wsl.exe -d !selectedName! -- bash /tmp/wsl_setup_devtools.sh
        set "devResult=!errorlevel!"
        wsl.exe -d !selectedName! -- rm -f /tmp/wsl_setup_devtools.sh >nul 2>&1
        if not "!devResult!"=="0" (
            echo %CLR_YELLOW%[WARN]%CLR_RESET% Dev-tools setup reported an error above. You can re-run it
            echo        anytime inside WSL with: bash setup-dev-tools.sh
        ) else (
            echo %CLR_GREEN%[OK]%CLR_RESET% Dev-tools setup finished.
        )
        echo.
        pause
    )
)

:ASKAGAIN
echo.
set "again="
set /p again="Install another distribution? (y/n): "
if /i "!again!"=="y" goto MENU
goto END

:END
echo.
echo %CLR_CYAN%=========================================================%CLR_RESET%
echo   Done.
echo %CLR_CYAN%=========================================================%CLR_RESET%
echo.
pause
exit /b

REM --- Drop the base64 credentials and restore the caller's WSLENV ---
:CLEARCREDS
set "PASS_B64="
set "USER_B64="
set "WSLENV=!origWSLENV!"
exit /b

REM --- Case-sensitive regex check: exit 0 if env CHK_VAL matches CHK_RE ---
REM  Both are passed as environment variables, so the value is never parsed
REM  by cmd and may safely contain & | ^ ! %% or quotes.
:MATCHRE
powershell -NoProfile -Command "if ($env:CHK_VAL -cmatch $env:CHK_RE) { exit 0 } else { exit 1 }"
exit /b %errorlevel%
