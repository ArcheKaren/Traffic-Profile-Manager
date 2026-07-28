$script:GameFilterSchemaVersion = 2
$script:SupportedGameFilterSchemaVersions = @(1, 2)

function Get-GameFilterRoot([string]$AppRoot) {
    return [IO.Path]::GetFullPath((Join-Path $AppRoot "config\game-filters"))
}

function Get-GameFilterStatePath([string]$AppRoot) {
    return [IO.Path]::GetFullPath(
        (Join-Path $AppRoot "state\enabled-game-filters.txt")
    )
}

function Get-MeaningfulGameFilterLines([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
    return @(
        Get-Content -LiteralPath $Path |
            ForEach-Object {
                $value = $_.Trim()
                if ($value -and -not $value.StartsWith("#")) { $value }
            }
    )
}

function ConvertTo-GameFilterPortExpression([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw "A port or port range is required."
    }
    $ranges = New-Object "Collections.Generic.List[object]"
    foreach ($rawPart in $Value.Split(",")) {
        $part = $rawPart.Trim()
        if ($part -notmatch "^(?<start>\d{1,5})(?:-(?<end>\d{1,5}))?$") {
            throw "Invalid port or port range: $rawPart"
        }
        $start = [int]$Matches.start
        $end = if ($Matches.end) { [int]$Matches.end } else { $start }
        if ($start -lt 1 -or $end -gt 65535 -or $start -gt $end) {
            throw "Port range must be between 1 and 65535: $part"
        }
        $ranges.Add([pscustomobject]@{ Start = $start; End = $end })
    }

    $merged = New-Object "Collections.Generic.List[object]"
    foreach ($range in @($ranges | Sort-Object Start, End)) {
        if (
            $merged.Count -and
            $range.Start -le ($merged[$merged.Count - 1].End + 1)
        ) {
            if ($range.End -gt $merged[$merged.Count - 1].End) {
                $merged[$merged.Count - 1].End = $range.End
            }
        } else {
            $merged.Add([pscustomobject]@{
                Start = [int]$range.Start
                End = [int]$range.End
            })
        }
    }
    return (
        $merged |
            ForEach-Object {
                if ($_.Start -eq $_.End) {
                    [string]$_.Start
                } else {
                    "$($_.Start)-$($_.End)"
                }
            }
    ) -join ","
}

function Merge-GameFilterPortExpressions([string[]]$Values) {
    $parts = @(
        $Values |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { ([string]$_).Split(",") } |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ }
    )
    if ($parts.Count -eq 0) { return "" }
    return ConvertTo-GameFilterPortExpression ($parts -join ",")
}

