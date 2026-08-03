[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet("manage", "list", "enable", "disable", "rebuild")]
    [string]$Action = "manage",

    [Parameter(Position = 1)]
    [string]$PackId = "",

    [string]$RootPath = ""
)

$ErrorActionPreference = "Stop"
$appRoot = if ($RootPath) {
    [IO.Path]::GetFullPath($RootPath)
} else {
    Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
}
. (Join-Path $PSScriptRoot "catalog-library.ps1")

function Get-PackContext {
    $catalog = Get-TargetCatalog $appRoot
    if ($null -eq $catalog) { throw "lists\catalog.json was not found." }
    $state = Get-DomainPackState $appRoot $catalog
    return [pscustomobject]@{ Catalog = $catalog; State = $state }
}

function Set-PackEnabled([string]$Id, [bool]$Enabled) {
    $context = Get-PackContext
    $pack = @($context.Catalog.packs | Where-Object id -eq $Id) | Select-Object -First 1
    if ($null -eq $pack) { throw "Unknown domain pack '$Id'." }
    if ($Enabled) { [void]$context.State.Enabled.Add($Id) }
    else { [void]$context.State.Enabled.Remove($Id) }
    Save-DomainPackState $appRoot $context.Catalog $context.State
    $result = Sync-DomainCatalog $appRoot
    Write-Host "Domain pack '$Id': $(if ($Enabled) { 'enabled' } else { 'disabled' })." -ForegroundColor Green
    Write-Host "Compiled domains: $($result.DomainCount). Restart the active profile to apply the change."
}

function Show-Packs {
    $context = Get-PackContext
    foreach ($pack in @($context.Catalog.packs)) {
        [pscustomobject]@{
            Id = [string]$pack.id
            Enabled = $context.State.Enabled.Contains([string]$pack.id)
            DisplayName = [string]$pack.displayName
            Description = [string]$pack.description
        }
    }
}

function Show-Manager {
    while ($true) {
        Clear-Host
        Write-Host "=========================================================="
        Write-Host "                       Domain Packs"
        Write-Host "=========================================================="
        Write-Host ""
        $packs = @(Show-Packs)
        for ($index = 0; $index -lt $packs.Count; $index++) {
            $marker = if ($packs[$index].Enabled) { "ON " } else { "OFF" }
            Write-Host ("[{0}] [{1}] {2}" -f ($index + 1), $marker, $packs[$index].DisplayName)
            Write-Host ("        {0}" -f $packs[$index].Id) -ForegroundColor DarkGray
        }
        Write-Host ""
        Write-Host "Select a pack number to toggle it."
        Write-Host "[R] Rebuild lists\domains.txt"
        Write-Host "[0] Back"
        Write-Host ""
        $choice = (Read-Host "Select an option").Trim()
        if ($choice -eq "0") { return }
        if ($choice -match "^[Rr]$") {
            $result = Sync-DomainCatalog $appRoot
            Write-Host "Compiled domains: $($result.DomainCount)." -ForegroundColor Green
            Read-Host "Press Enter to continue" | Out-Null
            continue
        }
        $number = 0
        if ([int]::TryParse($choice, [ref]$number) -and $number -ge 1 -and $number -le $packs.Count) {
            $pack = $packs[$number - 1]
            Set-PackEnabled $pack.Id (-not $pack.Enabled)
            Read-Host "Press Enter to continue" | Out-Null
        }
    }
}

switch ($Action) {
    "manage" { Show-Manager }
    "list" { Show-Packs }
    "enable" { if (-not $PackId) { throw "Specify a pack ID." }; Set-PackEnabled $PackId $true }
    "disable" { if (-not $PackId) { throw "Specify a pack ID." }; Set-PackEnabled $PackId $false }
    "rebuild" {
        $result = Sync-DomainCatalog $appRoot
        Write-Output "Catalog revision: $($result.Catalog.revision)"
        Write-Output "Enabled packs: $($result.EnabledPackCount)"
        Write-Output "Compiled domains: $($result.DomainCount)"
    }
}
