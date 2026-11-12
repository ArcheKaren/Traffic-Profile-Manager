Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'TrafficProfileManager.Maintenance/TrafficProfileManager.Maintenance.psd1') -ErrorAction Stop
$script:ProjectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $script:ProjectRoot 'modules\TrafficProfileManager.Console\TrafficProfileManager.Console.psd1') -ErrorAction Stop

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
  version [--json]                       show version and build identity
  language [en|ru]                       choose the console language
  overview | advice                     show status and recommended actions
  backup create|preview|restore          save or restore user settings
  update check|download|preview|apply     check and install verified updates
  update rollback <transaction-id>       roll back a file operation
  results list|use <profile-id>           inspect saved comparisons
  setup list|create|save|show|preview|use|run [id]
                                        manage named JSON/TXT setups
  configuration status|apply             inspect pending changes; apply to service
  build-profile preview|create <recipe>  construct a new validated JSON profile
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
    Set-TpmUiRoot $script:AppRoot
    $commandName = $Command.ToLowerInvariant()
    switch ($commandName) {
        { $_ -in @('setup','configuration','build-profile') } {
            if ($commandName -eq 'setup' -and (-not $CommandArgs.Count -or $CommandArgs[0] -notin @('preview','show'))) { Ensure-Initialized }
            & (Join-Path $script:ProjectRoot 'tools/workflows.ps1') -Command $commandName -Arguments $CommandArgs -RootPath $script:AppRoot
        }
        { $_ -in @('overview','advice','language','backup','update','results') } {
            & (Join-Path $script:ProjectRoot 'tools\maintenance.ps1') -Action $commandName -Arguments $CommandArgs -RootPath $script:AppRoot
        }

        "help" { Show-Help }
        "--help" { Show-Help }
        "-h" { Show-Help }
        "version" {
            if ($CommandArgs.Count -gt 1 -or (
                $CommandArgs.Count -eq 1 -and $CommandArgs[0] -ne "--json"
            )) { throw "Usage: zapretctl version [--json]" }
            $build = Get-TpmBuildInfo -AppRoot $script:AppRoot
            if ($CommandArgs -contains "--json") {
                $build | ConvertTo-Json
            } else {
                "Traffic Profile Manager $($build.version)"
                "Commit: $(if ($build.commit) { $build.commit } else { 'unknown' })"
                $changes = if ($null -eq $build.localChanges) { "unknown" } elseif (
                    $build.localChanges
                ) { "yes" } else { "no" }
                "Source changes: $changes"
                "Build metadata: $($build.source)"
                if ($build.contentSha256) { "Build content SHA-256: $($build.contentSha256)" }
            }
        }
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
