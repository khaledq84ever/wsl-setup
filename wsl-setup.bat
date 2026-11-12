@echo off
REM  This script's own folder and path are read while delayed expansion is
REM  still off: with it on, cmd drops every "!" from %~dp0 and %~f0, and a
REM  folder named e.g. "New!" could not be found again. From here on they are
REM  only used as !SELF_DIR! and !SELF_PATH!, which keeps the value intact.
setlocal DisableDelayedExpansion
set "SELF_DIR=%~dp0"
set "SELF_PATH=%~f0"
setlocal EnableDelayedExpansion
title WSL Setup

REM =====================================================================
REM  wsl-setup.bat
REM  WSL installer: pick a distro from a live list, the Linux account is
REM  created automatically; can also open the distro that is installed.
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
    set "WSL_SETUP_SELF=!SELF_PATH!"
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

REM --- Work from this script's own folder (an elevated window starts in
REM     System32). wsl.exe starts each Linux command in the current Windows
REM     folder, so the shipped .sh files can be copied into the distro by
REM     their plain name. That needs no wslpath call - and no Linux path
REM     coming back through `for /f`, which would lose a "!" in it.
cd /d "!SELF_DIR!"

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

REM --- The helper files must sit next to this script. Check them all up
REM     front, so a partial download fails here with a clear list instead of
REM     halfway through an install.
set "missing="
for %%F in (setup-user.sh list-distros.ps1 install-distro.ps1 wait-distro.ps1 wsl-status.ps1 start.bat) do (
    if not exist "!SELF_DIR!%%F" set "missing=!missing! %%F"
)
if defined missing (
    echo %CLR_RED%[ERROR]%CLR_RESET% These files are missing next to wsl-setup.bat:!missing!
    echo         Download the whole repo - not just the .bat - and run it again.
    echo.
    pause
    exit /b 1
)

REM --- Is WSL itself installed? (separate from any distro) ---
REM  A failed install attempt comes back here rather than to :MENU: it may
REM  have changed WSL's own state (just turned on, restart pending), and the
REM  line at the top of the menu should say so instead of what was true
REM  when the tool started.
:MENUFRESH
call :WSLSTATUS

REM --- Main menu: install a distro, or open the one already installed ---
:MENU
cls
echo %CLR_CYAN%=========================================================%CLR_RESET%
echo                 %CLR_BOLD%%CLR_CYAN%WSL AUTO SETUP%CLR_RESET%
echo %CLR_CYAN%=========================================================%CLR_RESET%
echo.
if "!WSLSTATE!"=="OK" echo   %CLR_GREEN%[OK]%CLR_RESET% !WSLSTATUS!
if "!WSLSTATE!"=="INFO" echo   %CLR_YELLOW%[INFO]%CLR_RESET% !WSLSTATUS!
echo.
echo   1.  Install a Linux distro
echo   2.  Start WSL - open the distro you already installed
echo   0.  Exit
echo.
echo   First time installing WSL on this PC? A restart may be
echo   needed partway through - if this tool stops and says so,
echo   just restart and run it again; it will continue safely.
echo.

REM  Compared with delayed expansion only, never percent-expanded into a
REM  parsed line: a typed "1&something" must not run as a command in this
REM  elevated window.
set "choice="
set /p choice="Choose an option: "
if "!choice!"=="0" goto END
if "!choice!"=="1" goto DISTROMENU
if "!choice!"=="2" goto STARTWSL
echo.
echo %CLR_RED%[ERROR]%CLR_RESET% "!choice!" is not a valid option.
echo.
pause
goto MENU

REM --- Menu entry "Start WSL": the shipped start.bat opens the default
REM     distro in this (already elevated) window. If WSL cannot start it
REM     says why and waits for a key itself; either way the menu comes back.
:STARTWSL
echo.
call "!SELF_DIR!start.bat"
title WSL Setup
goto MENU

REM --- Distro list (main menu entry 1, and "install another") ---
:DISTROMENU
REM  The distro list only needs fetching once per run - a bad choice and
REM  "install another" come back here, and wsl.exe --list --online is slow.
if defined DISTROCOUNT goto SHOWMENU
echo.
echo   Fetching the list of available distros ...

