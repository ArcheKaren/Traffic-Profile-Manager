param([string]$ProjectRoot, [string]$FixtureRoot)
$ErrorActionPreference = "Stop"
Add-Type -Path (Join-Path $ProjectRoot "tests\fixtures\ForegroundConsole.cs")
[TpmForegroundConsole]::EnableCtrlC()
Import-Module (Join-Path $ProjectRoot (
    "modules\TrafficProfileManager.Core\TrafficProfileManager.Core.psd1"
)) -Force
Import-Module (Join-Path $ProjectRoot 'modules/TrafficProfileManager.Maintenance/TrafficProfileManager.Maintenance.psd1') -Force
New-Item -ItemType Directory -Path (Join-Path $FixtureRoot 'config/profiles') -Force|Out-Null
[IO.File]::WriteAllText((Join-Path $FixtureRoot 'config/config.json'),'{"activeProfile":"fixture","debug":false,"autoHostlist":false,"allowAllWithoutTargets":false}')
[IO.File]::WriteAllText((Join-Path $FixtureRoot 'config/profiles/fixture.json'),'{"name":"fixture","interception":{"tcpOut":"443"},"rules":[{"name":"tls","match":["--filter-tcp=443"],"actions":["--payload=tls_client_hello"]}]}')
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
