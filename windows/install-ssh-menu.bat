@echo off
rem Install the portable ssh-menu Perl script on Windows.
rem The Perl source is kept in ..\perl and copied to %USERPROFILE%\bin.
rem
rem See the LICENSE file at the top of the project tree for copyright
rem and license details.

setlocal

set "SCRIPT_DIR=%~dp0"
set "SOURCE=%SCRIPT_DIR%..\perl\ssh-menu.pl"
set "DEST=%USERPROFILE%\bin\ssh-menu.pl"

if not exist "%USERPROFILE%\bin" mkdir "%USERPROFILE%\bin"
copy /Y "%SOURCE%" "%DEST%" >nul
if errorlevel 1 (
    echo [ERROR] Could not copy ssh-menu.pl to "%DEST%" 1>&2
    exit /b 1
)
echo [INFO] Installed ssh-menu.pl to "%DEST%"
