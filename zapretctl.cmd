@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0zapretctl.ps1" %*
exit /b %errorlevel%
