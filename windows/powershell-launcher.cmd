@echo off
rem scripts-powershell-launcher - template used by install-windows.bat.
rem Prefer PowerShell 7 installed under Program Files.
rem See the LICENSE file at the top of the project tree for license details.
setlocal EnableExtensions DisableDelayedExpansion
rem The launcher name selects the matching .ps1 file under windows.
set "PS7=%ProgramFiles%\PowerShell\7\pwsh.exe"
if not exist "%PS7%" goto windows_powershell
"%PS7%" -NoProfile -File "%~dp0..\windows\%~n0.ps1" %*
exit /b %ERRORLEVEL%
:windows_powershell
rem Use the Windows-provided executable via its system directory.
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -File "%~dp0..\windows\%~n0.ps1" %*
exit /b %ERRORLEVEL%
