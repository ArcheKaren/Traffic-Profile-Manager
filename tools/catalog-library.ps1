$script:CatalogUtf8NoBom = New-Object Text.UTF8Encoding($false)

function Get-CatalogMeaningfulLines([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
    return @(
        Get-Content -LiteralPath $Path |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -and -not $_.StartsWith("#") }
    )
}

function Test-CatalogDomain([string]$Value, [string]$Context) {
    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw "Empty domain in $Context."
    }
    $domain = $Value.Trim().ToLowerInvariant()
    if ($domain.StartsWith("^")) { $domain = $domain.Substring(1) }
    if (
        $domain.Length -gt 253 -or
        $domain -notmatch "^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$"
    ) {
        throw "Invalid domain '$Value' in $Context."
    }
}

function Resolve-CatalogFile(
    [string]$AppRoot,
    [string]$RelativePath,
    [string]$FieldName
) {
    if ([string]::IsNullOrWhiteSpace($RelativePath)) {
        throw "'$FieldName' contains an empty path."
    }
    if ([IO.Path]::IsPathRooted($RelativePath)) {
        throw "'$FieldName' must use a relative path."
    }
    $root = [IO.Path]::GetFullPath((Join-Path $AppRoot "lists\packs")).TrimEnd("\")
    $full = [IO.Path]::GetFullPath((Join-Path $AppRoot $RelativePath))
    if (-not $full.StartsWith($root + "\", [StringComparison]::OrdinalIgnoreCase)) {
        throw "'$FieldName' must stay inside '$root'."
    }
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
        throw "Catalog pack was not found: $RelativePath"
    }
    $item = Get-Item -LiteralPath $full -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw "Catalog packs must not be reparse points: $RelativePath"
    }
    return $full
}

function Get-TargetCatalog([string]$AppRoot) {
    $catalogPath = Join-Path $AppRoot "lists\catalog.json"
    if (-not (Test-Path -LiteralPath $catalogPath -PathType Leaf)) {
        return $null
    }
    $catalog = Get-Content -Raw -LiteralPath $catalogPath | ConvertFrom-Json
    if ($catalog -isnot [pscustomobject] -or [int]$catalog.schemaVersion -ne 1) {
        throw "Unsupported target catalog schema."
    }
    if ([string]$catalog.revision -notmatch "^[0-9]{4}\.[0-9]{2}\.[0-9]{2}\.[0-9]+$") {
        throw "The target catalog revision is invalid."
    }
    if ([string]$catalog.generatedFile -ne "lists\domains.txt") {
        throw "The target catalog must generate lists\domains.txt."
    }
    if ($catalog.packs -isnot [Array] -or @($catalog.packs).Count -eq 0) {
        throw "The target catalog must contain at least one pack."
    }

    $sourceIds = New-Object "Collections.Generic.HashSet[string]" ([StringComparer]::OrdinalIgnoreCase)
    foreach ($source in @($catalog.sources)) {
        if ([string]$source.id -notmatch "^[a-z0-9][a-z0-9-]{0,63}$") {
            throw "A target catalog source ID is invalid."
        }
        if (-not $sourceIds.Add([string]$source.id)) {
            throw "Duplicate target catalog source: $($source.id)"
        }
    }

    $packIds = New-Object "Collections.Generic.HashSet[string]" ([StringComparer]::OrdinalIgnoreCase)
    $allDomains = New-Object "Collections.Generic.HashSet[string]" ([StringComparer]::OrdinalIgnoreCase)
    foreach ($pack in @($catalog.packs)) {
        $id = [string]$pack.id
        if ($id -notmatch "^[a-z0-9][a-z0-9-]{0,63}$") {
            throw "A target pack ID is invalid."
        }
        if (-not $packIds.Add($id)) { throw "Duplicate target pack: $id" }
        if ([string]::IsNullOrWhiteSpace([string]$pack.displayName)) {
            throw "Target pack '$id' has no displayName."
        }
        if ($pack.enabledByDefault -isnot [bool]) {
            throw "Target pack '$id' enabledByDefault must be boolean."
        }
        foreach ($sourceId in @($pack.sourceIds)) {
            if (-not $sourceIds.Contains([string]$sourceId)) {
                throw "Target pack '$id' references unknown source '$sourceId'."
            }
        }
        $path = Resolve-CatalogFile $AppRoot ([string]$pack.path) "packs.path"
        foreach ($domain in Get-CatalogMeaningfulLines $path) {
            Test-CatalogDomain $domain "target pack '$id'"
            if (-not $allDomains.Add($domain.TrimStart("^").ToLowerInvariant())) {
                throw "Duplicate domain across target packs: $domain"
            }
        }
    }
    return $catalog
}

