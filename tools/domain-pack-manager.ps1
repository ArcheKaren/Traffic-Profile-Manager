[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet("manage", "list", "enable", "disable", "rebuild", "create")]
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

function New-UserDomainPack(
    [string]$Id,
    [string]$DisplayName = ""
) {
    if ($Id -notmatch "^[a-z0-9][a-z0-9-]{0,63}$") {
        throw "Pack ID must use lowercase letters, digits, and hyphens."
    }
    $context = Get-PackContext
    if (@($context.Catalog.packs | Where-Object id -eq $Id).Count -ne 0) {
        throw "Pack ID is already used: $Id"
    }
    $root = [IO.Path]::GetFullPath(
        (Join-Path $appRoot "lists\user-packs")
    ).TrimEnd("\")
    if (Test-Path -LiteralPath $root) {
        $rootItem = Get-Item -LiteralPath $root -Force
        if (
            -not $rootItem.PSIsContainer -or
            $rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint
        ) {
            throw "The user pack root must be a regular directory."
        }
    }
    $target = [IO.Path]::GetFullPath((Join-Path $root $Id))
    if (-not $target.StartsWith(
        $root + "\",
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw "Unsafe user pack path."
    }
    if (Test-Path -LiteralPath $target) {
        throw "User pack directory already exists: $Id"
    }
    $name = if ([string]::IsNullOrWhiteSpace($DisplayName)) {
        $Id
    } else {
        $DisplayName.Trim()
    }
    try {
        New-Item -ItemType Directory -Path $target -Force | Out-Null
        $definition = [ordered]@{
            schemaVersion = 1
            id = $Id
            displayName = $name
            description = "Custom domain pack."
            enabledByDefault = $false
        }
        [IO.File]::WriteAllText(
            (Join-Path $target "pack.json"),
            ($definition | ConvertTo-Json -Depth 5) + [Environment]::NewLine,
            [Text.UTF8Encoding]::new($false)
        )
        [IO.File]::WriteAllText(
            (Join-Path $target "domains.txt"),
            "# Add one domain per line." + [Environment]::NewLine +
                "# example.org" + [Environment]::NewLine,
            [Text.UTF8Encoding]::new($false)
        )
        [void](Sync-DomainCatalog $appRoot)
    } catch {
        if (Test-Path -LiteralPath $target -PathType Container) {
            foreach ($fileName in @("pack.json", "domains.txt")) {
                $createdFile = Join-Path $target $fileName
                if (Test-Path -LiteralPath $createdFile -PathType Leaf) {
                    Remove-Item -LiteralPath $createdFile -Force -ErrorAction SilentlyContinue
                }
            }
            Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
        }
        throw
    }
    Write-Host "User domain pack created: $Id" -ForegroundColor Green
    Write-Host "Edit: $(Join-Path $target 'domains.txt')"
    return $target
}

function Show-Packs([switch]$IncludeWarnings) {
    $context = Get-PackContext
    if ($IncludeWarnings) {
        foreach ($warning in @(Get-DomainPackWarnings)) {
            Write-Warning $warning
        }
    }
    foreach ($pack in @($context.Catalog.packs)) {
        [pscustomobject]@{
            Id = [string]$pack.id
            Enabled = $context.State.Enabled.Contains([string]$pack.id)
            DisplayName = [string]$pack.displayName
            Description = [string]$pack.description
            UserDefined = [bool]$pack.userDefined
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
        $warnings = @(Get-DomainPackWarnings)
        foreach ($warning in $warnings) {
            Write-Host "[INVALID] $warning" -ForegroundColor Red
        }
        if ($warnings.Count) { Write-Host "" }
        for ($index = 0; $index -lt $packs.Count; $index++) {
            $marker = if ($packs[$index].Enabled) { "ON " } else { "OFF" }
            $kind = if ($packs[$index].UserDefined) { "CUSTOM" } else { "BUILT-IN" }
            Write-Host ("[{0}] [{1}] [{2}] {3}" -f @(
                $index + 1,
                $marker,
                $kind,
                $packs[$index].DisplayName
            ))
            Write-Host ("        {0}" -f $packs[$index].Id) -ForegroundColor DarkGray
        }
        Write-Host ""
        Write-Host "Select a pack number to toggle it."
        Write-Host "[C] Create a custom pack"
        Write-Host "[O] Open the custom pack folder"
        Write-Host "[R] Rebuild lists\domains.txt"
        Write-Host "[0] Back"
        Write-Host ""
        $choice = (Read-Host "Select an option").Trim()
        if ($choice -eq "0") { return }
        if ($choice -match "^[Cc]$") {
            $id = (Read-Host "Pack ID (lowercase letters, digits, hyphens)").Trim()
            $displayName = (Read-Host "Display name").Trim()
            $createdPath = New-UserDomainPack $id $displayName
            Start-Process notepad.exe -ArgumentList @(
                (Join-Path $createdPath "domains.txt")
            )
            Read-Host "Press Enter to continue" | Out-Null
            continue
        }
        if ($choice -match "^[Oo]$") {
            $userPackRoot = Join-Path $appRoot "lists\user-packs"
            New-Item -ItemType Directory -Path $userPackRoot -Force | Out-Null
            Start-Process explorer.exe -ArgumentList @($userPackRoot)
            continue
        }
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
    "list" { Show-Packs -IncludeWarnings }
    "enable" { if (-not $PackId) { throw "Specify a pack ID." }; Set-PackEnabled $PackId $true }
    "disable" { if (-not $PackId) { throw "Specify a pack ID." }; Set-PackEnabled $PackId $false }
    "create" {
        if (-not $PackId) { throw "Specify a pack ID." }
        [void](New-UserDomainPack $PackId)
    }
    "rebuild" {
        $result = Sync-DomainCatalog $appRoot
        Write-Output "Catalog revision: $($result.Catalog.revision)"
        Write-Output "Enabled packs: $($result.EnabledPackCount)"
        Write-Output "Compiled domains: $($result.DomainCount)"
    }
}
