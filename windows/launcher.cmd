@echo off
rem launcher.cmd - internal template copied by install-windows.bat.
rem Do not run this template directly. Each installed copy is named
rem <program>.cmd and runs perl\<program>.pl with the Perl interpreter
rem recorded and checked at install time.
rem
rem See the LICENSE file at the top of the project tree for copyright
rem and license details.
setlocal EnableExtensions DisableDelayedExpansion
set "NF_ROOT=%~dp0.."
set "PERL="
for /f "usebackq delims=" %%P in ("%NF_ROOT%\perl-path.txt") do set "PERL=%%P"
if not defined PERL goto no_perl
if not "%PERL:~1,2%"==":\" goto no_perl
for %%I in ("%PERL%") do if /i not "%%~nxI"=="perl.exe" goto no_perl
if not exist "%PERL%" goto no_perl
rem A launcher named foo.cmd runs perl\foo.pl.
"%PERL%" "%NF_ROOT%\perl\%~n0.pl" %*
rem Return the Perl program's exit status unchanged.
exit /b %ERRORLEVEL%
:no_perl
echo [ERROR] The recorded Perl interpreter is unavailable. Reinstall with a trusted Perl on PATH. 1>&2
exit /b 2
