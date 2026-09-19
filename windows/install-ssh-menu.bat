@echo off
rem Install ssh-menu Perl script on Windows
setlocal

set "SCRIPT_DIR=%~dp0"
set "SOURCE=%SCRIPT_DIR%..\perl\ssh-menu.pl"
set "DEST=%USERPROFILE%\bin\ssh-menu.pl"

if not exist "%USERPROFILE%\bin" mkdir "%USERPROFILE%\bin"
copy /Y "%SOURCE%" "%DEST%"
echo Installed ssh-menu.pl to "%DEST%"
