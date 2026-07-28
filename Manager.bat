@echo off
setlocal EnableExtensions EnableDelayedExpansion
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

:menu
cls
echo ==========================================================
echo                  Traffic Profile Manager
echo ==========================================================
echo.
echo [1] Run a profile in a visible window
echo [2] Install a profile as an automatic service
echo [3] Remove the automatic service
echo [4] Show status
echo.
echo [5] Edit custom target lists
echo [6] Edit custom exclusion lists
echo [7] Test and compare profiles
echo [8] Validate profile files
echo [9] Background component controls
echo [10] Edit a traffic profile
echo [11] Create a custom profile
echo [12] Open the profile folder
echo.
echo [0] Exit
echo.
set "menu_choice="
set /p "menu_choice=Select an option: "

if "%menu_choice%"=="1" goto run_profile
if "%menu_choice%"=="2" goto install_service
if "%menu_choice%"=="3" goto remove_service
if "%menu_choice%"=="4" goto show_status
if "%menu_choice%"=="5" goto edit_targets
if "%menu_choice%"=="6" goto edit_exclusions
if "%menu_choice%"=="7" goto test_profiles
if "%menu_choice%"=="8" goto validate_profiles
if "%menu_choice%"=="9" goto background_controls
if "%menu_choice%"=="10" goto edit_profile
if "%menu_choice%"=="11" goto create_profile
if "%menu_choice%"=="12" goto open_profiles
if "%menu_choice%"=="0" exit /b
goto menu

:run_profile
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\profile-manager.ps1" run
goto menu

:install_service
cls
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\profile-manager.ps1" install
echo.
pause
goto menu

:remove_service
cls
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\service-control.ps1" remove
echo.
pause
goto menu

:show_status
cls
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\service-control.ps1" status
echo.
pause
goto menu

:edit_targets
cls
echo [1] Custom domains
echo [2] Custom IP addresses and CIDR ranges
echo [0] Back
echo.
set "list_choice="
set /p "list_choice=Select a list: "
if "%list_choice%"=="1" start "" notepad.exe "%~dp0lists\user-domains.txt"
if "%list_choice%"=="2" start "" notepad.exe "%~dp0lists\user-ips.txt"
goto menu

:edit_exclusions
cls
echo [1] Custom domain exclusions
echo [2] Custom IP/CIDR exclusions
echo [0] Back
echo.
set "list_choice="
set /p "list_choice=Select a list: "
if "%list_choice%"=="1" start "" notepad.exe "%~dp0lists\user-domains-exclude.txt"
if "%list_choice%"=="2" start "" notepad.exe "%~dp0lists\user-ips-exclude.txt"
goto menu

:test_profiles
start "" "%~dp0Test Profiles.bat"
goto menu

:validate_profiles
call "%~dp0Validate Profiles.bat"
goto menu

:edit_profile
cls
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\profile-manager.ps1" edit
goto menu

:create_profile
cls
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\profile-manager.ps1" create
echo.
pause
goto menu

:open_profiles
start "" explorer.exe "%~dp0config\profiles"
goto menu

:background_controls
cls
echo ==========================================================
echo                Background Component Controls
echo ==========================================================
echo.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\service-control.ps1" status
echo.
echo [1] Start the installed service now
echo [2] Stop the service for this Windows session
echo [3] Turn startup mapping refresh ON
echo [4] Turn startup mapping refresh OFF and remove its task
echo [5] Refresh temporary mappings now
echo [6] Clean temporary mappings while stopped
echo [0] Back
echo.
set "background_choice="
set /p "background_choice=Select an option: "
set "background_action="
if "%background_choice%"=="1" set "background_action=start"
if "%background_choice%"=="2" set "background_action=stop"
if "%background_choice%"=="3" set "background_action=task-on"
if "%background_choice%"=="4" set "background_action=task-off"
if "%background_choice%"=="5" set "background_action=refresh"
if "%background_choice%"=="6" set "background_action=cleanup"
if "%background_choice%"=="0" goto menu
if not defined background_action goto background_controls
echo.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\service-control.ps1" "!background_action!"
echo.
pause
goto background_controls
