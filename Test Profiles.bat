@echo off
setlocal EnableExtensions
cd /d "%~dp0"
title Traffic Profile Comparison

if defined TRAFFIC_PROFILE_TEST_MODE goto elevated
fltmc >nul 2>&1
if errorlevel 1 (
  set "TRAFFIC_PROFILE_ELEVATE_TARGET=%~f0"
  powershell.exe -NoProfile -Command "Start-Process -FilePath $env:TRAFFIC_PROFILE_ELEVATE_TARGET -Verb RunAs"
  exit /b
)

:elevated
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\profile-benchmark.ps1"
set "test_error=%errorlevel%"
echo.
if not "%test_error%"=="0" echo Comparison finished with exit code %test_error%.
pause
exit /b %test_error%
