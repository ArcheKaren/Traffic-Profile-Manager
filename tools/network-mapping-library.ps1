function Test-NetworkMappingHostName([string]$Value, [string]$FieldName) {
    $name = $Value.Trim().TrimEnd(".").ToLowerInvariant()
    if (
        -not $name -or
        $name.Length -gt 253 -or
        $name -notmatch "^[a-z0-9.-]+$" -or
        @($name.Split(".") | Where-Object {
            -not $_ -or $_.Length -gt 63 -or $_.StartsWith("-") -or $_.EndsWith("-")
        }).Count
    ) {
        throw "Invalid host name in '$FieldName': $Value"
    }
    return $name
}

function Get-NetworkMappingDefinitions([string]$AppRoot) {
    $root = Join-Path $AppRoot "config\network-mappings"
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { return @() }
    $ids = New-Object "Collections.Generic.HashSet[string]" (
        [StringComparer]::OrdinalIgnoreCase
    )
    $definitions = @()
    foreach ($file in Get-ChildItem -LiteralPath $root -Filter "*.json" -File) {
        $item = Get-Content -Raw -LiteralPath $file.FullName | ConvertFrom-Json
        $id = [string]$item.id
        if (
            [int]$item.schemaVersion -ne 1 -or
            $id -notmatch "^[a-z0-9][a-z0-9-]{0,63}$" -or
            -not $ids.Add($id) -or
            $id -cne $file.BaseName
        ) {
            throw "Invalid network mapping definition: $($file.Name)"
        }
        if ([string]$item.mode -notin @("fixed", "secure-dns")) {
            throw "Network mapping '$id' has an unsupported mode."
        }
        if ($item.actions -isnot [Array] -or @($item.actions).Count -eq 0) {
            throw "Network mapping '$id' must define actions."
        }
        foreach ($action in @($item.actions)) {
            if ([string]$action -notin @("install", "refresh")) {
                throw "Network mapping '$id' has an invalid action."
            }
        }
        if ($item.hosts -isnot [Array] -or @($item.hosts).Count -eq 0) {
            throw "Network mapping '$id' must define hosts."
        }
        foreach ($name in @($item.hosts)) {
            [void](Test-NetworkMappingHostName ([string]$name) "$id.hosts")
        }
        foreach ($suffix in @($item.discoverSuffixes)) {
            [void](Test-NetworkMappingHostName ([string]$suffix) "$id.discoverSuffixes")
        }
        if ($item.mode -eq "fixed") {
            $address = $null
            if (-not [Net.IPAddress]::TryParse([string]$item.address, [ref]$address)) {
                throw "Network mapping '$id' has an invalid fixed address."
            }
        } else {
            if ($item.providers -isnot [Array] -or @($item.providers).Count -eq 0) {
                throw "Network mapping '$id' must define secure DNS providers."
            }
            [void](Test-NetworkMappingHostName ([string]$item.probeHost) "$id.probeHost")
            foreach ($provider in @($item.providers)) {
                $address = $null
                $uri = $null
                if (
                    -not [Net.IPAddress]::TryParse([string]$provider.address, [ref]$address) -or
                    -not [Uri]::TryCreate([string]$provider.url, [UriKind]::Absolute, [ref]$uri) -or
                    $uri.Scheme -ne "https" -or
                    -not ([string]$provider.url).Contains("{0}")
                ) {
                    throw "Network mapping '$id' has an invalid secure DNS provider."
                }
                [void](Test-NetworkMappingHostName ([string]$provider.host) "$id.providers.host")
            }
            foreach ($property in @($item.fallbacks.PSObject.Properties)) {
                [void](Test-NetworkMappingHostName ([string]$property.Name) "$id.fallbacks")
                $address = $null
                if (-not [Net.IPAddress]::TryParse([string]$property.Value, [ref]$address)) {
                    throw "Network mapping '$id' has an invalid fallback address."
                }
            }
            foreach ($override in @($item.overrides)) {
                [void](Test-NetworkMappingHostName ([string]$override.testHost) "$id.overrides.testHost")
                if ([string]$override.cacheFile -notmatch "^state\\[a-zA-Z0-9_.-]+$") {
                    throw "Network mapping '$id' has an unsafe override cache path."
                }
                foreach ($name in @($override.targets) + @($override.candidates)) {
                    [void](Test-NetworkMappingHostName ([string]$name) "$id.overrides")
                }
            }
        }
        $definitions += $item
    }
    return @($definitions | Sort-Object id)
}

function Get-NetworkMappingHostNames([object]$Definition) {
    $names = New-Object "Collections.Generic.HashSet[string]" (
        [StringComparer]::OrdinalIgnoreCase
    )
    foreach ($name in @($Definition.hosts)) {
        [void]$names.Add(([string]$name).ToLowerInvariant())
    }
    $suffixes = @($Definition.discoverSuffixes | ForEach-Object {
        ([string]$_).ToLowerInvariant()
    })
    if ($suffixes.Count) {
        Get-DnsClientCache -ErrorAction SilentlyContinue | ForEach-Object {
            $name = ([string]$_.Entry).Trim().TrimEnd(".").ToLowerInvariant()
            foreach ($suffix in $suffixes) {
                if ($name -eq $suffix -or $name.EndsWith(".$suffix")) {
                    try { [void]$names.Add((Test-NetworkMappingHostName $name "DNS cache")) } catch {}
                    break
                }
            }
        }
    }
    return @($names | Sort-Object)
}
