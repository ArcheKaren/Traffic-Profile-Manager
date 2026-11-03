param([string]$ProjectRoot, [string]$FixtureRoot)
$ErrorActionPreference = "Stop"
Import-Module (Join-Path $ProjectRoot (
    "modules\TrafficProfileManager.Core\TrafficProfileManager.Core.psd1"
)) -Force
. (Join-Path $ProjectRoot "modules\TrafficProfileManager.Controller\Private\AppState.ps1")
. (Join-Path $ProjectRoot "modules\TrafficProfileManager.Controller\Private\RuntimeProcess.ps1")
$script:AppRoot = $FixtureRoot
Import-Module (Join-Path $ProjectRoot "modules\TrafficProfileManager.Console\TrafficProfileManager.Console.psd1") -Force
Set-TpmUiRoot $FixtureRoot

# Replace only runtime/configuration boundaries; exercise the real foreground lifecycle.
function Ensure-Initialized {}
function Test-TpmIsAdministrator { return $true }
function Get-RunningPid { return $null }
function Find-RuntimeExecutable { return (Get-Command powershell.exe).Source }
function Find-RuntimeFile { return "fixture" }
function Build-WinwsArguments {
    return @("-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
        (Join-Path $FixtureRoot "worker.ps1"))
}
try {
    Start-ZapretForeground "fixture"
} catch {
    [IO.File]::WriteAllText((Join-Path $FixtureRoot "controller-error.txt"), $_.ToString())
    exit 7
}
