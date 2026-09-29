@echo off
rem =====================================================================
rem install-windows.bat - unified per-user installer for this project's
rem public Perl programs on Windows 10 and Windows 11.
rem
rem   * Installs Strawberry Perl through winget only when no suitable Perl
rem     (5.10.1 or newer, with the required core modules) is already
rem     available. The winget package id was verified against
rem     microsoft/winget-pkgs (StrawberryPerl.StrawberryPerl, MSI, silent).
rem   * Copies the public programs listed in perl\programs.txt and creates
rem     <install>\bin\<program>.cmd launchers from windows\launcher.cmd.
rem   * Adds <install>\bin to the *user* PATH (HKCU\Environment) only, in an
rem     idempotent way. The system PATH is never touched.
rem   * Never requires administrator rights for the steps it performs, never
rem     downloads arbitrary binaries, never disables security features.
rem
rem Usage: install-windows.bat [--dry-run] [--no-path] [--install-dir PATH]
rem                            [--help]
rem
rem See the LICENSE file at the top of the project tree for copyright and
rem license details.
rem =====================================================================

setlocal EnableExtensions DisableDelayedExpansion

set "REPO=%~dp0"
set "PROJECT="
set "VERSION=unknown"
set "OPT_DRY=0"
set "OPT_PATH=1"
set "OPT_INSTALL_DIR="
set "OPT_HELP=0"
set "PERL_EXE="
set "PROGRAMS="
set "MANIFEST_BAD="
set "INSTALL_FAIL="
set "VERIFY_FAIL="
set "WINGET_ID=StrawberryPerl.StrawberryPerl"
set "PERL_MODULES=-M5.010001 -MEncode -MUnicode::Normalize -MFile::Spec -MFile::Basename -MFile::Temp -MFile::Path -MGetopt::Long -MPod::Usage -MDigest::SHA -MCwd"

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
echo [ERROR] unknown option: %~1
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
call :warn_if_system_dir "%INSTALL_DIR%"

