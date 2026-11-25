@echo off
rem =====================================================================
rem install-windows.bat - unified per-user installer for this project's
rem public Perl and PowerShell programs on Windows 10 and Windows 11.
rem
rem   * Installs Strawberry Perl through winget only when no suitable Perl
rem     (5.10.1 or newer, with the required core modules) is already
rem     available. The winget package id was verified against
rem     microsoft/winget-pkgs (StrawberryPerl.StrawberryPerl, MSI, silent).
rem   * Copies the public programs listed in perl\programs.txt and creates
rem     <install>\bin\<program>.cmd launchers from windows\launcher.cmd.
rem   * Adds <install>\bin to the *user* PATH (HKCU\Environment) only, in an
rem     idempotent way. The system PATH is never touched.
rem   * No step requires administrator rights for its own setup (per-user files
rem     and HKCU\Environment only); installing Strawberry Perl through winget
rem     uses the vendor MSI and may prompt for elevation. Never downloads
rem     arbitrary binaries, never disables security features.
rem
rem Usage: install-windows.bat [--dry-run] [--no-path] [--install-dir PATH]
rem                            [--help]
rem
rem See the LICENSE file at the top of the project tree for copyright and
rem license details.
rem =====================================================================

setlocal EnableExtensions DisableDelayedExpansion

for %%I in ("%~dp0..") do set "REPO=%%~fI\"
set "SYS_PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
set "PS7=%ProgramFiles%\PowerShell\7\pwsh.exe"
set "TRUST=%REPO%windows\install-support\trust.ps1"
set "PROJECT="
set "VERSION=unknown"
set "OPT_DRY=0"
set "OPT_PATH=1"
set "OPT_INSTALL_DIR="
set "OPT_HELP=0"
set "PERL_EXE="
set "PROGRAMS="
set "PS_PROGRAMS="
set "MANIFEST_BAD="
set "INSTALL_FAIL="
set "VERIFY_FAIL="
set "WINGET_ID=StrawberryPerl.StrawberryPerl"
set "PERL_MODULES=-M5.010001 -MEncode -MUnicode::Normalize -MFile::Spec -MFile::Basename -MFile::Temp -MFile::Path -MGetopt::Long -MPod::Usage -MDigest::SHA -MCwd -MWin32 -MWin32API::File"

rem --------------------------------------------------------------------
rem Argument parsing (only a few options on purpose)
rem --------------------------------------------------------------------
:parse_args
if "%~1"=="" goto args_done
if /i "%~1"=="--help" goto opt_help
if /i "%~1"=="-h" goto opt_help
if /i "%~1"=="--dry-run" goto opt_dry
if /i "%~1"=="--no-path" goto opt_nopath
if /i "%~1"=="--install-dir" goto opt_installdir
echo [ERROR] unknown option
call :usage
exit /b 3

:args_done
if "%OPT_HELP%"=="1" (
    call :usage
    exit /b 0
)

rem --------------------------------------------------------------------
rem Platform check: Windows 10 or Windows 11 only
rem --------------------------------------------------------------------
if /i not "%OS%"=="Windows_NT" (
    echo [ERROR] This installer only supports Windows 10 and Windows 11.
    exit /b 2
)
call :detect_windows
if not "%WIN_OK%"=="1" (
    echo [ERROR] Unsupported Windows version: %WINVER%
    echo         This installer only supports Windows 10 and Windows 11.
    exit /b 2
)

rem --------------------------------------------------------------------
rem Project name, version and install root
rem --------------------------------------------------------------------
for %%I in ("%REPO:~0,-1%") do set "PROJECT=%%~nxI"
if not defined PROJECT set "PROJECT=scripts"
if exist "%REPO%VERSION" set /p VERSION=<"%REPO%VERSION"
if not defined VERSION set "VERSION=unknown"

