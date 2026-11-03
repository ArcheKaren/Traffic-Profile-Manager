[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Command = "help",

    [Parameter(Position = 1)]
    [string]$Arg1,

    [Parameter(Position = 2)]
    [string]$Arg2,

    [Parameter(Position = 3)]
    [string]$Arg3,

    [switch]$NoNetwork,

    [Alias("-json")]
    [switch]$Json,

    [Alias("-apply")]
    [switch]$Apply
)

$ErrorActionPreference = "Stop"
$appRoot = if ($env:ZAPRETCTL_HOME) {
    [IO.Path]::GetFullPath($env:ZAPRETCTL_HOME)
} else {
    Split-Path -Parent $MyInvocation.MyCommand.Path
}
$commandArguments = @(
    @($Arg1, $Arg2, $Arg3) |
        Where-Object { -not [string]::IsNullOrEmpty($_) }
)
if ($NoNetwork) { $commandArguments += "--no-network" }
if ($Json) { $commandArguments += "--json" }
if ($Apply) { $commandArguments += "--apply" }

try {
    Import-Module (
        Join-Path $PSScriptRoot `
            "modules\TrafficProfileManager.Controller\TrafficProfileManager.Controller.psd1"
    ) -ErrorAction Stop
    Invoke-TpmControllerCommand `
        -AppRoot $appRoot `
        -Command $Command `
        -CommandArgs $commandArguments
} catch {
    Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
