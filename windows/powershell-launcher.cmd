@echo off
rem scripts-powershell-launcher - template used by install-windows.bat.
rem Prefer PowerShell 7 when available; Windows PowerShell is the fallback.
rem See the LICENSE file at the top of the project tree for license details.
setlocal EnableExtensions DisableDelayedExpansion
where pwsh.exe >nul 2>&1
if errorlevel 1 goto windows_powershell
pwsh.exe -NoProfile -File "%~dp0..\windows\%~n0.ps1" %*
exit /b %ERRORLEVEL%
:windows_powershell
powershell.exe -NoProfile -File "%~dp0..\windows\%~n0.ps1" %*
exit /b %ERRORLEVEL%