if defined OPT_INSTALL_DIR goto install_dir_ready
if defined LOCALAPPDATA set "OPT_INSTALL_DIR=%LOCALAPPDATA%\Programs\%PROJECT%"
if not defined OPT_INSTALL_DIR set "OPT_INSTALL_DIR=%USERPROFILE%\Programs\%PROJECT%"
:install_dir_ready
set "INSTALL_DIR=%OPT_INSTALL_DIR%"
rem Canonicalize so a relative --install-dir is not stored verbatim in PATH.
for %%I in ("%INSTALL_DIR%") do set "INSTALL_DIR=%%~fI"
"%SYS_PS%" -NoProfile -File "%TRUST%" -Action ValidatePath -Path "%INSTALL_DIR%"
if errorlevel 1 exit /b 2

rem --------------------------------------------------------------------
rem Read the single source of truth for public programs
rem --------------------------------------------------------------------
if not exist "%REPO%perl\programs.txt" (
    echo [ERROR] missing program manifest: "%REPO%perl\programs.txt"
    exit /b 2
)
if not exist "%REPO%windows\launcher.cmd" (
    echo [ERROR] missing launcher template: "%REPO%windows\launcher.cmd"
    exit /b 2
)
for /f "usebackq tokens=1 delims=" %%L in ("%REPO%perl\programs.txt") do call :collect_program "%%L"
if defined MANIFEST_BAD (
    echo [ERROR] invalid entries in perl\programs.txt
    exit /b 2
)
if not defined PROGRAMS (
    echo [ERROR] no programs listed in perl\programs.txt
    exit /b 2
)

rem --------------------------------------------------------------------
rem Top-level scripts become public commands. Keep installer helpers in a
rem subdirectory so they do not acquire standalone launchers.
rem Discover PowerShell programs alongside this installer and the formatter.
rem --------------------------------------------------------------------
if not exist "%REPO%windows\powershell-launcher.cmd" (
    echo [ERROR] missing PowerShell launcher template.
    exit /b 2
)
for %%N in ("%REPO%windows\*.ps1") do if exist "%%~fN" call :collect_ps_program "%%~nxN"
if not exist "%REPO%windows\test-format\psfmt.ps1" (
    echo [ERROR] missing formatter: windows\test-format\psfmt.ps1
    exit /b 2
)
rem psfmt lives under test-format but is installed like a top-level script.
call :collect_ps_program "psfmt.ps1"
if "%INSTALL_FAIL%"=="1" (
    echo [ERROR] invalid PowerShell script name; cannot continue.
    exit /b 2
)
if not exist "%PS7%" echo [WARN] PowerShell 7 is not installed in its standard location; psfmt requires it.

rem --------------------------------------------------------------------
rem Only inspect candidate paths in dry-run mode.
rem --------------------------------------------------------------------
call :find_perl

rem --------------------------------------------------------------------
rem Show the plan
rem --------------------------------------------------------------------
echo Installing "%PROJECT%" "%VERSION%"
echo.
echo Perl:
if defined PERL_EXE echo   found: "%PERL_EXE%"
if not defined PERL_EXE echo   would install via winget: %WINGET_ID%
echo Install root:
echo   "%INSTALL_DIR%"
echo Scripts:
for %%N in (%PROGRAMS%) do echo   %%N -^> "%INSTALL_DIR%\perl\%%N"
for %%N in (%PS_PROGRAMS%) do echo   %%N -^> "%INSTALL_DIR%\windows\%%N"
echo Launchers:
for %%N in (%PROGRAMS% %PS_PROGRAMS%) do echo   %%~nN.cmd -^> "%INSTALL_DIR%\bin\%%~nN.cmd"
echo PATH:
if "%OPT_PATH%"=="1" echo   add if missing: "%INSTALL_DIR%\bin"
if "%OPT_PATH%"=="0" echo   not modified: --no-path
echo.

if "%OPT_DRY%"=="1" (
    echo [DRY-RUN] no changes were made.
    exit /b 0
)

rem --------------------------------------------------------------------
rem Install Strawberry Perl when needed
rem --------------------------------------------------------------------
if not defined PERL_EXE call :install_perl
if not defined PERL_EXE (
    echo [ERROR] no suitable Perl is available; cannot continue.
    exit /b 2
)
echo [INFO] Using Perl: "%PERL_EXE%"
echo.

