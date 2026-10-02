@echo off
rem Static checks for the Windows installer, launchers and Perl manifest.
rem Usage: validate-windows-installer.bat [ROOT_DIR]
rem Defaults to the repository containing this validator, from any directory.
rem Exit status: 0 success, 1 validation failure, 2 invalid arguments.
rem Requires only cmd.exe and the built-in Windows PowerShell.
rem See the LICENSE file at the top of the project tree for license details.
setlocal EnableExtensions DisableDelayedExpansion
set "ROOT_DIR=%~1"
if not "%~2"=="" goto usage
if not defined ROOT_DIR set "ROOT_DIR=%~dp0.."
if "%ROOT_DIR:~0,1%"=="-" goto usage
if not exist "%ROOT_DIR%\" (
    echo [ERROR] not a directory: "%ROOT_DIR%" 1>&2
    exit /b 2
)
for %%I in ("%ROOT_DIR%") do set "ROOT_DIR=%%~fI"
set "INSTALLER=%ROOT_DIR%\windows\install-windows.bat"
set "LAUNCHER=%ROOT_DIR%\windows\launcher.cmd"
set "PS_LAUNCHER=%ROOT_DIR%\windows\powershell-launcher.cmd"
set "MANIFEST=%ROOT_DIR%\perl\programs.txt"
set "MAKEFILE=%ROOT_DIR%\Makefile"
set "FAIL=0"