rem --------------------------------------------------------------------
rem Read the single source of truth for public programs
rem --------------------------------------------------------------------
if not exist "%REPO%perl\programs.txt" (
    echo [ERROR] missing program manifest: %REPO%perl\programs.txt
    exit /b 2
)
if not exist "%REPO%windows\launcher.cmd" (
    echo [ERROR] missing launcher template: %REPO%windows\launcher.cmd
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
rem Find an already usable Perl before considering winget
rem --------------------------------------------------------------------
call :find_perl

rem --------------------------------------------------------------------
rem Show the plan
rem --------------------------------------------------------------------
echo Installing %PROJECT% %VERSION%
echo.
echo Perl:
if defined PERL_EXE echo   found: %PERL_EXE%
if not defined PERL_EXE echo   would install via winget: %WINGET_ID%
echo Install root:
echo   %INSTALL_DIR%
echo Scripts:
for %%N in (%PROGRAMS%) do echo   %%N -^> %INSTALL_DIR%\perl\%%N
echo Launchers:
for %%N in (%PROGRAMS%) do echo   %%~nN.cmd -^> %INSTALL_DIR%\bin\%%~nN.cmd
echo PATH:
if "%OPT_PATH%"=="1" echo   add if missing: %INSTALL_DIR%\bin
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
echo [INFO] Using Perl: %PERL_EXE%
echo.

rem --------------------------------------------------------------------
rem Create the install tree and copy our files
rem --------------------------------------------------------------------
mkdir "%INSTALL_DIR%" >nul 2>&1
mkdir "%INSTALL_DIR%\perl" >nul 2>&1
mkdir "%INSTALL_DIR%\bin" >nul 2>&1
if not exist "%INSTALL_DIR%\bin" (
    echo [ERROR] cannot create %INSTALL_DIR%\bin
    exit /b 2
)

rem Keep the previous manifest so obsolete files we installed can be removed.
set "OLD_MANIFEST=%TEMP%\nf_old_%RANDOM%%RANDOM%.txt"
if exist "%INSTALL_DIR%\installed-files.txt" copy /y "%INSTALL_DIR%\installed-files.txt" "%OLD_MANIFEST%" >nul 2>&1

> "%INSTALL_DIR%\installed-files.txt" echo perl-path.txt
>> "%INSTALL_DIR%\installed-files.txt" echo installed-files.txt
>> "%INSTALL_DIR%\installed-files.txt" echo VERSION

> "%INSTALL_DIR%\perl-path.txt" echo %PERL_EXE%
if exist "%REPO%VERSION" copy /y "%REPO%VERSION" "%INSTALL_DIR%\VERSION" >nul 2>&1

for %%N in (%PROGRAMS%) do call :install_one "%%N"
if defined INSTALL_FAIL (
    echo [ERROR] one or more files could not be installed.
    exit /b 2
)

if exist "%OLD_MANIFEST%" call :cleanup_obsolete "%OLD_MANIFEST%"
if exist "%OLD_MANIFEST%" del /f /q "%OLD_MANIFEST%" >nul 2>&1

rem --------------------------------------------------------------------
rem User PATH (HKCU\Environment\Path only, idempotent)
rem --------------------------------------------------------------------
if "%OPT_PATH%"=="1" call :update_user_path

rem --------------------------------------------------------------------
rem Post-install verification
rem --------------------------------------------------------------------
echo.
echo Verifying installation:
call :verify_all
if defined VERIFY_FAIL (
    echo.
    echo [ERROR] post-install verification failed.
    exit /b 2
)

rem --------------------------------------------------------------------
rem Summary
rem --------------------------------------------------------------------
echo.
echo [INFO] %PROJECT% %VERSION% installed to %INSTALL_DIR%
echo [INFO] Programs installed: %PROGRAMS%
if "%OPT_PATH%"=="1" echo [INFO] User PATH now includes: %INSTALL_DIR%\bin
if "%OPT_PATH%"=="0" echo [INFO] PATH not modified. Add %INSTALL_DIR%\bin manually if wanted.
echo.
echo [NOTE] Open a new terminal so newly started applications pick up the
echo        updated PATH. The launchers also work through their full path.
echo [NOTE] Perl comes from Strawberry Perl and is not removed by this
echo        installer; other applications may depend on it.
exit /b 0

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

:detect_windows
set "WIN_OK=0"
set "WINVER=unknown"
set "WTMP=%TEMP%\nf_win_%RANDOM%%RANDOM%.txt"
powershell -NoProfile -Command "[Environment]::OSVersion.Version.Major.ToString() + '.' + [Environment]::OSVersion.Version.Minor.ToString() + '.' + [Environment]::OSVersion.Version.Build.ToString()" >"%WTMP%" 2>nul
if exist "%WTMP%" (
    set /p WINVER=<"%WTMP%"
    del /f /q "%WTMP%" >nul 2>&1
)
for /f "tokens=1 delims=." %%A in ("%WINVER%") do set "WINMAJOR=%%A"
if "%WINMAJOR%"=="10" set "WIN_OK=1"
exit /b 0

:warn_if_system_dir
echo "%~1" | find /i "%SystemRoot%" >nul
if not errorlevel 1 echo [WARN] %SystemRoot% needs administrator rights; prefer the default per-user path.
echo "%~1" | find /i "Program Files" >nul
if not errorlevel 1 echo [WARN] Program Files needs administrator rights; prefer the default per-user path.
exit /b 0

:collect_program
set "NAME=%~1"
if "%NAME%"=="" exit /b 0
if "%NAME:~0,1%"=="#" exit /b 0
if not "%NAME:~-3%"==".pl" (
    echo [ERROR] manifest entry is not a .pl program: %NAME%
    set "MANIFEST_BAD=1"
    exit /b 0
)
echo "%NAME%" | find "/" >nul
if not errorlevel 1 set "MANIFEST_BAD=1"
echo "%NAME%" | find "\" >nul
if not errorlevel 1 set "MANIFEST_BAD=1"
echo "%NAME%" | find " " >nul
if not errorlevel 1 set "MANIFEST_BAD=1"
set "PROGRAMS=%PROGRAMS% %NAME%"
exit /b 0

:try_perl
set "CAND=%~1"
if not exist "%CAND%" exit /b 0
"%CAND%" %PERL_MODULES% -e exit >nul 2>&1
if not errorlevel 1 set "PERL_EXE=%CAND%"
exit /b 0

:find_perl
set "PERL_EXE="
for /f "delims=" %%P in ('where perl 2^>nul') do call :try_perl "%%P"
if defined PERL_EXE exit /b 0
call :try_perl "%SystemDrive%\Strawberry\perl\bin\perl.exe"
if defined PERL_EXE exit /b 0
call :try_perl "%ProgramFiles%\Strawberry\perl\bin\perl.exe"
if defined PERL_EXE exit /b 0
call :try_perl "%LOCALAPPDATA%\Programs\Strawberry\perl\bin\perl.exe"
if defined PERL_EXE exit /b 0
set "SAVED_PATH=%PATH%"
call :load_registry_path
if defined REGPATH set "PATH=%REGPATH%"
for /f "delims=" %%P in ('where perl 2^>nul') do call :try_perl "%%P"
if defined SAVED_PATH set "PATH=%SAVED_PATH%"
exit /b 0

:load_registry_path
set "REGPATH="
set "RTMP=%TEMP%\nf_regpath_%RANDOM%%RANDOM%.txt"
powershell -NoProfile -Command "[Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User')" >"%RTMP%" 2>nul
if exist "%RTMP%" (
    set /p REGPATH=<"%RTMP%"
    del /f /q "%RTMP%" >nul 2>&1
)
exit /b 0

:install_perl
echo [INFO] No suitable Perl found; a Windows Perl distribution is required.
where winget >nul 2>&1
if errorlevel 1 (
    echo [ERROR] winget is not available.
    echo         Install or update "App Installer" from the Microsoft Store,
    echo         then run this installer again.
    exit /b 0
)
echo [INFO] Installing %WINGET_ID% with winget...
winget install --id %WINGET_ID% --exact --accept-package-agreements --accept-source-agreements --silent
set "WRC=%ERRORLEVEL%"
if not "%WRC%"=="0" echo [WARN] winget exited with code %WRC%; checking for Perl anyway.
call :find_perl
if defined PERL_EXE echo [INFO] Perl available at: %PERL_EXE%
exit /b 0

:install_one
set "NAME=%~1"
set "LNAME=%NAME:.pl=%"
if defined SEEN_%LNAME% (
    echo [ERROR] duplicate launcher name: %LNAME%
    set "INSTALL_FAIL=1"
    exit /b 0
)
set "SEEN_%LNAME%=1"
copy /y "%REPO%perl\%NAME%" "%INSTALL_DIR%\perl\%NAME%" >nul
if errorlevel 1 (
    echo [ERROR] cannot copy %NAME%
    set "INSTALL_FAIL=1"
    exit /b 0
)
copy /y "%REPO%windows\launcher.cmd" "%INSTALL_DIR%\bin\%LNAME%.cmd" >nul
if errorlevel 1 (
    echo [ERROR] cannot create launcher %LNAME%.cmd
    set "INSTALL_FAIL=1"
    exit /b 0
)
>> "%INSTALL_DIR%\installed-files.txt" echo perl\%NAME%
>> "%INSTALL_DIR%\installed-files.txt" echo bin\%LNAME%.cmd
exit /b 0

:cleanup_obsolete
set "OLD=%~1"
for /f "usebackq tokens=1 delims=" %%E in ("%OLD%") do call :maybe_remove "%%E"
exit /b 0

:maybe_remove
set "ENTRY=%~1"
if "%ENTRY%"=="" exit /b 0
if /i "%ENTRY%"=="perl-path.txt" exit /b 0
if /i "%ENTRY%"=="installed-files.txt" exit /b 0
if /i "%ENTRY%"=="VERSION" exit /b 0
if /i not "%ENTRY:~0,4%"=="bin\" if /i not "%ENTRY:~0,5%"=="perl\" exit /b 0
set "KEEP=0"
for %%N in (%PROGRAMS%) do (
    if /i "%ENTRY%"=="perl\%%N" set "KEEP=1"
    if /i "%ENTRY%"=="bin\%%~nN.cmd" set "KEEP=1"
)
if "%KEEP%"=="1" exit /b 0
set "TARGET=%INSTALL_DIR%\%ENTRY%"
if not exist "%TARGET%" exit /b 0
if /i "%ENTRY:~0,4%"=="bin\" (
    findstr /c:"perl-path.txt" "%TARGET%" >nul 2>&1
    if errorlevel 1 exit /b 0
)
del /f /q "%TARGET%" >nul 2>&1
if not exist "%TARGET%" echo [INFO] Removed obsolete: %ENTRY%
exit /b 0