function Resolve-GameFilterAssetPath(
    [string]$AppRoot,
    [string]$RelativePath
) {
    if ([string]::IsNullOrWhiteSpace($RelativePath)) {
        throw "udpFake is required when UDP transport is enabled."
    }
    if ([IO.Path]::IsPathRooted($RelativePath)) {
        throw "udpFake must be a path relative to the program folder."
    }
    $root = [IO.Path]::GetFullPath($AppRoot).TrimEnd("\")
    $fullPath = [IO.Path]::GetFullPath((Join-Path $root $RelativePath))
    if (-not $fullPath.StartsWith(
        $root + "\",
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw "udpFake must stay inside the program folder."
    }
    if ([IO.Path]::GetExtension($fullPath) -ine ".bin") {
        throw "udpFake must reference a .bin file."
    }
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        throw "UDP fake file was not found: $RelativePath"
    }
    $length = (Get-Item -LiteralPath $fullPath).Length
    if ($length -lt 1 -or $length -gt 65535) {
        throw "UDP fake file must contain 1-65535 bytes: $RelativePath"
    }
    return $fullPath
}

function Get-GameFilterTransport(
    [object]$Manifest,
    [string]$AppRoot,
    [string]$IpsPath
) {
    $mode = "off"
    $preset = "balanced"
    $tcpPorts = "1024-65535"
    $udpPorts = "1024-65535"
    $udpFake = "assets\ACTIVE_GAME_UDP.bin"

    if ($Manifest.PSObject.Properties.Name -contains "transport") {
        $transport = $Manifest.transport
        if ($null -eq $transport) {
            throw "transport must be an object."
        }
        if ($transport.PSObject.Properties.Name -contains "mode") {
            $mode = ([string]$transport.mode).Trim().ToLowerInvariant()
        }
        if ($transport.PSObject.Properties.Name -contains "preset") {
            $preset = ([string]$transport.preset).Trim().ToLowerInvariant()
        }
        if ($transport.PSObject.Properties.Name -contains "tcpPorts") {
            $tcpPorts = [string]$transport.tcpPorts
        }
        if ($transport.PSObject.Properties.Name -contains "udpPorts") {
            $udpPorts = [string]$transport.udpPorts
        }
        if ($transport.PSObject.Properties.Name -contains "udpFake") {
            $udpFake = [string]$transport.udpFake
        }
    }

    if ($mode -notin @("off", "tcp", "udp", "all")) {
        throw "transport.mode must be off, tcp, udp or all."
    }
    if ($preset -notin @("balanced", "extended")) {
        throw "transport.preset must be balanced or extended."
    }

    $usesTcp = $mode -in @("tcp", "all")
    $usesUdp = $mode -in @("udp", "all")
    $normalizedTcp = if ($usesTcp) {
        ConvertTo-GameFilterPortExpression $tcpPorts
    } else { "" }
    $normalizedUdp = if ($usesUdp) {
        ConvertTo-GameFilterPortExpression $udpPorts
    } else { "" }
    $udpFakePath = if ($usesUdp) {
        Resolve-GameFilterAssetPath $AppRoot $udpFake
    } else { "" }
    if (
        $mode -ne "off" -and
        (Get-MeaningfulGameFilterLines $IpsPath).Count -eq 0
    ) {
        throw "ips.txt must contain at least one IP/CIDR when transport is enabled."
    }

    return [pscustomobject]@{
        Mode = $mode
        Preset = $preset
        TcpPorts = $normalizedTcp
        UdpPorts = $normalizedUdp
        UdpFake = $udpFake
        UdpFakePath = $udpFakePath
        UsesTcp = $usesTcp
        UsesUdp = $usesUdp
    }
}

function ConvertTo-GameFilterDomain(
    [string]$Value,
    [switch]$AllowExactPrefix
) {
    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw "A domain is required."
    }
    $domain = $Value.Trim().ToLowerInvariant()
    $exact = $AllowExactPrefix -and $domain.StartsWith("^")
    if ($exact) { $domain = $domain.Substring(1) }
    $domain = $domain.TrimEnd(".")
    if (
        $domain.Contains("://") -or
        $domain.Contains("/") -or
        $domain.Contains(":") -or
        $domain.Contains("*")
    ) {
        throw "'$Value' is not a domain name."
    }
    try {
        $domain = (New-Object Globalization.IdnMapping).GetAscii($domain)
    } catch {
        throw "Invalid domain name: $Value"
    }
    if (
        $domain.Length -gt 253 -or
        $domain -notmatch "^[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?$"
    ) {
        throw "Invalid domain name: $Value"
    }
    foreach ($label in $domain.Split(".")) {
        if (
            -not $label -or
            $label.Length -gt 63 -or
            $label.StartsWith("-") -or
            $label.EndsWith("-")
        ) {
            throw "Invalid domain name: $Value"
        }
    }
    return $(if ($exact) { "^$domain" } else { $domain })
}

function ConvertTo-GameFilterIpNetwork([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw "An IP address or CIDR is required."
    }
    $parts = $Value.Trim().Split("/")
    if ($parts.Count -gt 2) { throw "Invalid IP/CIDR: $Value" }
    $address = $null
    if (-not [Net.IPAddress]::TryParse($parts[0], [ref]$address)) {
        throw "Invalid IP address: $Value"
    }
    if ($parts.Count -eq 1) {
        return $address.ToString().ToLowerInvariant()
    }
    $prefix = 0
    $maximum = if (
        $address.AddressFamily -eq
            [Net.Sockets.AddressFamily]::InterNetwork
    ) { 32 } else { 128 }
    if (
        -not [int]::TryParse($parts[1], [ref]$prefix) -or
        $prefix -lt 0 -or
        $prefix -gt $maximum
    ) {
        throw "Invalid CIDR prefix length: $Value"
    }
    return "$($address.ToString().ToLowerInvariant())/$prefix"
}

