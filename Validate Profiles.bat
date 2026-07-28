@echo off
setlocal
cd /d "%~dp0"
fltmc >nul 2>&1
if errorlevel 1 (
  set "TRAFFIC_PROFILE_ELEVATE_TARGET=%~f0"
  powershell.exe -NoProfile -Command "Start-Process -FilePath $env:TRAFFIC_PROFILE_ELEVATE_TARGET -Verb RunAs"
  exit /b
)
title Traffic Profile Validation
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\validate-profiles.ps1"
echo.
pause