:update_user_path
set "NF_BIN=%INSTALL_DIR%\bin"
set "PSOUT=%TEMP%\nf_path_%RANDOM%%RANDOM%.txt"
set "PATH_RESULT=error"
powershell -NoProfile -Command "$b=$env:NF_BIN; $k=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment',$true); if($null -eq $k){$k=[Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Environment')}; $cur=$k.GetValue('Path',$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames); if($null -eq $cur){$cur='';$kind=[Microsoft.Win32.RegistryValueKind]::ExpandString}else{$kind=$k.GetValueKind('Path')}; $t=$b.TrimEnd('\').ToLower(); $found=$false; foreach($e in ($cur -split ';')){ if($e.Trim() -ne '' -and $e.TrimEnd('\').ToLower() -eq $t){$found=$true;break} }; if($found){'present'}else{$list=@(); foreach($e in ($cur -split ';')){if($e.Trim() -ne ''){$list+=$e}}; $list+=$b; $k.SetValue('Path',($list -join ';'),$kind); 'added'}; $k.Close()" >"%PSOUT%" 2>nul
if exist "%PSOUT%" (
    set /p PATH_RESULT=<"%PSOUT%"
    del /f /q "%PSOUT%" >nul 2>&1
)
if /i "%PATH_RESULT%"=="added" echo [INFO] Added to user PATH: %NF_BIN%
if /i "%PATH_RESULT%"=="present" echo [INFO] User PATH already contains: %NF_BIN%
if /i not "%PATH_RESULT%"=="added" if /i not "%PATH_RESULT%"=="present" echo [WARN] Could not update the user PATH automatically.
exit /b 0