function Get-DomainPackState([string]$AppRoot, $Catalog) {
    $statePath = Join-Path $AppRoot "state\domain-packs.json"
    $known = New-Object "Collections.Generic.HashSet[string]" ([StringComparer]::OrdinalIgnoreCase)
    $enabled = New-Object "Collections.Generic.HashSet[string]" ([StringComparer]::OrdinalIgnoreCase)
    $hasState = Test-Path -LiteralPath $statePath -PathType Leaf
    if ($hasState) {
        $state = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json
        if ($state -isnot [pscustomobject] -or [int]$state.schemaVersion -ne 1) {
            throw "Unsupported domain pack state schema."
        }
        foreach ($id in @($state.knownPacks)) { [void]$known.Add([string]$id) }
        foreach ($id in @($state.enabledPacks)) { [void]$enabled.Add([string]$id) }
    }
    foreach ($pack in @($Catalog.packs)) {
        $id = [string]$pack.id
        if (-not $known.Contains($id) -and [bool]$pack.enabledByDefault) {
            [void]$enabled.Add($id)
        }
        [void]$known.Add($id)
    }
    $validIds = @($Catalog.packs | ForEach-Object { [string]$_.id })
    foreach ($id in @($enabled)) {
        if ($id -notin $validIds) { [void]$enabled.Remove($id) }
    }
    return [pscustomobject]@{
        Path = $statePath
        Enabled = $enabled
        Known = $known
    }
}

function Save-DomainPackState([string]$AppRoot, $Catalog, $State) {
    $stateRoot = Join-Path $AppRoot "state"
    if (-not (Test-Path -LiteralPath $stateRoot -PathType Container)) {
        New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
    }
    $value = [ordered]@{
        schemaVersion = 1
        catalogRevision = [string]$Catalog.revision
        knownPacks = @($Catalog.packs | ForEach-Object { [string]$_.id })
        enabledPacks = @(
            $Catalog.packs |
                Where-Object { $State.Enabled.Contains([string]$_.id) } |
                ForEach-Object { [string]$_.id }
        )
    }
    if (Test-Path -LiteralPath $State.Path -PathType Leaf) {
        try {
            $current = Get-Content -Raw -LiteralPath $State.Path |
                ConvertFrom-Json |
                ConvertTo-Json -Depth 8 -Compress
            $expected = $value | ConvertTo-Json -Depth 8 -Compress
            if ($current -ceq $expected) { return }
        } catch {}
    }
    $temporary = "$($State.Path).$PID.$([Guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText(
            $temporary,
            ($value | ConvertTo-Json -Depth 8) + [Environment]::NewLine,
            $script:CatalogUtf8NoBom
        )
        Move-Item -LiteralPath $temporary -Destination $State.Path -Force
    } finally {
        if (Test-Path -LiteralPath $temporary) {
            Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-CompiledDomainCatalog([string]$AppRoot, $Catalog, $State) {
    $lines = New-Object "Collections.Generic.List[string]"
    $domains = New-Object "Collections.Generic.HashSet[string]" ([StringComparer]::OrdinalIgnoreCase)
    $enabledPacks = @(
        $Catalog.packs | Where-Object { $State.Enabled.Contains([string]$_.id) }
    )
    $lines.Add("# Generated from lists\catalog.json. Use the domain pack manager.")
    $lines.Add("# Catalog revision: $($Catalog.revision)")
    $lines.Add("# Enabled packs: $((@($enabledPacks | ForEach-Object id)) -join ', ')")
    foreach ($pack in $enabledPacks) {
        $lines.Add("")
        $lines.Add("# Pack: $($pack.displayName) [$($pack.id)]")
        $path = Resolve-CatalogFile $AppRoot ([string]$pack.path) "packs.path"
        foreach ($domain in Get-CatalogMeaningfulLines $path) {
            $normalized = $domain.ToLowerInvariant()
            if ($domains.Add($normalized.TrimStart("^"))) { $lines.Add($normalized) }
        }
    }
    return [pscustomobject]@{
        Lines = $lines.ToArray()
        Domains = @($domains)
        EnabledPacks = $enabledPacks
    }
}

function Sync-DomainCatalog(
    [string]$AppRoot,
    [switch]$CheckOnly
) {
    $catalog = Get-TargetCatalog $AppRoot
    if ($null -eq $catalog) { return $null }
    $state = Get-DomainPackState $AppRoot $catalog
    $compiled = Get-CompiledDomainCatalog $AppRoot $catalog $state
    $domainsPath = Join-Path $AppRoot "lists\domains.txt"
    $expected = ($compiled.Lines -join [Environment]::NewLine) + [Environment]::NewLine
    $actual = if (Test-Path -LiteralPath $domainsPath -PathType Leaf) {
        [IO.File]::ReadAllText($domainsPath)
    } else { "" }
    $matches = $actual.Replace("`r`n", "`n") -eq $expected.Replace("`r`n", "`n")
    if ($CheckOnly) {
        if (-not $matches) { throw "lists\domains.txt is not synchronized with the enabled domain packs." }
    } else {
        Save-DomainPackState $AppRoot $catalog $state
        if (-not $matches) {
            $temporary = "$domainsPath.$PID.$([Guid]::NewGuid().ToString('N')).tmp"
            try {
                [IO.File]::WriteAllText($temporary, $expected, $script:CatalogUtf8NoBom)
                Move-Item -LiteralPath $temporary -Destination $domainsPath -Force
            } finally {
                if (Test-Path -LiteralPath $temporary) {
                    Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
                }
            }
        }
    }
    return [pscustomobject]@{
        Catalog = $catalog
        State = $state
        DomainCount = @($compiled.Domains).Count
        EnabledPackCount = @($compiled.EnabledPacks).Count
        Synchronized = $matches
    }
}
