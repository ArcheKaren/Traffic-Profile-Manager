@echo off
setlocal EnableExtensions
cd /d "%~dp0.."
set "TRAFFIC_PROFILE_SETUP_ID=%~1"
if not defined TRAFFIC_PROFILE_SETUP_ID (
  echo Usage: tools\run-setup.bat setup-id
  exit /b 2
)
powershell.exe -NoLogo -NoProfile -Command "if ($env:TRAFFIC_PROFILE_SETUP_ID -cnotmatch '^[a-z0-9][a-z0-9_-]{0,63}$') { exit 2 }"
if errorlevel 1 exit /b 2
if defined TRAFFIC_PROFILE_TEST_MODE goto elevated
fltmc >nul 2>&1
if errorlevel 1 (
  set "TRAFFIC_PROFILE_ELEVATE_TARGET=%~f0"
  powershell.exe -NoLogo -NoProfile -Command "Start-Process -FilePath $env:TRAFFIC_PROFILE_ELEVATE_TARGET -ArgumentList $env:TRAFFIC_PROFILE_SETUP_ID -Verb RunAs"
  exit /b
)
:elevated
title Traffic Profile - %TRAFFIC_PROFILE_SETUP_ID%
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\zapretctl.ps1" setup run "%TRAFFIC_PROFILE_SETUP_ID%"
set "setup_error=%errorlevel%"
if not "%setup_error%"=="0" pause
exit /b %setup_error%