REM  Parsing happens in list-distros.ps1, not here: wsl.exe prints UTF-16 when
REM  piped unless it is new enough to honour WSL_UTF8, and cmd cannot read
REM  UTF-16, so on older builds the list always came back empty. The script
REM  decodes the raw bytes, copes with any intro length or language, and
REM  prints NAME^|FRIENDLY lines. If it finds nothing, it shows what wsl.exe
REM  said on stderr, which for /f does not capture.
set "DISTROCOUNT=0"
for /f "usebackq tokens=1,* delims=|" %%D in (`powershell -NoProfile -ExecutionPolicy Bypass -File "!SELF_DIR!list-distros.ps1"`) do (
    set /a DISTROCOUNT+=1
    set "DISTRONAME_!DISTROCOUNT!=%%D"
    set "DISTROFRIENDLY_!DISTROCOUNT!=%%E"
)

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
if "!WSLSTATE!"=="OK" echo   %CLR_GREEN%[OK]%CLR_RESET% !WSLSTATUS!
if "!WSLSTATE!"=="INFO" echo   %CLR_YELLOW%[INFO]%CLR_RESET% !WSLSTATUS!
echo.
echo   Choose a distro to install:
echo.
for /l %%i in (1,1,!DISTROCOUNT!) do (
    echo   %%i.  !DISTROFRIENDLY_%%i!
)
echo   0.  Back
echo.

set "choice="
set /p choice="Choose an option: "