function Read-GameFilterMappings([string]$Path) {
    $result = New-Object "Collections.Generic.List[object]"
    $known = New-Object "Collections.Generic.Dictionary[string,string]" (
        [StringComparer]::OrdinalIgnoreCase
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return @()
    }

    $lineNumber = 0
    foreach ($rawLine in Get-Content -LiteralPath $Path) {
        $lineNumber++
        $line = ([string]$rawLine).Split("#", 2)[0].Trim()
        if (-not $line) { continue }
        $parts = @($line -split "\s+" | Where-Object { $_ })
        if ($parts.Count -lt 2) {
            throw "Invalid hosts entry at ${Path}:$lineNumber."
        }
        $address = $null
        if (-not [Net.IPAddress]::TryParse($parts[0], [ref]$address)) {
            throw "Invalid hosts IP at ${Path}:$lineNumber`: $($parts[0])"
        }
        $normalizedAddress = $address.ToString().ToLowerInvariant()
        foreach ($rawName in $parts[1..($parts.Count - 1)]) {
            $name = ConvertTo-GameFilterDomain $rawName
            if (
                $known.ContainsKey($name) -and
                $known[$name] -ne $normalizedAddress
            ) {
                throw "Conflicting hosts entries for '$name' in $Path."
            }
            if (-not $known.ContainsKey($name)) {
                $known[$name] = $normalizedAddress
                $result.Add([pscustomobject]@{
                    Address = $normalizedAddress
                    Name = $name
                })
            }
        }
    }
    return $result.ToArray()
}

function Test-GameFilterList(
    [string]$Path,
    [ValidateSet("domain", "ip")]
    [string]$Kind
) {
    $known = New-Object "Collections.Generic.HashSet[string]" (
        [StringComparer]::OrdinalIgnoreCase
    )
    $lineNumber = 0
    foreach ($rawLine in Get-Content -LiteralPath $Path) {
        $lineNumber++
        $line = ([string]$rawLine).Trim()
        if (-not $line -or $line.StartsWith("#")) { continue }
        try {
            $normalized = if ($Kind -eq "domain") {
                ConvertTo-GameFilterDomain $line -AllowExactPrefix
            } else {
                ConvertTo-GameFilterIpNetwork $line
            }
        } catch {
            throw "$($_.Exception.Message) File: ${Path}:$lineNumber."
        }
        if (-not $known.Add($normalized)) {
            throw "Duplicate entry '$normalized' in $Path."
        }
    }
}

function Get-EnabledGameFilterIds([string]$AppRoot) {
    $statePath = Get-GameFilterStatePath $AppRoot
    $result = New-Object "Collections.Generic.List[string]"
    $known = New-Object "Collections.Generic.HashSet[string]" (
        [StringComparer]::OrdinalIgnoreCase
    )
    foreach ($id in Get-MeaningfulGameFilterLines $statePath) {
        if ($id -notmatch "^[a-z0-9][a-z0-9_-]{0,63}$") {
            throw "Invalid enabled game filter ID in ${statePath}: $id"
        }
        if ($known.Add($id)) { $result.Add($id.ToLowerInvariant()) }
    }
    return $result.ToArray()
}

