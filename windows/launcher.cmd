@echo off
rem launcher.cmd - internal template copied by install-windows.bat.
rem Do not run this template directly. Each installed copy is named
rem <program>.cmd and runs perl\<program>.pl with the Perl interpreter
rem recorded at install time (falling back to perl from PATH).
rem
rem See the LICENSE file at the top of the project tree for copyright
rem and license details.
setlocal EnableExtensions DisableDelayedExpansion
set "NF_ROOT=%~dp0.."
set "PERL="
for /f "usebackq delims=" %%P in ("%NF_ROOT%\perl-path.txt") do set "PERL=%%P"
if not defined PERL set "PERL=perl"
if not exist "%PERL%" set "PERL=perl"
"%PERL%" "%NF_ROOT%\perl\%~n0.pl" %*
exit /b %ERRORLEVEL%
