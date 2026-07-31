[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet(
        "manage",
        "list",
        "enable",
        "disable",
        "create",
        "transport",
        "validate",
        "open"
    )]
    [string]$Action = "manage",

    [Parameter(Position = 1)]
    [string]$FilterId = "",

    [string]$DisplayName = "",

    [string]$TransportMode = "",

    [string]$TransportPreset = "",

    [string]$TcpPorts = "",

    [string]$UdpPorts = "",

    [string]$UdpFake = "",

    [string]$RootPath = ""
)

$ErrorActionPreference = "Stop"
$appRoot = if ($RootPath) {
    [IO.Path]::GetFullPath($RootPath)
} else {
    Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
}
$filterRoot = Join-Path $appRoot "config\game-filters"
$utf8NoBom = New-Object Text.UTF8Encoding($false)

. (Join-Path $PSScriptRoot "game-filter-library.ps1")

function Write-AtomicLines([string]$Path, [string[]]$Lines) {
    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $temporary = "$Path.$PID.tmp"
    [IO.File]::WriteAllLines($temporary, $Lines, $utf8NoBom)
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function Save-EnabledIds([string[]]$Ids) {
    $normalized = @(
        $Ids |
            ForEach-Object { $_.Trim().ToLowerInvariant() } |
            Where-Object { $_ } |
            Sort-Object -Unique
    )
    Write-AtomicLines (Get-GameFilterStatePath $appRoot) $normalized
}

function Write-AtomicJson([string]$Path, [object]$Value) {
    $text = ($Value | ConvertTo-Json -Depth 10) + [Environment]::NewLine
    $temporary = "$Path.$PID.tmp"
    [IO.File]::WriteAllText($temporary, $text, $utf8NoBom)
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function Update-RunningMappings {
    $managedRuntimeActive = $false
    $pidPath = Join-Path $appRoot "state\winws2.windows.pid"
    if (Test-Path -LiteralPath $pidPath -PathType Leaf) {
        $runtimePid = 0
        $runtimePidText = [string](
            Get-Content -Raw -LiteralPath $pidPath
        )
        if (
            [int]::TryParse(
                $runtimePidText,
                [ref]$runtimePid
            ) -and
            $runtimePid -gt 0
        ) {
            $managedRuntimeActive = [bool](
                Get-Process -Id $runtimePid -ErrorAction SilentlyContinue |
                    Where-Object ProcessName -eq "winws2"
            )
        }
    }
    $service = Get-Service `
        -Name "TrafficProfileService" `
        -ErrorAction SilentlyContinue
    if ($service -and $service.Status -eq "Running") {
        $managedRuntimeActive = $true
    }
    if (-not $managedRuntimeActive) {
        Write-Host "The change will take effect on the next profile start." `
            -ForegroundColor DarkGray
        return
    }
    try {
        if ($service -and $service.Status -eq "Running") {
            & (Join-Path $PSScriptRoot "service-control.ps1") refresh |
                Out-Host
        } else {
            & (Join-Path $PSScriptRoot "..\manage-network-mappings.ps1") `
                refresh `
                -AppRoot $appRoot |
                Out-Host
        }
        Write-Host "Running mappings refreshed." -ForegroundColor Green
        Write-Host (
            "Restart the active profile or service to apply domain, IP and " +
            "transport changes."
        ) -ForegroundColor Yellow
    } catch {
        Write-Warning (
            "The selection was saved, but running mappings could not be " +
            "refreshed: $($_.Exception.Message)"
        )
    }
}

function Set-GameFilterTransport([string]$Id) {
    $id = $Id.Trim().ToLowerInvariant()
    if ($id -notmatch "^[a-z0-9][a-z0-9_-]{0,63}$") {
        throw "Invalid game filter ID: $Id"
    }
    $filter = @(
        Get-GameFilters $appRoot -IncludeInvalid |
            Where-Object Id -eq $id
    ) | Select-Object -First 1
    if (-not $filter) { throw "Game filter '$id' was not found." }
    if (-not (Test-Path -LiteralPath $filter.ManifestPath -PathType Leaf)) {
        throw "filter.json was not found for '$id'."
    }

    $manifest = Get-Content -Raw -LiteralPath $filter.ManifestPath |
        ConvertFrom-Json
    $current = if ($filter.Valid) {
        $filter.Transport
    } else {
        [pscustomobject]@{
            Mode = "off"
            Preset = "balanced"
            TcpPorts = "1024-65535"
            UdpPorts = "1024-65535"
            UdpFake = "assets\ACTIVE_GAME_UDP.bin"
        }
    }

    $mode = $TransportMode.Trim().ToLowerInvariant()
    if (-not $mode) {
        Write-Host ""
        Write-Host "Select transport mode:"
        Write-Host "  0. Off"
        Write-Host "  1. TCP and UDP"
        Write-Host "  2. TCP only"
        Write-Host "  3. UDP only"
        $modeChoice = (Read-Host "Mode (0-3, current: $($current.Mode))").Trim()
        $mode = switch ($modeChoice) {
            "" { $current.Mode }
            "0" { "off" }
            "1" { "all" }
            "2" { "tcp" }
            "3" { "udp" }
            default { throw "Select a mode from 0 to 3." }
        }
    }
    if ($mode -notin @("off", "tcp", "udp", "all")) {
        throw "Transport mode must be off, tcp, udp or all."
    }

    $preset = $TransportPreset.Trim().ToLowerInvariant()
    if (-not $preset) {
        if ($mode -eq "off") {
            $preset = if ($current.Preset) {
                $current.Preset
            } else { "balanced" }
        } else {
            $presetChoice = (
                Read-Host "Preset: 1=Balanced, 2=Extended (current: $($current.Preset))"
            ).Trim()
            $preset = switch ($presetChoice) {
                "" { $current.Preset }
                "1" { "balanced" }
                "2" { "extended" }
                default { throw "Select preset 1 or 2." }
            }
        }
    }

    $defaultTcp = if ($current.TcpPorts) {
        $current.TcpPorts
    } else { "1024-65535" }
    $tcp = $TcpPorts.Trim()
    if (-not $tcp) {
        $tcp = $defaultTcp
    }
    if ($mode -in @("tcp", "all") -and -not $TcpPorts.Trim()) {
        $tcp = (Read-Host "TCP ports (default: $defaultTcp)").Trim()
        if (-not $tcp) { $tcp = $defaultTcp }
    }
    $defaultUdp = if ($current.UdpPorts) {
        $current.UdpPorts
    } else { "1024-65535" }
    $udp = $UdpPorts.Trim()
    if (-not $udp) {
        $udp = $defaultUdp
    }
    if ($mode -in @("udp", "all") -and -not $UdpPorts.Trim()) {
        $udp = (Read-Host "UDP ports (default: $defaultUdp)").Trim()
        if (-not $udp) { $udp = $defaultUdp }
    }
    $defaultFake = if ($current.UdpFake) {
        $current.UdpFake
    } else { "assets\ACTIVE_GAME_UDP.bin" }
    $fake = $UdpFake.Trim()
    if (-not $fake) {
        $fake = $defaultFake
    }
    if ($mode -in @("udp", "all") -and -not $UdpFake.Trim()) {
        $fake = (Read-Host "UDP fake path (default: $defaultFake)").Trim()
        if (-not $fake) { $fake = $defaultFake }
    }

    $transport = [ordered]@{
        mode = $mode
        preset = $preset
        tcpPorts = $tcp
        udpPorts = $udp
        udpFake = $fake
    }
    $candidate = [pscustomobject]@{ transport = [pscustomobject]$transport }
    [void](Get-GameFilterTransport $candidate $appRoot $filter.IpsPath)

    $manifest.schemaVersion = $script:GameFilterSchemaVersion
    if ($manifest.PSObject.Properties.Name -contains "transport") {
        $manifest.transport = [pscustomobject]$transport
    } else {
        $manifest | Add-Member `
            -MemberType NoteProperty `
            -Name transport `
            -Value ([pscustomobject]$transport)
    }
    Write-AtomicJson $filter.ManifestPath $manifest
    Write-Host (
        "{0}: transport {1} ({2})" -f
        $filter.DisplayName,
        $mode,
        $preset
    ) -ForegroundColor Green
    Write-Host (
        "Restart the active profile or service to apply transport changes."
    ) -ForegroundColor Yellow
}

function Set-GameFilterEnabled(
    [string]$Id,
    [bool]$Enabled
) {
    $id = $Id.Trim().ToLowerInvariant()
    if ($id -notmatch "^[a-z0-9][a-z0-9_-]{0,63}$") {
        throw "Invalid game filter ID: $Id"
    }
    $filters = @(Get-GameFilters $appRoot -IncludeInvalid)
    $filter = $filters | Where-Object Id -eq $id | Select-Object -First 1
    if (-not $filter) { throw "Game filter '$id' was not found." }
    if ($Enabled -and -not $filter.Valid) {
        throw "Game filter '$id' is invalid: $($filter.Error)"
    }

    $ids = New-Object "Collections.Generic.HashSet[string]" (
        [StringComparer]::OrdinalIgnoreCase
    )
    foreach ($current in Get-EnabledGameFilterIds $appRoot) {
        [void]$ids.Add($current)
    }
    if ($Enabled) {
        [void]$ids.Add($id)
    } else {
        [void]$ids.Remove($id)
    }
    Save-EnabledIds @($ids | ForEach-Object { [string]$_ })
    Write-Host (
        "{0}: {1}" -f
        $filter.DisplayName,
        $(if ($Enabled) { "enabled" } else { "disabled" })
    ) -ForegroundColor Green
    Update-RunningMappings
}

function New-GameFilter {
    $id = if ($FilterId) {
        $FilterId.Trim().ToLowerInvariant()
    } else {
        (Read-Host "Filter ID, for example my-game").Trim().ToLowerInvariant()
    }
    if ($id -notmatch "^[a-z0-9][a-z0-9_-]{0,63}$") {
        throw "Use 1-64 lowercase letters, numbers, '-' or '_'."
    }
    $path = Join-Path $filterRoot $id
    if (Test-Path -LiteralPath $path) {
        throw "A game filter named '$id' already exists."
    }
    $name = if ($DisplayName) {
        $DisplayName.Trim()
    } else {
        (Read-Host "Display name").Trim()
    }
    if (-not $name) { $name = $id }
    if ($name.Length -gt 80) {
        throw "The display name must not exceed 80 characters."
    }

    New-Item -ItemType Directory -Path $path -Force | Out-Null
    $manifest = [ordered]@{
        schemaVersion = $script:GameFilterSchemaVersion
        id = $id
        displayName = $name
        description = "Custom game filter."
        transport = [ordered]@{
            mode = "off"
            preset = "balanced"
            tcpPorts = "1024-65535"
            udpPorts = "1024-65535"
            udpFake = "assets\ACTIVE_GAME_UDP.bin"
        }
    }
    [IO.File]::WriteAllText(
        (Join-Path $path "filter.json"),
        ($manifest | ConvertTo-Json -Depth 5) + [Environment]::NewLine,
        $utf8NoBom
    )
    Write-AtomicLines (Join-Path $path "hosts.txt") @(
        "# Temporary hosts mappings. Format: IP hostname [hostname2 ...]"
        "# 203.0.113.10 signon.example-game.test"
    )
    Write-AtomicLines (Join-Path $path "domains.txt") @(
        "# Domains added to the active traffic profile. One per line."
        "# example-game.test"
    )
    Write-AtomicLines (Join-Path $path "ips.txt") @(
        "# IP addresses or CIDR ranges added to the active profile."
        "# 203.0.113.10/32"
    )
    Write-AtomicLines (Join-Path $path "domains-exclude.txt") @(
        "# Domain exclusions for this game. One per line."
    )
    Write-AtomicLines (Join-Path $path "ips-exclude.txt") @(
        "# IP/CIDR exclusions for this game. One per line."
    )
    Write-Host "Created: $path" -ForegroundColor Green
    Write-Host "The filter is disabled until you enable it."
    Start-Process -FilePath "explorer.exe" -ArgumentList @('"{0}"' -f $path)
}

function Show-GameFilters([switch]$Detailed) {
    $filters = @(Get-GameFilters $appRoot -IncludeInvalid)
    if ($filters.Count -eq 0) {
        Write-Host "No game filters were found."
        return @()
    }
    for ($index = 0; $index -lt $filters.Count; $index++) {
        $filter = $filters[$index]
        $marker = if (-not $filter.Valid) {
            "!"
        } elseif ($filter.Enabled) {
            "x"
        } else {
            " "
        }
        Write-Host ("[{0}] [{1}] {2}" -f ($index + 1), $marker, $filter.DisplayName)
        Write-Host "        $($filter.Id)" -ForegroundColor DarkGray
        if ($Detailed -and $filter.Description) {
            Write-Host "        $($filter.Description)" -ForegroundColor DarkGray
        }
        if ($filter.Valid) {
            $transportText = if ($filter.Transport.Mode -eq "off") {
                "Transport: off"
            } else {
                $modeName = if ($filter.Transport.Mode -eq "all") {
                    "TCP+UDP"
                } else {
                    $filter.Transport.Mode.ToUpperInvariant()
                }
                "Transport: $modeName, " +
                    "$($filter.Transport.Preset)"
            }
            Write-Host "        $transportText" -ForegroundColor DarkGray
        }
        if (-not $filter.Valid) {
            Write-Host "        ERROR: $($filter.Error)" -ForegroundColor Red
        }
    }
    return $filters
}

function Invoke-Validation {
    $filters = @(Get-GameFilters $appRoot -IncludeInvalid)
    $invalid = @($filters | Where-Object { -not $_.Valid })
    foreach ($filter in $filters) {
        if ($filter.Valid) {
            Write-Host "[OK]   $($filter.Id)" -ForegroundColor Green
        } else {
            Write-Host "[FAIL] $($filter.Id): $($filter.Error)" `
                -ForegroundColor Red
        }
    }
    $enabledIds = @(Get-EnabledGameFilterIds $appRoot)
    $known = @($filters.Id)
    foreach ($id in $enabledIds) {
        if ($id -notin $known) {
            Write-Host "[FAIL] Enabled filter was not found: $id" `
                -ForegroundColor Red
            $invalid += [pscustomobject]@{ Id = $id }
        }
    }
    try {
        [void]@(Get-EnabledGameFilterMappings $appRoot)
    } catch {
        Write-Host "[FAIL] $($_.Exception.Message)" -ForegroundColor Red
        $invalid += [pscustomobject]@{ Id = "mapping-conflict" }
    }
    if ($invalid.Count) {
        throw "$($invalid.Count) game filter error(s) found."
    }
    Write-Host "All game filters are valid." -ForegroundColor Green
}

function Invoke-InteractiveManager {
    while ($true) {
        Clear-Host
        Write-Host "=========================================================="
        Write-Host "                       Game Filters"
        Write-Host "=========================================================="
        Write-Host ""
        Write-Host (
            "Enabled filters add their hosts mappings, domains, IPs and " +
            "exclusions to ordinary traffic profiles."
        )
        Write-Host "Mappings remain active only while a profile/service is active."
        Write-Host ""
        $filters = @(Show-GameFilters -Detailed)
        Write-Host ""
        Write-Host "Enter a number to enable or disable a filter."
        Write-Host "[C] Create a custom filter"
        Write-Host "[T] Configure transport mode"
        Write-Host "[E] Open a filter folder"
        Write-Host "[O] Open the game filter folder"
        Write-Host "[V] Validate all game filters"
        Write-Host "[0] Back"
        Write-Host ""
        $choice = (Read-Host "Select an option").Trim()
        if ($choice -eq "0") { return }
        if ($choice -match "^[cC]$") {
            try { New-GameFilter } catch {
                Write-Host $_.Exception.Message -ForegroundColor Red
                Read-Host "Press Enter to continue" | Out-Null
            }
            continue
        }
        if ($choice -match "^[tT]$") {
            $selectionText = Read-Host "Filter number"
            $selection = 0
            if (
                [int]::TryParse($selectionText, [ref]$selection) -and
                $selection -ge 1 -and
                $selection -le $filters.Count
            ) {
                try {
                    Set-GameFilterTransport $filters[$selection - 1].Id
                } catch {
                    Write-Host $_.Exception.Message -ForegroundColor Red
                }
            }
            Read-Host "Press Enter to continue" | Out-Null
            continue
        }
        if ($choice -match "^[oO]$") {
            New-Item -ItemType Directory -Path $filterRoot -Force | Out-Null
            Start-Process -FilePath "explorer.exe" `
                -ArgumentList @('"{0}"' -f $filterRoot)
            continue
        }
        if ($choice -match "^[vV]$") {
            try { Invoke-Validation } catch {
                Write-Host $_.Exception.Message -ForegroundColor Red
            }
            Read-Host "Press Enter to continue" | Out-Null
            continue
        }
        if ($choice -match "^[eE]$") {
            $selectionText = Read-Host "Filter number"
            $selection = 0
            if (
                [int]::TryParse($selectionText, [ref]$selection) -and
                $selection -ge 1 -and
                $selection -le $filters.Count
            ) {
                Start-Process -FilePath "explorer.exe" -ArgumentList @(
                    '"{0}"' -f $filters[$selection - 1].Path
                )
            }
            continue
        }
        $number = 0
        if (
            [int]::TryParse($choice, [ref]$number) -and
            $number -ge 1 -and
            $number -le $filters.Count
        ) {
            $filter = $filters[$number - 1]
            try {
                Set-GameFilterEnabled $filter.Id (-not $filter.Enabled)
            } catch {
                Write-Host $_.Exception.Message -ForegroundColor Red
            }
            Read-Host "Press Enter to continue" | Out-Null
        }
    }
}

New-Item -ItemType Directory -Path $filterRoot -Force | Out-Null

switch ($Action) {
    "manage" { Invoke-InteractiveManager }
    "list" {
        Get-GameFilters $appRoot -IncludeInvalid |
            Select-Object Id, DisplayName, Enabled, Valid, Error
    }
    "enable" { Set-GameFilterEnabled $FilterId $true }
    "disable" { Set-GameFilterEnabled $FilterId $false }
    "create" { New-GameFilter }
    "transport" { Set-GameFilterTransport $FilterId }
    "validate" { Invoke-Validation }
    "open" {
        Start-Process -FilePath "explorer.exe" `
            -ArgumentList @('"{0}"' -f $filterRoot)
    }
}
