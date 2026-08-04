$script:ProjectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

Import-Module (
    Join-Path $script:ProjectRoot `
        "modules\TrafficProfileManager.Core\TrafficProfileManager.Core.psd1"
) -ErrorAction Stop
Import-Module (
    Join-Path $script:ProjectRoot `
        "modules\TrafficProfileManager.Profile\TrafficProfileManager.Profile.psd1"
) -ErrorAction Stop

. (Join-Path $script:ProjectRoot "tools\game-filter-library.ps1")
. (Join-Path $script:ProjectRoot "tools\catalog-library.ps1")
. (Join-Path $PSScriptRoot "Private\AppState.ps1")
. (Join-Path $PSScriptRoot "Private\WinwsArguments.ps1")
. (Join-Path $PSScriptRoot "Private\RuntimeProcess.ps1")

function Invoke-DomainPackCommand([string[]]$InputArgs) {
    $action = if ($InputArgs.Count -ge 1) {
        $InputArgs[0].ToLowerInvariant()
    } else { "list" }
    if ($action -notin @("list", "enable", "disable", "rebuild", "create")) {
        throw "Usage: zapretctl pack list|enable|disable|rebuild|create [pack-id]"
    }
    $id = if ($InputArgs.Count -ge 2) { $InputArgs[1] } else { "" }
    & (Get-AppPath "tools\domain-pack-manager.ps1") `
        $action `
        $id `
        -RootPath $script:AppRoot
    if (-not $?) { throw "Domain pack command failed." }
}

function Invoke-ApplicationDiagnostics([string[]]$InputArgs) {
    Ensure-Initialized
    $parameters = @{ RootPath = $script:AppRoot }
    foreach ($argument in $InputArgs) {
        if ($argument -eq "--no-network") {
            $parameters.NoNetwork = $true
        } elseif (-not $parameters.ContainsKey("TargetId")) {
            $parameters.TargetId = $argument
        } else {
            throw "Usage: zapretctl diagnose [target-id] [--no-network]"
        }
    }
    & (Get-AppPath "tools\application-diagnostics.ps1") @parameters
    if (-not $?) { throw "Application diagnostics failed." }
}

function Show-Help {
    @"
zapretctl - local traffic profile manager

  init                                  create configuration and lists
  domain add|remove <domain>            modify the domain list
  domain exclude [add|remove] <domain>  modify domain exclusions
  domain list [--exclude]               show the list
  domain import <file> [--exclude]      import a list
  ip add|remove <IP/CIDR>               modify the IP list
  ip exclude [add|remove] <IP/CIDR>     modify IP exclusions
  ip list [--exclude]                   show the list
  ip import <file> [--exclude]          import a list
  profile list|show|use <name>          manage profiles
  pack list|enable|disable|rebuild      manage domain packs
  pack create <pack-id>                 create a custom domain pack
  diagnose [target-id] [-NoNetwork]     create local TXT and JSON reports
  runtime path <winws2.exe>             set an explicit runtime path
  start                                 start winws2
  foreground <profile>                  run in the current window
  check                                 validate parameters with --dry-run
  stop | restart | status               manage the process
  adopt                                 register an existing winws2 process
  render                                show the generated command
  doctor                                check the installation
  logs [--tail N]                       show the log

Running without domain or IP targets is disabled by default to avoid processing
all traffic accidentally. The explicitly enabled universal game transport is the
only exception and applies to its selected TCP/UDP ports. Settings are stored in
config\config.json.
"@
}

function Invoke-TpmControllerCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$AppRoot,

        [Parameter(Mandatory = $true)]
        [string]$Command,

        [string[]]$CommandArgs = @()
    )

    $script:AppRoot = [IO.Path]::GetFullPath($AppRoot)
    $commandName = $Command.ToLowerInvariant()
    switch ($commandName) {
        "help" { Show-Help }
        "--help" { Show-Help }
        "-h" { Show-Help }
        "init" { Initialize-App }
        "domain" { Invoke-ListCommand "domain" $CommandArgs }
        "ip" { Invoke-ListCommand "ip" $CommandArgs }
        "profile" { Invoke-ProfileCommand $CommandArgs }
        "pack" { Invoke-DomainPackCommand $CommandArgs }
        "diagnose" { Invoke-ApplicationDiagnostics $CommandArgs }
        "runtime" { Invoke-RuntimeCommand $CommandArgs }
        "launch-spec" {
            $profileName = if ($CommandArgs.Count) { $CommandArgs[0] } else { "" }
            Get-WinwsLaunchSpecification $profileName
        }
        "start" { Start-Zapret $false }
        "foreground" {
            if (-not $CommandArgs.Count) { throw "Specify a profile." }
            Start-ZapretForeground $CommandArgs[0]
        }
        "check" {
            $profileName = if ($CommandArgs.Count) { $CommandArgs[0] } else { "" }
            Start-Zapret $true $profileName
        }
        "stop" { Stop-Zapret }
        "restart" {
            Stop-Zapret
            Start-Zapret $false
        }
        "status" { Show-Status }
        "adopt" { Adopt-ZapretProcess }
        "render" {
            $profileName = if ($CommandArgs.Count) { $CommandArgs[0] } else { "" }
            Show-Render $profileName
        }
        "doctor" { Show-Doctor }
        "logs" { Show-Logs $CommandArgs }
        default {
            throw "Unknown command '$Command'. Run 'zapretctl help'."
        }
    }
}

Export-ModuleMember -Function "Invoke-TpmControllerCommand"
