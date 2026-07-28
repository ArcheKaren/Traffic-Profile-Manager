[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet("run", "install", "edit", "create", "list")]
    [string]$Action,

    [switch]$NoEditor,
    [string]$BaseProfile = "",
    [string]$ProfileId = "",
    [string]$ProfileDisplayName = ""
)

$ErrorActionPreference = "Stop"
$appRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$profileRoot = Join-Path $appRoot "config\profiles"
$utf8NoBom = New-Object Text.UTF8Encoding($false)

. (Join-Path $appRoot "tools\profile-library.ps1")

function Show-InvalidProfiles {
    param([object[]]$Profiles)

    $invalid = @($Profiles | Where-Object { -not $_.Valid })
    if ($invalid.Count -eq 0) { return }
    Write-Host ""
    Write-Host "Invalid profile files:" -ForegroundColor Red
    foreach ($profile in $invalid) {
        Write-Host "  $($profile.Id): $($profile.Error)" -ForegroundColor Red
    }
}

function Select-TrafficProfile {
    param(
        [string]$Prompt,
        [switch]$AllowInvalid
    )

    $allProfiles = @(Get-TrafficProfiles $appRoot -IncludeInvalid)
    Show-InvalidProfiles $allProfiles
    $profiles = if ($AllowInvalid) {
        $allProfiles
    } else {
        @($allProfiles | Where-Object Valid)
    }
    if ($profiles.Count -eq 0) {
        throw "No suitable profile files were found in $profileRoot."
    }

    Write-Host ""
    Write-Host $Prompt -ForegroundColor Cyan
    Write-Host ""
    for ($index = 0; $index -lt $profiles.Count; $index++) {
        $profile = $profiles[$index]
        $suffix = if ($profile.Valid) { "" } else { " [INVALID]" }
        Write-Host ("[{0}] {1}{2}" -f ($index + 1), $profile.DisplayName, $suffix)
        Write-Host "    $($profile.Id)" -ForegroundColor DarkGray
    }
    Write-Host "[0] Cancel"
    Write-Host ""

    $choiceText = Read-Host "Select a profile"
    $choice = 0
    if (-not [int]::TryParse($choiceText, [ref]$choice)) {
        return $null
    }
    if ($choice -eq 0) { return $null }
    if ($choice -lt 1 -or $choice -gt $profiles.Count) {
        return $null
    }
    return $profiles[$choice - 1]
}

function Open-ProfileEditor([string]$Path) {
    if ($NoEditor) { return }
    Start-Process `
        -FilePath "notepad.exe" `
        -ArgumentList @('"{0}"' -f $Path) `
        -Wait
}

function New-CustomProfile {
    $selectedBase = $null
    if ($BaseProfile) {
        $selectedBase = @(
            Get-TrafficProfiles $appRoot |
                Where-Object Id -eq $BaseProfile
        ) | Select-Object -First 1
        if (-not $selectedBase) {
            throw "Base profile '$BaseProfile' was not found or is invalid."
        }
    } else {
        $selectedBase = Select-TrafficProfile "Select a profile to copy"
    }
    if (-not $selectedBase) { return }

    Write-Host ""
    $id = if ($ProfileId) {
        $ProfileId.Trim().ToLowerInvariant()
    } else {
        (Read-Host "New profile ID, for example my-network").Trim().ToLowerInvariant()
    }
    if ($id -notmatch "^[a-z0-9][a-z0-9_-]{0,63}$") {
        throw "Use 1-64 lowercase letters, numbers, '-' or '_'."
    }
    $path = Join-Path $profileRoot "$id.json"
    if (Test-Path -LiteralPath $path) {
        throw "A profile named '$id' already exists."
    }

    $displayName = if ($ProfileDisplayName) {
        $ProfileDisplayName.Trim()
    } else {
        (Read-Host "Display name").Trim()
    }
    if (-not $displayName) { $displayName = $id }

    $profile = Get-Content -Raw -LiteralPath $selectedBase.Path |
        ConvertFrom-Json
    $profile.name = $id
    if ($profile.PSObject.Properties.Name -contains "displayName") {
        $profile.displayName = $displayName
    } else {
        $profile | Add-Member -NotePropertyName displayName -NotePropertyValue $displayName
    }
    $existing = @(Get-TrafficProfiles $appRoot)
    $maximumOrder = 0
    foreach ($item in $existing) {
        if ($item.Order -lt 10000 -and $item.Order -gt $maximumOrder) {
            $maximumOrder = $item.Order
        }
    }
    $newOrder = $maximumOrder + 1
    if ($profile.PSObject.Properties.Name -contains "order") {
        $profile.order = $newOrder
    } else {
        $profile | Add-Member -NotePropertyName order -NotePropertyValue $newOrder
    }
    $profile.description = "Custom profile based on $($selectedBase.Id)."

    [IO.File]::WriteAllText(
        $path,
        ($profile | ConvertTo-Json -Depth 20) + [Environment]::NewLine,
        $utf8NoBom
    )
    Write-Host ""
    Write-Host "Created: $path" -ForegroundColor Green
    Write-Host "The manager and tests will detect it automatically."
    Open-ProfileEditor $path
}

switch ($Action) {
    "run" {
        $profile = Select-TrafficProfile "Run a traffic profile"
        if ($profile) {
            & (Join-Path $appRoot "tools\run-profile.bat") $profile.Id
        }
    }
    "install" {
        $profile = Select-TrafficProfile "Install a traffic profile as a service"
        if ($profile) {
            & (Join-Path $appRoot "tools\service-control.ps1") install $profile.Id
        }
    }
    "edit" {
        $profile = Select-TrafficProfile `
            "Edit a traffic profile" `
            -AllowInvalid
        if ($profile) {
            Open-ProfileEditor $profile.Path
        }
    }
    "create" {
        New-CustomProfile
    }
    "list" {
        $profiles = @(Get-TrafficProfiles $appRoot -IncludeInvalid)
        foreach ($profile in $profiles) {
            [pscustomobject]@{
                Number = $profile.Number
                Id = $profile.Id
                DisplayName = $profile.DisplayName
                Valid = $profile.Valid
                Error = $profile.Error
            }
        }
    }
}