rem --------------------------------------------------------------------
rem Create the install tree and copy our files
rem --------------------------------------------------------------------
set "FINAL_INSTALL_DIR=%INSTALL_DIR%"
set "INSTALL_STAGE="
for /f "usebackq delims=" %%G in (`""%SYS_PS%" -NoProfile -File "%TRUST%" -Action Stage"`) do set "INSTALL_STAGE=%%G"
if not defined INSTALL_STAGE exit /b 2
set "INSTALL_DIR=%INSTALL_STAGE%"
mkdir "%INSTALL_DIR%\perl" >nul 2>&1
mkdir "%INSTALL_DIR%\windows" >nul 2>&1
mkdir "%INSTALL_DIR%\bin" >nul 2>&1
if not exist "%INSTALL_DIR%\bin" (
    echo [ERROR] cannot create "%INSTALL_DIR%\bin"
    goto install_failed
)

set "NEW_MANIFEST=%INSTALL_DIR%\installed-files.txt.new"

> "%NEW_MANIFEST%" echo perl-path.txt
>> "%NEW_MANIFEST%" echo installed-files.txt
>> "%NEW_MANIFEST%" echo VERSION

rem Write the interpreter path without letting cmd parse &, |, <, > or ^ in
rem the path. Delayed expansion is local to this block.
setlocal EnableDelayedExpansion
> "%INSTALL_DIR%\perl-path.txt" echo(!PERL_EXE!
endlocal
if exist "%REPO%VERSION" copy /y "%REPO%VERSION" "%INSTALL_DIR%\VERSION" >nul 2>&1

for %%N in (%PROGRAMS%) do call :install_one "%%N" "perl" "launcher.cmd"
for %%N in (%PS_PROGRAMS%) do call :install_one "%%N" "windows" "powershell-launcher.cmd"
if defined INSTALL_FAIL (
    echo [ERROR] one or more files could not be installed.
    if exist "%NEW_MANIFEST%" del /f /q "%NEW_MANIFEST%" >nul 2>&1
    goto install_failed
)
move /y "%NEW_MANIFEST%" "%INSTALL_DIR%\installed-files.txt" >nul
if errorlevel 1 (
    echo [ERROR] cannot publish installed-files.txt
    goto install_failed
)

rem --------------------------------------------------------------------
rem Post-install verification
rem --------------------------------------------------------------------
echo.
echo Verifying installation:
call :verify_all
if defined VERIFY_FAIL (
    echo.
    echo [ERROR] post-install verification failed.
    goto install_failed
)
set "INSTALL_DIR=%FINAL_INSTALL_DIR%"
"%SYS_PS%" -NoProfile -File "%REPO%windows\install-support\publish.ps1" -Stage "%INSTALL_STAGE%" -Destination "%INSTALL_DIR%"
if errorlevel 1 goto install_failed
rmdir /s /q "%INSTALL_STAGE%" >nul 2>&1

rem --------------------------------------------------------------------
rem User PATH (HKCU\Environment\Path only, idempotent). Do this only after a
rem successful verification so a broken install is not added to PATH.
rem --------------------------------------------------------------------
if "%OPT_PATH%"=="1" (
    "%SYS_PS%" -NoProfile -File "%TRUST%" -Action AddPath -Path "%INSTALL_DIR%\bin"
    if errorlevel 1 (
        echo [ERROR] Files published but user PATH was not changed.
        exit /b 2
    )
)

rem --------------------------------------------------------------------
rem Summary
rem --------------------------------------------------------------------
echo.
echo [INFO] "%PROJECT%" "%VERSION%" installed to "%INSTALL_DIR%"
echo [INFO] Programs installed: %PROGRAMS% %PS_PROGRAMS%
if "%OPT_PATH%"=="0" echo [INFO] PATH not modified. Add "%INSTALL_DIR%\bin" manually if wanted.
echo.
echo [NOTE] Open a new terminal so newly started applications pick up the
echo        updated PATH. The launchers also work through their full path.
echo [NOTE] Perl comes from Strawberry Perl and is not removed by this
echo        installer; other applications may depend on it.
exit /b 0

:install_failed
rmdir /s /q "%INSTALL_STAGE%" >nul 2>&1
exit /b 2

rem ====================================================================
rem Subroutines
rem ====================================================================

:opt_help
set "OPT_HELP=1"
shift
goto parse_args

:opt_dry
set "OPT_DRY=1"
shift
goto parse_args

:opt_nopath
set "OPT_PATH=0"
shift
goto parse_args

:opt_installdir
if "%~2"=="" (
    echo [ERROR] --install-dir needs a path argument
    exit /b 3
)
set "OPT_INSTALL_DIR=%~2"
shift
shift
goto parse_args

:usage
echo Usage: install-windows.bat [options]
echo.
echo Options:
echo   --dry-run            Show the plan and exit without changing anything.
echo   --no-path            Do not modify the user PATH.
echo   --install-dir PATH   Install to PATH instead of the per-user default.
echo   --help               Show this help.
exit /b 0

rem Read the OS version directly without creating scratch files.
:detect_windows
set "WIN_OK=0"
set "WINVER=unknown"
for /f "usebackq delims=" %%V in (`""%SYS_PS%" -NoProfile -File "%TRUST%" -Action Version"`) do set "WINVER=%%V"
for /f "tokens=1 delims=." %%A in ("%WINVER%") do set "WINMAJOR=%%A"
if "%WINMAJOR%"=="10" set "WIN_OK=1"
exit /b 0

rem Validate one perl\programs.txt line. Entries are bare .pl names; blank lines
rem and lines starting with # are ignored, and invalid entries set MANIFEST_BAD
rem for the caller to report after the loop.
:collect_program
set "NAME=%~1"
if "%NAME%"=="" exit /b 0
if "%NAME:~0,1%"=="#" exit /b 0
if not "%NAME:~-3%"==".pl" (
    echo [ERROR] manifest entry is not a .pl program: "%NAME%"
    set "MANIFEST_BAD=1"
    exit /b 0
)
rem Reject names with path separators or spaces. String substitution avoids
rem the pipe/echo pitfall where a space before "|" is printed and then found.
set "CHK=%NAME:/=%"
if not "%CHK%"=="%NAME%" set "MANIFEST_BAD=1"
set "CHK=%NAME:\=%"
if not "%CHK%"=="%NAME%" set "MANIFEST_BAD=1"
set "CHK=%NAME: =%"
if not "%CHK%"=="%NAME%" set "MANIFEST_BAD=1"
set "CHK=%NAME:&=%"
if not "%CHK%"=="%NAME%" set "MANIFEST_BAD=1"
set "CHK=%NAME:|=%"
if not "%CHK%"=="%NAME%" set "MANIFEST_BAD=1"
set "CHK=%NAME:<=%"
if not "%CHK%"=="%NAME%" set "MANIFEST_BAD=1"
set "CHK=%NAME:>=%"
if not "%CHK%"=="%NAME%" set "MANIFEST_BAD=1"
set "PROGRAMS=%PROGRAMS% %NAME%"
exit /b 0

rem Add one discovered PowerShell script. Names must end in .ps1 and must not
rem contain spaces or the shell characters checked here, because the installed
rem launcher name is derived from the script name. Failures set INSTALL_FAIL.
:collect_ps_program
set "NAME=%~1"
if "%NAME%"=="" exit /b 0
if not "%NAME:~-4%"==".ps1" (
    echo [ERROR] PowerShell entry is not a .ps1 script: "%NAME%"
    set "INSTALL_FAIL=1"
    exit /b 0
)
set "CHK=%NAME: =%"
if not "%CHK%"=="%NAME%" (
    echo [ERROR] PowerShell script name contains a space: "%NAME%"
    set "INSTALL_FAIL=1"
    exit /b 0
)
set "CHK=%NAME:&=%"
if not "%CHK%"=="%NAME%" set "INSTALL_FAIL=1"
set "CHK=%NAME:|=%"
if not "%CHK%"=="%NAME%" set "INSTALL_FAIL=1"
set "CHK=%NAME:<=%"
if not "%CHK%"=="%NAME%" set "INSTALL_FAIL=1"
set "CHK=%NAME:>=%"
if not "%CHK%"=="%NAME%" set "INSTALL_FAIL=1"
set "PS_PROGRAMS=%PS_PROGRAMS% %NAME%"
exit /b 0

rem Accept a candidate only when it runs with every required core module.
:try_perl
if defined PERL_EXE exit /b 0
set "CAND=%~1"
if not exist "%CAND%" exit /b 0
"%CAND%" %PERL_MODULES% -e exit >nul 2>&1
if not errorlevel 1 set "PERL_EXE=%CAND%"
exit /b 0

rem The helper resolves and validates executable paths without a CMD search.
:find_perl
set "PERL_EXE="
for /f "usebackq delims=" %%P in (`""%SYS_PS%" -NoProfile -File "%TRUST%" -Action FindPerl"`) do (
    if "%OPT_DRY%"=="1" (
        if not defined PERL_EXE set "PERL_EXE=%%P"
    ) else (
        call :try_perl "%%P"
    )
)
exit /b 0

rem Install Strawberry Perl with winget only after no existing Perl passed the
rem module check. A nonzero winget status is a warning because Perl may still
rem have become available, so find_perl is retried.
:install_perl
echo [INFO] No suitable Perl found; a Windows Perl distribution is required.
set "WINGET_EXE="
for /f "usebackq delims=" %%P in (`""%SYS_PS%" -NoProfile -File "%TRUST%" -Action Winget"`) do set "WINGET_EXE=%%P"
if not defined WINGET_EXE (
    echo [ERROR] winget is not available.
    echo         Install or update "App Installer" from the Microsoft Store,
    echo         then run this installer again.
    exit /b 0
)
echo [INFO] Installing %WINGET_ID% with winget...
"%WINGET_EXE%" install --id %WINGET_ID% --exact --source winget --accept-package-agreements --accept-source-agreements --silent --disable-interactivity
set "WRC=%ERRORLEVEL%"
if not "%WRC%"=="0" echo [WARN] winget exited with code %WRC%; checking for Perl anyway.
call :find_perl
if defined PERL_EXE echo [INFO] Perl available at: "%PERL_EXE%"
exit /b 0

rem Copy one program (or psfmt.ps1) and create its launcher. Launcher names must
rem be unique across Perl and PowerShell programs. Every installed file is added
rem to installed-files.txt for the next upgrade's obsolete-file cleanup.
:install_one
set "NAME=%~1"
set "LNAME=%~n1"
set "SCRIPT_FOLDER=%~2"
set "TEMPLATE=%~3"
set "SOURCE_FOLDER=%SCRIPT_FOLDER%"
if /i "%SCRIPT_FOLDER%\%NAME%"=="windows\psfmt.ps1" set "SOURCE_FOLDER=windows\test-format"
if defined SEEN_%LNAME% (
    echo [ERROR] duplicate launcher name: %LNAME%
    set "INSTALL_FAIL=1"
    exit /b 0
)
set "SEEN_%LNAME%=1"
copy /y "%REPO%%SOURCE_FOLDER%\%NAME%" "%INSTALL_DIR%\%SCRIPT_FOLDER%\%NAME%" >nul
if errorlevel 1 (
    echo [ERROR] cannot copy %NAME%
    set "INSTALL_FAIL=1"
    exit /b 0
)
copy /y "%REPO%windows\%TEMPLATE%" "%INSTALL_DIR%\bin\%LNAME%.cmd" >nul
if errorlevel 1 (
    echo [ERROR] cannot create launcher %LNAME%.cmd
    set "INSTALL_FAIL=1"
    exit /b 0
)
>> "%NEW_MANIFEST%" echo %SCRIPT_FOLDER%\%NAME%
>> "%NEW_MANIFEST%" echo bin\%LNAME%.cmd
exit /b 0


rem Verify every installed program, plus the normalize-files launcher's argument
rem forwarding and exit status.
:verify_all
call :verify_launcher "normalize-files"
for %%N in (%PROGRAMS%) do call :verify_script "%%N"
for %%N in (%PS_PROGRAMS%) do call :verify_ps_script "%%N"
if exist "%PS7%" (
    "%PS7%" -NoProfile -File "%INSTALL_DIR%\windows\psfmt.ps1" -version >nul 2>&1
    if errorlevel 1 (
        echo [WARN] psfmt.ps1 did not run under pwsh; check the execution policy.
    ) else (
        echo   OK   psfmt.ps1 -Version
    )
) else (
    echo [WARN] pwsh not found; psfmt requires PowerShell 7 at runtime.
)
exit /b 0

rem Parse the installed PowerShell script without executing it.
:verify_ps_script
set "PS_SCRIPT=%INSTALL_DIR%\windows\%~1"
"%SYS_PS%" -NoProfile -Command "$tokens=$null; $errors=$null; $null=[System.Management.Automation.Language.Parser]::ParseFile($env:PS_SCRIPT,[ref]$tokens,[ref]$errors); if($errors.Count){$errors | Out-String | Write-Host; exit 1}" >nul 2>&1
if errorlevel 1 (
    echo [ERROR] PowerShell syntax check failed for %~1
    set "VERIFY_FAIL=1"
) else (
    echo   OK   %~1 parses
)
exit /b 0

rem Compile-check the installed Perl program with the interpreter selected by
rem this run.
:verify_script
set "NAME=%~1"
"%PERL_EXE%" -c "%INSTALL_DIR%\perl\%NAME%" >nul 2>&1
if errorlevel 1 (
    echo [ERROR] perl -c failed for %NAME%
    set "VERIFY_FAIL=1"
) else (
    echo   OK   %NAME% compiles
)
exit /b 0

rem Exercise the normalize-files launcher: --version and --help must succeed, an
rem unknown option must return 3, and --dry-run on a temporary directory with a
rem sample file must return 1. All output goes to a temporary file.
:verify_launcher
set "LNAME=%~1"
set "LAUNCHER=%INSTALL_DIR%\bin\%LNAME%.cmd"
set "VOUT=%INSTALL_STAGE%\verify-output.txt"
call "%LAUNCHER%" --version >"%VOUT%" 2>&1
set "VRC=%ERRORLEVEL%"
if "%VRC%"=="0" (
    echo   OK   %LNAME% --version
) else (
    echo [ERROR] %LNAME% --version failed, exit code %VRC%
    set "VERIFY_FAIL=1"
)
call "%LAUNCHER%" --help >"%VOUT%" 2>&1
set "VRC=%ERRORLEVEL%"
if "%VRC%"=="0" (
    echo   OK   %LNAME% --help
) else (
    echo [ERROR] %LNAME% --help failed, exit code %VRC%
    set "VERIFY_FAIL=1"
)
call "%LAUNCHER%" --this-option-does-not-exist >"%VOUT%" 2>&1
set "VRC=%ERRORLEVEL%"
if "%VRC%"=="3" (
    echo   OK   %LNAME% propagates the Perl exit status
) else (
    echo [ERROR] %LNAME% lost the exit status, got %VRC%
    set "VERIFY_FAIL=1"
)
set "VTMP=%INSTALL_STAGE%\verify-input"
mkdir "%VTMP%" >nul 2>&1
if errorlevel 1 (
    set "VERIFY_FAIL=1"
    exit /b 0
)
> "%VTMP%\Name With Spaces.txt" echo sample
call "%LAUNCHER%" --dry-run "%VTMP%" >"%VOUT%" 2>&1
set "VRC=%ERRORLEVEL%"
if "%VRC%"=="1" (
    echo   OK   %LNAME% dry-run on a temporary directory
) else (
    echo [ERROR] %LNAME% dry-run returned %VRC%
    set "VERIFY_FAIL=1"
)
rmdir /s /q "%VTMP%" >nul 2>&1
del /f /q "%VOUT%" >nul 2>&1
exit /b 0
