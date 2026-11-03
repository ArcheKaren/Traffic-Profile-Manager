@echo off
setlocal EnableExtensions
cd /d "%~dp0"
if defined TRAFFIC_PROFILE_TEST_MODE goto elevated
fltmc >nul 2>&1
if errorlevel 1 (
  set "TRAFFIC_PROFILE_ELEVATE_TARGET=%~f0"
  powershell.exe -NoProfile -Command "Start-Process -FilePath $env:TRAFFIC_PROFILE_ELEVATE_TARGET -Verb RunAs"
  exit /b
)
:elevated
title Traffic Profile Manager
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\console-manager.ps1"
exit /b %errorlevel%