if "!choice!"=="0" goto MENU

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
goto DISTROMENU

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
set "CHK_RE=^[a-z_][a-z0-9_-]{0,31}$"
call :MATCHRE
if errorlevel 1 (
    echo %CLR_RED%[ERROR]%CLR_RESET% "!wslUser!" is not a valid Linux username.
    echo         Use only lowercase letters, digits, hyphen and underscore, and
    echo         start with a lowercase letter or underscore, max 32 characters
    echo         ^(e.g. "dev", "my_user"^).
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
REM  The name reaches PowerShell as an env var, never spliced into the command.
set "alreadyInstalled=0"
set "WSL_SETUP_DISTRO=!selectedName!"
powershell -NoProfile -Command "$n = $env:WSL_SETUP_DISTRO; $hit = Get-ChildItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss' -ErrorAction SilentlyContinue | Where-Object { $_.GetValue('DistributionName') -eq $n }; if ($hit) { exit 0 } else { exit 1 }"
if "!errorlevel!"=="0" set "alreadyInstalled=1"

if "!alreadyInstalled!"=="1" (
    echo !selectedFriendly! is already installed - skipping install,
    echo continuing straight to account setup.
) else (
    echo Installing !selectedFriendly! ...
    echo ^(--web-download is used to avoid a known WSL bug where install
    echo   can hang at 0.0%% - see Microsoft's WSL install docs^)

    REM  install-distro.ps1 shows a progress bar, returns wsl.exe's exit
    REM  code, and prints wsl.exe's output itself if the install fails.
    powershell -NoProfile -ExecutionPolicy Bypass -File "!SELF_DIR!install-distro.ps1" -Distro "!selectedName!" -Friendly "!selectedFriendly!"
    set "installResult=!errorlevel!"

    if not "!installResult!"=="0" (
        echo %CLR_RED%[ERROR]%CLR_RESET% wsl.exe --install failed for "!selectedName!" - output above.
        echo         If this is the very first WSL install on this PC, Windows
        echo         may need a restart to finish enabling WSL. Restart, then
        echo         run this tool again.
        call :CLEARCREDS
        pause
        goto MENUFRESH
    )
)

echo.
echo Waiting for !selectedFriendly! to finish initializing ...
echo ^(a first-ever WSL launch on this PC can take several minutes -
echo   it is extracting and booting the distro for the first time^)

powershell -NoProfile -ExecutionPolicy Bypass -File "!SELF_DIR!wait-distro.ps1" -Distro "!selectedName!"
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
    goto MENUFRESH
)

echo %CLR_RED%[ERROR]%CLR_RESET% !selectedFriendly! did not become ready after 5 minutes.
echo         Try launching it manually first: wsl -d !selectedName!
echo         If that also hangs, Windows may need a restart to finish
echo         enabling WSL. Restart your PC, then run this tool again
echo         and pick the same option - it will pick up where it left off.
call :CLEARCREDS
pause
goto MENUFRESH

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

set "WSL_SETUP_USER_RAW=!wslUser!"
set "USER_B64="
for /f "usebackq delims=" %%B in (`powershell -NoProfile -Command "[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($env:WSL_SETUP_USER_RAW))"`) do set "USER_B64=%%B"
set "WSL_SETUP_USER_RAW="

REM  Copy the shipped setup-user.sh into the distro, strip any CR (a CRLF
REM  checkout on Windows would otherwise break bash parsing), and run it as
REM  root. It reads USER_B64/PASS_B64 from the environment, forwarded via
REM  WSLENV for that one call only. Running `bash <path>` with no shell metacharacters on the command
REM  line avoids cmd.exe mangling a pipe, redirect, or && even inside quotes.
REM  Every value captured with `for /f` below is cleared first: when nothing
REM  comes back, `for /f` leaves the variable untouched, and on a second
REM  "install another" round a stale value from the first distro would be
REM  silently reused - e.g. reporting [OK] for a user check that failed.
REM  The copy goes into a file that root's own mktemp just created: a random
REM  name, owned by root, mode 0600. A fixed /tmp name could be created first
REM  by another user of an already-installed distro, who would then own the
REM  file and could rewrite it before it runs here as root.
REM  Results are compared with 0, not `if errorlevel 1`: wsl.exe exits with
REM  -1 for its own errors, which `if errorlevel 1` treats as success.
set "TMPSCRIPT="
for /f "usebackq delims=" %%T in (`wsl.exe -d !selectedName! -u root -- mktemp /tmp/wsl_setup_user.XXXXXXXX`) do set "TMPSCRIPT=%%T"
if not defined TMPSCRIPT goto COPYFAIL
wsl.exe -d !selectedName! -u root -- cp ./setup-user.sh "!TMPSCRIPT!"
if not "!errorlevel!"=="0" goto COPYFAIL
wsl.exe -d !selectedName! -u root -- sed -i "s/\r$//" "!TMPSCRIPT!"
if not "!errorlevel!"=="0" goto COPYFAIL
REM  Forward the credentials into exactly this one call, then stop at once.
REM  Otherwise every later wsl.exe call in this window - including
REM  setup-dev-tools.sh, which pipes installers from the internet into a
REM  shell - would still receive PASS_B64 in its environment.
if defined origWSLENV (
    set "WSLENV=USER_B64:PASS_B64:!origWSLENV!"
) else (
    set "WSLENV=USER_B64:PASS_B64"
)
wsl.exe -d !selectedName! -u root -- bash "!TMPSCRIPT!"
set "userScriptResult=!errorlevel!"
call :CLEARCREDS
wsl.exe -d !selectedName! -u root -- rm -f "!TMPSCRIPT!" >nul 2>&1

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

REM --- Show what WSL itself now reports, so the result is visible, not
REM     just claimed: WSL version/default distro, then every distro with its
REM     WSL version. Printed straight to the console, not parsed.
echo.
echo %CLR_CYAN%=========================================================%CLR_RESET%
echo   WSL status after setup
echo %CLR_CYAN%=========================================================%CLR_RESET%
wsl.exe --status
echo.
wsl.exe --list --verbose
echo.
echo To open !selectedFriendly! later as Administrator, run start.bat next to
echo this script, or pick "Start WSL" in the main menu. If WSL cannot start,
echo it tells you why. Or just type "wsl" in any terminal.

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
if not exist "!SELF_DIR!setup-dev-tools.sh" goto ASKAGAIN
echo.
set "devChoice="
set /p devChoice="Install dev tools now inside !selectedFriendly! - Node, Docker, GitHub CLI? [y/n]: "
if /i not "!devChoice!"=="y" goto ASKAGAIN
echo.
echo Running setup-dev-tools.sh inside !selectedFriendly! ...
REM  Copy it by its plain name (see the cd at the top) into a private temp file
REM  (the new user's own mktemp - see the note at setup-user.sh above), strip
REM  CR - the file may be checked out with CRLF on Windows - then run it as
REM  `bash <path>` with no shell metacharacters on the command line.
set "DEVTMP="
for /f "usebackq delims=" %%T in (`wsl.exe -d !selectedName! -- mktemp /tmp/wsl_setup_devtools.XXXXXXXX`) do set "DEVTMP=%%T"
if not defined DEVTMP goto DEVCOPYFAIL
wsl.exe -d !selectedName! -- cp ./setup-dev-tools.sh "!DEVTMP!"
if not "!errorlevel!"=="0" goto DEVCOPYFAIL
wsl.exe -d !selectedName! -- sed -i "s/\r$//" "!DEVTMP!"
if not "!errorlevel!"=="0" goto DEVCOPYFAIL
wsl.exe -d !selectedName! -- bash "!DEVTMP!"
set "devResult=!errorlevel!"
wsl.exe -d !selectedName! -- rm -f "!DEVTMP!" >nul 2>&1
if not "!devResult!"=="0" (
    echo %CLR_YELLOW%[WARN]%CLR_RESET% Dev-tools setup reported an error above. You can re-run it
    echo        anytime inside WSL with: bash setup-dev-tools.sh
) else (
    echo %CLR_GREEN%[OK]%CLR_RESET% Dev-tools setup finished.
)
echo.
pause
goto ASKAGAIN

:DEVCOPYFAIL
echo %CLR_YELLOW%[WARN]%CLR_RESET% Could not copy setup-dev-tools.sh into !selectedFriendly! - dev tools
echo        were NOT installed. Your WSL account itself is set up fine. To install
echo        them later, run inside WSL: bash setup-dev-tools.sh
if defined DEVTMP wsl.exe -d !selectedName! -- rm -f "!DEVTMP!" >nul 2>&1
echo.
pause

:ASKAGAIN
REM  What next: the distro just set up can be opened right here, without
REM  leaving the tool and hunting for start.bat. No cls - the results above
REM  stay readable. Compared with delayed expansion only, like the main menu.
echo.
echo %CLR_CYAN%=========================================================%CLR_RESET%
echo   Setup finished. What next?
echo %CLR_CYAN%=========================================================%CLR_RESET%
echo.
echo   1.  Start WSL now - open !selectedFriendly!
echo   2.  Install another distro
echo   0.  Exit
echo.
set "again="
set /p again="Choose an option: "
if "!again!"=="0" goto END
if "!again!"=="1" goto STARTAFTER
if "!again!"=="2" (
    call :WSLSTATUS
    goto DISTROMENU
)
echo.
echo %CLR_RED%[ERROR]%CLR_RESET% "!again!" is not a valid option.
goto ASKAGAIN

REM --- "Start WSL now": start.bat opens the distro just set up - by name,
REM     because it is not the default yet if the checks above ended early -
REM     in this window; typing exit there comes back to this menu.
REM     If WSL cannot start, start.bat says why and waits for a key itself.
REM     The name is one this tool listed itself: letters, digits, . _ -
:STARTAFTER
echo.
call "!SELF_DIR!start.bat" "!selectedName!"
title WSL Setup
goto ASKAGAIN

:END
echo.
echo %CLR_CYAN%=========================================================%CLR_RESET%
echo   Done.
echo %CLR_CYAN%=========================================================%CLR_RESET%
echo.
pause
exit /b

REM --- setup-user.sh could not be copied into the distro ---
:COPYFAIL
echo %CLR_RED%[ERROR]%CLR_RESET% Could not copy setup-user.sh into !selectedFriendly! - no account
echo         was created. See any output above, then try again. If this
echo         folder is on a drive WSL cannot see, such as some network
echo         shares, copy the folder to C:\ and run it from there.
if defined TMPSCRIPT wsl.exe -d !selectedName! -u root -- rm -f "!TMPSCRIPT!" >nul 2>&1
call :CLEARCREDS
set "wslUser="
pause
goto MENU

REM --- Ask wsl-status.ps1 whether WSL itself is installed ---
REM  Sets WSLSTATE to OK / INFO and WSLSTATUS to the message, shown at the top
REM  of the menu. Purely informational: wsl.exe --install sets WSL up either
REM  way. Cleared first so a failed check never shows a stale result.
:WSLSTATUS
set "WSLSTATE="
set "WSLSTATUS="
for /f "usebackq tokens=1,* delims=|" %%A in (`powershell -NoProfile -ExecutionPolicy Bypass -File "!SELF_DIR!wsl-status.ps1"`) do (
    set "WSLSTATE=%%A"
    set "WSLSTATUS=%%B"
)
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