:verify_all
call :verify_launcher "normalize-files"
for %%N in (%PROGRAMS%) do call :verify_script "%%N"
exit /b 0

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

:verify_launcher
set "LNAME=%~1"
set "LAUNCHER=%INSTALL_DIR%\bin\%LNAME%.cmd"
set "VOUT=%TEMP%\nf_verify_%RANDOM%%RANDOM%.txt"
"%LAUNCHER%" --version >"%VOUT%" 2>&1
set "VRC=%ERRORLEVEL%"
if "%VRC%"=="0" (
    echo   OK   %LNAME% --version
) else (
    echo [ERROR] %LNAME% --version failed, exit code %VRC%
    set "VERIFY_FAIL=1"
)
"%LAUNCHER%" --help >"%VOUT%" 2>&1
set "VRC=%ERRORLEVEL%"
if "%VRC%"=="0" (
    echo   OK   %LNAME% --help
) else (
    echo [ERROR] %LNAME% --help failed, exit code %VRC%
    set "VERIFY_FAIL=1"
)
"%LAUNCHER%" --this-option-does-not-exist >"%VOUT%" 2>&1
set "VRC=%ERRORLEVEL%"
if "%VRC%"=="3" (
    echo   OK   %LNAME% propagates the Perl exit status
) else (
    echo [ERROR] %LNAME% lost the exit status, got %VRC%
    set "VERIFY_FAIL=1"
)
set "VTMP=%TEMP%\nf_vdir_%RANDOM%%RANDOM%"
mkdir "%VTMP%" >nul 2>&1
> "%VTMP%\Name With Spaces.txt" echo sample
"%LAUNCHER%" --dry-run "%VTMP%" >"%VOUT%" 2>&1
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
