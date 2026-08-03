@echo off
setlocal EnableExtensions
set "tpm_command=%~1"
if not defined tpm_command (
  powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0zapretctl.ps1" help
) else (
  powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0zapretctl.ps1" "%~1" "%~2" "%~3" "%~4"
)
exit /b %errorlevel%
