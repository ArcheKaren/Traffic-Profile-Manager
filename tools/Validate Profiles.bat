@echo off
setlocal EnableExtensions
cd /d "%~dp0.."
title Traffic Profile Validation
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0validate-profiles.ps1"
set "validation_error=%errorlevel%"
echo.
pause
exit /b %validation_error%
