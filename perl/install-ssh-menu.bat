@echo off
rem Install ssh-menu Perl script on Windows
rem Requires Perl and OpenSSH in PATH
rem See the LICENSE file at the top of the project tree for copyright
rem and license details.

setlocal enabledelayedexpansion

set "INSTALL_DIR=%USERPROFILE%\.local\bin"
set "SCRIPT_NAME=ssh-menu"
set "SOURCE=%~dp0ssh-menu.pl"

echo [INFO] Installing ssh-menu to %INSTALL_DIR%

rem Verify Perl is available
where perl >nul 2>&1
if %errorlevel% neq 0 (
    echo [ERROR] perl not found in PATH. Install Strawberry Perl or Git for Windows Perl.
    exit /b 1
)

rem Verify ssh is available
where ssh >nul 2>&1
if %errorlevel% neq 0 (
    echo [WARN] ssh not found in PATH. ssh-menu requires OpenSSH.
)

rem Create install directory
if not exist "%INSTALL_DIR%" (
    mkdir "%INSTALL_DIR%" >nul 2>&1
    if %errorlevel% neq 0 (
        echo [ERROR] Failed to create %INSTALL_DIR%
        exit /b 1
    )
)

rem Check if source script exists
if not exist "%SOURCE%" (
    echo [ERROR] Source script not found: %SOURCE%
    echo [INFO] Run this .bat from the directory containing ssh-menu.pl
    exit /b 1
)

rem Copy script (strip .pl extension, use LF endings)
copy /y "%SOURCE%" "%INSTALL_DIR%\%SCRIPT_NAME%" >nul 2>&1
if %errorlevel% neq 0 (
    echo [ERROR] Failed to copy %SOURCE% to %INSTALL_DIR%\%SCRIPT_NAME%
    exit /b 1
)

rem Ensure Perl shebang works by creating a wrapper .bat
echo @perl "%%~dp0%SCRIPT_NAME%" %%* > "%INSTALL_DIR%\%SCRIPT_NAME%.bat"
echo [INFO] Created wrapper: %INSTALL_DIR%\%SCRIPT_NAME%.bat

rem Check if install dir is already in PATH
echo %PATH% | findstr /i /c:"%INSTALL_DIR%" >nul 2>&1
if %errorlevel% neq 0 (
    echo.
    echo [WARN] %INSTALL_DIR% is not in your PATH.
    echo [INFO] Add it manually or run the following command from an elevated prompt:
    echo   setx PATH "%%PATH%%;%INSTALL_DIR%"
    echo.
    echo Alternatively, run this command from a regular prompt for current session:
    echo   set PATH=%%PATH%%;%INSTALL_DIR%
) else (
    echo [INFO] %INSTALL_DIR% is already in PATH.
)

echo.
echo [INFO] ssh-menu installed to %INSTALL_DIR%\%SCRIPT_NAME%
echo [INFO] Run it by typing: %SCRIPT_NAME%
