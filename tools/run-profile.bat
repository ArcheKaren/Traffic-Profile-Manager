@echo off
setlocal EnableExtensions
cd /d "%~dp0.."
set "profile=%~1"

if not defined profile (
  echo ERROR: A profile name is required.
  pause
  exit /b 2
)

if defined TRAFFIC_PROFILE_TEST_MODE goto elevated
fltmc >nul 2>&1
if errorlevel 1 (
  set "TRAFFIC_PROFILE_ELEVATE_TARGET=%~f0"
  set "TRAFFIC_PROFILE_ELEVATE_ARGUMENT=%profile%"
  powershell.exe -NoProfile -Command "Start-Process -FilePath $env:TRAFFIC_PROFILE_ELEVATE_TARGET -ArgumentList $env:TRAFFIC_PROFILE_ELEVATE_ARGUMENT -Verb RunAs"
  exit /b
)

:elevated
title Traffic Profile - %profile%

powershell.exe -NoLogo -NoProfile -Command "if (Get-Service -Name 'TrafficProfileService' -ErrorAction SilentlyContinue) { exit 0 } else { exit 1 }"
if not errorlevel 1 (
  echo ERROR: The automatic service is installed.
  echo Remove it from Manager.bat before starting a visible profile.
  pause
  exit /b 3
)

tasklist /FI "IMAGENAME eq winws2.exe" 2>nul | find /I "winws2.exe" >nul
if not errorlevel 1 (
  echo ERROR: Another traffic profile or service is already running.
  echo Close the other profile before starting this one.
  pause
  exit /b 3
)

call "%cd%\zapretctl.cmd" stop >nul 2>&1
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%cd%\manage-network-mappings.ps1" cleanup >nul 2>&1

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%cd%\manage-network-mappings.ps1" install
if errorlevel 1 (
  echo ERROR: Could not prepare temporary network mappings.
  pause
  exit /b 4
)

echo.
echo Profile: %profile%
echo The profile remains active while this window is open.
echo Press Ctrl+C or close the window to stop it.
echo.

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%cd%\zapretctl.ps1" foreground "%profile%"
set "run_error=%errorlevel%"

call "%cd%\zapretctl.cmd" stop >nul 2>&1
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%cd%\manage-network-mappings.ps1" cleanup >nul 2>&1

echo.
if not "%run_error%"=="0" (
  echo Profile stopped with exit code %run_error%.
) else (
  echo Profile stopped.
)
pause
exit /b %run_error%