rem Literal content checks. Keep patterns out of CALL's second expansion.
set "CHECK_PATTERN=%%~dp0"
set "CHECK_MESSAGE=install-windows.bat must resolve files relative to the batch directory"
call :require "%INSTALLER%"
set "CHECK_PATTERN=perl\programs.txt"
set "CHECK_MESSAGE=install-windows.bat must read the perl/programs.txt manifest"
call :require "%INSTALLER%"
set "CHECK_PATTERN=windows\launcher.cmd"
set "CHECK_MESSAGE=install-windows.bat must use the launcher template"
call :require "%INSTALLER%"
set "CHECK_PATTERN=StrawberryPerl.StrawberryPerl"
set "CHECK_MESSAGE=install-windows.bat must install Strawberry Perl via winget"
call :require "%INSTALLER%"
set "CHECK_PATTERN=--exact"
set "CHECK_MESSAGE=winget install must use --exact"
call :require "%INSTALLER%"
set "CHECK_PATTERN=--accept-package-agreements"
set "CHECK_MESSAGE=winget install must accept package agreements non-interactively"
call :require "%INSTALLER%"
set "CHECK_PATTERN=--accept-source-agreements"
set "CHECK_MESSAGE=winget install must accept source agreements non-interactively"
call :require "%INSTALLER%"
set "CHECK_PATTERN=--silent"
set "CHECK_MESSAGE=winget install should be silent"
call :require "%INSTALLER%"
set "CHECK_PATTERN=where winget"
set "CHECK_MESSAGE=install-windows.bat must check for winget before using it"
call :require "%INSTALLER%"
set "CHECK_PATTERN=DisableDelayedExpansion"
set "CHECK_MESSAGE=install-windows.bat must avoid global delayed expansion"
call :require "%INSTALLER%"
set "CHECK_PATTERN=CurrentUser"
set "CHECK_MESSAGE=user PATH must be updated through HKCU (CurrentUser)"
call :require "%INSTALLER%"
set "CHECK_PATTERN=--dry-run"
set "CHECK_MESSAGE=install-windows.bat must support --dry-run"
call :require "%INSTALLER%"
set "CHECK_PATTERN=--no-path"
set "CHECK_MESSAGE=install-windows.bat must support --no-path"
call :require "%INSTALLER%"
set "CHECK_PATTERN=--install-dir"
set "CHECK_MESSAGE=install-windows.bat must support --install-dir"
call :require "%INSTALLER%"
set "CHECK_PATTERN=--version"
set "CHECK_MESSAGE=install-windows.bat must verify installed launchers"
call :require "%INSTALLER%"
set "CHECK_PATTERN=installed-files.txt"
set "CHECK_MESSAGE=install-windows.bat must keep an installed-files manifest"
call :require "%INSTALLER%"
set "CHECK_PATTERN=setx"
set "CHECK_MESSAGE=do not use setx to modify PATH"
call :forbid "%INSTALLER%"
set "CHECK_PATTERN=runas"
set "CHECK_MESSAGE=do not elevate privileges automatically"
call :forbid "%INSTALLER%"
set "CHECK_PATTERN=Start-Process"
set "CHECK_MESSAGE=do not launch elevated processes"
call :forbid "%INSTALLER%"
set "CHECK_PATTERN=Invoke-Expression"
set "CHECK_MESSAGE=do not evaluate remote or dynamic content"
call :forbid "%INSTALLER%"
set "CHECK_PATTERN=iex"
set "CHECK_MESSAGE=do not evaluate dynamic content"
call :forbid "%INSTALLER%"
set "CHECK_PATTERN=curl"
set "CHECK_MESSAGE=do not download arbitrary content"
call :forbid "%INSTALLER%"
set "CHECK_PATTERN=wget"
set "CHECK_MESSAGE=do not download arbitrary content"
call :forbid "%INSTALLER%"
set "CHECK_PATTERN=choco"
set "CHECK_MESSAGE=winget is the only package manager used"
call :forbid "%INSTALLER%"
set "CHECK_PATTERN=scoop"
set "CHECK_MESSAGE=winget is the only package manager used"
call :forbid "%INSTALLER%"
set "CHECK_PATTERN=wsl"
set "CHECK_MESSAGE=do not depend on WSL"
call :forbid "%INSTALLER%"
set "CHECK_PATTERN=cygwin"
set "CHECK_MESSAGE=do not depend on Cygwin"
call :forbid "%INSTALLER%"
set "CHECK_PATTERN=msys"
set "CHECK_MESSAGE=do not depend on MSYS2"
call :forbid "%INSTALLER%"
set "CHECK_PATTERN=ExecutionPolicy"
set "CHECK_MESSAGE=do not change the PowerShell execution policy"
call :forbid "%INSTALLER%"
set "CHECK_PATTERN=HKLM"
set "CHECK_MESSAGE=do not write to the system registry hive"
call :forbid "%INSTALLER%"
set "CHECK_PATTERN=HKEY_LOCAL_MACHINE"
set "CHECK_MESSAGE=do not write to the system registry hive"
call :forbid "%INSTALLER%"
set "CHECK_PATTERN=--force"
set "CHECK_MESSAGE=do not force winget reinstalls"
call :forbid "%INSTALLER%"
set "CHECK_PATTERN=find \" \""
set "CHECK_MESSAGE=do not use a pipe/echo space search; the separator space is matched"
call :forbid "%INSTALLER%"
set "CHECK_PATTERN=%%~dp0"
set "CHECK_MESSAGE=launcher.cmd must resolve its own directory"
call :require "%LAUNCHER%"
set "CHECK_PATTERN=perl-path.txt"
set "CHECK_MESSAGE=launcher.cmd must use the recorded Perl interpreter"
call :require "%LAUNCHER%"
set "CHECK_PATTERN=%%~n0.pl"
set "CHECK_MESSAGE=launcher.cmd must derive the program from its own name"
call :require "%LAUNCHER%"
set "CHECK_PATTERN=%%*"
set "CHECK_MESSAGE=launcher.cmd must forward all arguments"
call :require "%LAUNCHER%"
set "CHECK_PATTERN=exit /b %%ERRORLEVEL%%"
set "CHECK_MESSAGE=launcher.cmd must preserve the Perl exit status"
call :require "%LAUNCHER%"
set "CHECK_PATTERN=DisableDelayedExpansion"
set "CHECK_MESSAGE=launcher.cmd must not corrupt paths containing exclamation marks"
call :require "%LAUNCHER%"
set "CHECK_PATTERN=Invoke-Expression"
set "CHECK_MESSAGE=launcher.cmd must not evaluate dynamic content"
call :forbid "%LAUNCHER%"
set "CHECK_PATTERN=setx"
set "CHECK_MESSAGE=launcher.cmd must not modify PATH"
call :forbid "%LAUNCHER%"
set "CHECK_PATTERN=windows\\*.ps1"
set "CHECK_MESSAGE=installer must discover PowerShell scripts"
call :require "%INSTALLER%"
set "CHECK_PATTERN=ParseFile"
set "CHECK_MESSAGE=installer must validate PowerShell syntax without executing scripts"
call :require "%INSTALLER%"
set "CHECK_PATTERN=%%~n0.ps1"
set "CHECK_MESSAGE=PowerShell launcher must derive the script name"
call :require "%PS_LAUNCHER%"
set "CHECK_PATTERN=%%*"
set "CHECK_MESSAGE=PowerShell launcher must forward arguments"
call :require "%PS_LAUNCHER%"
set "CHECK_PATTERN=exit /b %%ERRORLEVEL%%"
set "CHECK_MESSAGE=PowerShell launcher must preserve exit status"
call :require "%PS_LAUNCHER%"
set "CHECK_PATTERN=ExecutionPolicy"
set "CHECK_MESSAGE=PowerShell launcher must respect execution policy"
call :forbid "%PS_LAUNCHER%"
set "CHECK_PATTERN=programs.txt"
set "CHECK_MESSAGE=Makefile must use perl/programs.txt as the program list"
call :require "%MAKEFILE%"