function Get-GameFilters(
    [string]$AppRoot,
    [switch]$IncludeInvalid
) {
    $root = Get-GameFilterRoot $AppRoot
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        return @()
    }
    $enabledIds = @(Get-EnabledGameFilterIds $AppRoot)
    $enabled = New-Object "Collections.Generic.HashSet[string]" (
        [StringComparer]::OrdinalIgnoreCase
    )
    foreach ($id in $enabledIds) { [void]$enabled.Add($id) }

    $filters = New-Object "Collections.Generic.List[object]"
    $discoveredIds = New-Object "Collections.Generic.HashSet[string]" (
        [StringComparer]::OrdinalIgnoreCase
    )
    foreach ($directory in @(
        Get-ChildItem -LiteralPath $root -Directory | Sort-Object Name
    )) {
        $manifestPath = Join-Path $directory.FullName "filter.json"
        $id = $directory.Name.ToLowerInvariant()
        $displayName = $directory.Name
        $description = ""
        $valid = $true
        $errorMessage = ""
        $schemaVersion = 0
        $transport = [pscustomobject]@{
            Mode = "off"
            Preset = "balanced"
            TcpPorts = ""
            UdpPorts = ""
            UdpFake = "assets\ACTIVE_GAME_UDP.bin"
            UdpFakePath = ""
            UsesTcp = $false
            UsesUdp = $false
        }
        [void]$discoveredIds.Add($id)
        try {
            if ($id -notmatch "^[a-z0-9][a-z0-9_-]{0,63}$") {
                throw "The folder name must use lowercase letters, numbers, '-' or '_'."
            }
            if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
                throw "filter.json was not found."
            }
            $manifest = Get-Content -Raw -LiteralPath $manifestPath |
                ConvertFrom-Json
            $schemaVersion = [int]$manifest.schemaVersion
            if (
                $schemaVersion -notin
                    $script:SupportedGameFilterSchemaVersions
            ) {
                throw "Unsupported schemaVersion '$($manifest.schemaVersion)'."
            }
            if ([string]$manifest.id -cne $id) {
                throw "The manifest ID must match the folder name '$id'."
            }
            $displayName = ([string]$manifest.displayName).Trim()
            if (-not $displayName -or $displayName.Length -gt 80) {
                throw "displayName must contain 1-80 characters."
            }
            $description = ([string]$manifest.description).Trim()
            foreach ($name in @(
                "hosts.txt",
                "domains.txt",
                "ips.txt",
                "domains-exclude.txt",
                "ips-exclude.txt"
            )) {
                $path = Join-Path $directory.FullName $name
                if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                    throw "Required file was not found: $name"
                }
            }
            [void](Read-GameFilterMappings (
                Join-Path $directory.FullName "hosts.txt"
            ))
            Test-GameFilterList (
                Join-Path $directory.FullName "domains.txt"
            ) "domain"
            Test-GameFilterList (
                Join-Path $directory.FullName "ips.txt"
            ) "ip"
            Test-GameFilterList (
                Join-Path $directory.FullName "domains-exclude.txt"
            ) "domain"
            Test-GameFilterList (
                Join-Path $directory.FullName "ips-exclude.txt"
            ) "ip"
            $transport = Get-GameFilterTransport `
                $manifest `
                $AppRoot `
                (Join-Path $directory.FullName "ips.txt")
        } catch {
            $valid = $false
            $errorMessage = $_.Exception.Message
        }

        if ($valid -or $IncludeInvalid) {
            $filters.Add([pscustomobject]@{
                Id = $id
                DisplayName = $displayName
                Description = $description
                SchemaVersion = $schemaVersion
                Path = $directory.FullName
                ManifestPath = $manifestPath
                HostsPath = Join-Path $directory.FullName "hosts.txt"
                DomainsPath = Join-Path $directory.FullName "domains.txt"
                IpsPath = Join-Path $directory.FullName "ips.txt"
                DomainExcludesPath = Join-Path $directory.FullName "domains-exclude.txt"
                IpExcludesPath = Join-Path $directory.FullName "ips-exclude.txt"
                Transport = $transport
                Enabled = $enabled.Contains($id)
                Valid = $valid
                Error = $errorMessage
            })
        }
    }
    if ($IncludeInvalid) {
        foreach ($id in $enabledIds) {
            if ($discoveredIds.Contains($id)) { continue }
            $missingPath = Join-Path $root $id
            $filters.Add([pscustomobject]@{
                Id = $id
                DisplayName = $id
                Description = ""
                SchemaVersion = 0
                Path = $missingPath
                ManifestPath = Join-Path $missingPath "filter.json"
                HostsPath = Join-Path $missingPath "hosts.txt"
                DomainsPath = Join-Path $missingPath "domains.txt"
                IpsPath = Join-Path $missingPath "ips.txt"
                DomainExcludesPath = Join-Path $missingPath "domains-exclude.txt"
                IpExcludesPath = Join-Path $missingPath "ips-exclude.txt"
                Transport = [pscustomobject]@{
                    Mode = "off"
                    Preset = "balanced"
                    TcpPorts = ""
                    UdpPorts = ""
                    UdpFake = "assets\ACTIVE_GAME_UDP.bin"
                    UdpFakePath = ""
                    UsesTcp = $false
                    UsesUdp = $false
                }
                Enabled = $true
                Valid = $false
                Error = "The enabled filter folder was not found."
            })
        }
    }
    return @(
        $filters |
            Sort-Object @{ Expression = "DisplayName"; Ascending = $true },
                @{ Expression = "Id"; Ascending = $true }
    )
}

function Get-EnabledGameFilters(
    [string]$AppRoot,
    [switch]$ThrowOnInvalid
) {
    $enabledIds = @(Get-EnabledGameFilterIds $AppRoot)
    if ($enabledIds.Count -eq 0) { return @() }
    $filters = @(Get-GameFilters $AppRoot -IncludeInvalid)
    $byId = @{}
    foreach ($filter in $filters) { $byId[$filter.Id] = $filter }
    $result = New-Object "Collections.Generic.List[object]"
    foreach ($id in $enabledIds) {
        if (-not $byId.ContainsKey($id)) {
            if ($ThrowOnInvalid) {
                throw "Enabled game filter '$id' was not found."
            }
            continue
        }
        $filter = $byId[$id]
        if (-not $filter.Valid) {
            if ($ThrowOnInvalid) {
                throw "Enabled game filter '$id' is invalid: $($filter.Error)"
            }
            continue
        }
        $result.Add($filter)
    }
    return $result.ToArray()
}

function Get-EnabledGameFilterListPaths(
    [string]$AppRoot,
    [ValidateSet(
        "domain",
        "ip",
        "domain-exclude",
        "ip-exclude"
    )]
    [string]$Kind
) {
    $property = switch ($Kind) {
        "domain" { "DomainsPath" }
        "ip" { "IpsPath" }
        "domain-exclude" { "DomainExcludesPath" }
        "ip-exclude" { "IpExcludesPath" }
    }
    return @(
        Get-EnabledGameFilters $AppRoot -ThrowOnInvalid |
            ForEach-Object {
                $path = [string]$_.$property
                if ((Get-MeaningfulGameFilterLines $path).Count -gt 0) {
                    $path
                }
            }
    )
}

function Get-EnabledGameFilterMappings([string]$AppRoot) {
    $result = New-Object "Collections.Generic.List[object]"
    $known = New-Object "Collections.Generic.Dictionary[string,object]" (
        [StringComparer]::OrdinalIgnoreCase
    )
    foreach ($filter in Get-EnabledGameFilters $AppRoot -ThrowOnInvalid) {
        foreach ($mapping in Read-GameFilterMappings $filter.HostsPath) {
            if ($known.ContainsKey($mapping.Name)) {
                $existing = $known[$mapping.Name]
                if ($existing.Address -ne $mapping.Address) {
                    throw (
                        "Game filters '$($existing.FilterId)' and " +
                        "'$($filter.Id)' assign different addresses to " +
                        "'$($mapping.Name)'."
                    )
                }
                continue
            }
            $item = [pscustomobject]@{
                Address = $mapping.Address
                Name = $mapping.Name
                FilterId = $filter.Id
            }
            $known[$mapping.Name] = $item
            $result.Add($item)
        }
    }
    return $result.ToArray()
}

function Get-EnabledGameFilterTransports([string]$AppRoot) {
    return @(
        Get-EnabledGameFilters $AppRoot -ThrowOnInvalid |
            Where-Object { $_.Transport.Mode -ne "off" }
    )
}