call :require_crlf "%INSTALLER%"
call :require_crlf "%LAUNCHER%"
call :require_crlf "%PS_LAUNCHER%"

rem Validate every manifest entry without executing it as shell input.
powershell.exe -NoProfile -Command "$ErrorActionPreference='Stop'; try { $lines=[IO.File]::ReadAllLines($env:MANIFEST); $count=0; $bad=$false; foreach($line in $lines) { if($line -eq '' -or $line.StartsWith('#')) { continue }; $count++; if($line -cnotmatch '^[A-Za-z0-9._-]+\.pl$') { [Console]::Error.WriteLine('[ERROR] invalid manifest entry: '+$line); $bad=$true; continue }; if(-not [IO.File]::Exists([IO.Path]::Combine($env:ROOT_DIR,'perl',$line))) { [Console]::Error.WriteLine('[ERROR] manifest lists a missing program: perl/'+$line); $bad=$true } }; if($count -eq 0) { [Console]::Error.WriteLine('[ERROR] manifest must list at least one .pl program'); $bad=$true }; if($bad) { exit 1 } } catch { [Console]::Error.WriteLine('[ERROR] '+$_.Exception.Message); exit 1 }"
if errorlevel 1 set "FAIL=1"
if "%FAIL%"=="0" echo [INFO] Windows installer checks passed
exit /b %FAIL%

:usage
echo Usage: %~nx0 [ROOT_DIR] 1>&2
exit /b 2

:require
if not exist "%~1" goto missing_file
findstr /l /c:"%CHECK_PATTERN%" "%~1" >nul 2>&1
if errorlevel 1 (
    call :check_failed
)
exit /b 0

:forbid
if not exist "%~1" goto missing_file
findstr /i /l /c:"%CHECK_PATTERN%" "%~1" >nul 2>&1
if errorlevel 2 (
    echo [ERROR] cannot read "%~1" 1>&2
    set "FAIL=1"
    exit /b 0
)
if not errorlevel 1 (
    call :check_failed
)
exit /b 0

:check_failed
setlocal EnableDelayedExpansion
echo [ERROR] !CHECK_MESSAGE! 1>&2
endlocal
set "FAIL=1"
exit /b 0

:missing_file
echo [ERROR] missing file: "%~1" 1>&2
set "FAIL=1"
exit /b 0

:require_crlf
if not exist "%~1" goto missing_file
set "CHECK_FILE=%~1"
powershell.exe -NoProfile -Command "$ErrorActionPreference='Stop'; try { $s=[IO.File]::ReadAllText($env:CHECK_FILE); if(-not $s.Contains([string][char]13+[char]10) -or $s -match '(?<!\r)\n|\r(?!\n)') { exit 1 } } catch { exit 1 }"
if errorlevel 1 (
    echo [ERROR] "%~1" must be readable and use CRLF line endings 1>&2
    set "FAIL=1"
)
exit /b 0
