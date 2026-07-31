function Test-TrafficProfilePortExpression(
    [string]$Value,
    [string]$FieldName
) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return }
    foreach ($rawPart in $Value.Split(",")) {
        $part = $rawPart.Trim()
        if ($part -notmatch "^(?<start>\d{1,5})(?:-(?<end>\d{1,5}))?$") {
            throw "Invalid port expression in '$FieldName': $rawPart"
        }
        $start = [int]$Matches.start
        $end = if ($Matches.end) { [int]$Matches.end } else { $start }
        if ($start -lt 1 -or $end -gt 65535 -or $start -gt $end) {
            throw "Port range in '$FieldName' must be between 1 and 65535: $part"
        }
    }
}

function Resolve-TrafficProfilePath(
    [string]$AppRoot,
    [string]$RelativePath,
    [string]$AllowedRoot,
    [string]$FieldName
) {
    if ([string]::IsNullOrWhiteSpace($RelativePath)) {
        throw "'$FieldName' contains an empty path."
    }
    if ([IO.Path]::IsPathRooted($RelativePath)) {
        throw "'$FieldName' must use a relative path."
    }
    $root = [IO.Path]::GetFullPath($AllowedRoot).TrimEnd("\")
    $fullPath = [IO.Path]::GetFullPath(
        (Join-Path ([IO.Path]::GetFullPath($AppRoot)) $RelativePath)
    )
    if (-not $fullPath.StartsWith(
        $root + "\",
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw "'$FieldName' must stay inside '$root'."
    }
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        throw "'$FieldName' file was not found: $RelativePath"
    }
    $current = Get-Item -LiteralPath $fullPath -Force
    while ($current -and $current.FullName.Length -ge $root.Length) {
        if ($current.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "'$FieldName' must not pass through a reparse point."
        }
        if ($current.FullName -ieq $root) { break }
        $parent = Split-Path -Parent $current.FullName
        if (-not $parent -or -not (Test-Path -LiteralPath $parent)) { break }
        $current = Get-Item -LiteralPath $parent -Force
    }
    return $fullPath
}

function Test-TrafficProfileDefinition(
    [object]$Profile,
    [string]$ProfilePath,
    [string]$AppRoot
) {
    if ($null -eq $Profile -or $Profile -isnot [pscustomobject]) {
        throw "The profile JSON must contain an object."
    }
    $id = [string]$Profile.name
    if (-not $id -or $id -notmatch "^[a-zA-Z0-9_-]{1,64}$") {
        throw "The 'name' field is missing or invalid."
    }
    if ($id -cne [IO.Path]::GetFileNameWithoutExtension($ProfilePath)) {
        throw "The 'name' field must match the file name."
    }
    if ($Profile.interception -isnot [pscustomobject]) {
        throw "The 'interception' section must be an object."
    }
    foreach ($field in @("tcpOut", "udpOut", "tcpIn", "udpIn")) {
        if ($Profile.interception.PSObject.Properties.Name -contains $field) {
            if (
                $null -ne $Profile.interception.$field -and
                $Profile.interception.$field -isnot [string]
            ) {
                throw "'interception.$field' must be a string."
            }
            Test-TrafficProfilePortExpression `
                ([string]$Profile.interception.$field) `
                "interception.$field"
        }
    }
    if (
        [string]::IsNullOrWhiteSpace([string]$Profile.interception.tcpOut) -and
        [string]::IsNullOrWhiteSpace([string]$Profile.interception.udpOut) -and
        [string]::IsNullOrWhiteSpace([string]$Profile.interception.tcpIn) -and
        [string]::IsNullOrWhiteSpace([string]$Profile.interception.udpIn)
    ) {
        throw "The profile must define at least one interception port."
    }
    if ($Profile.interception.PSObject.Properties.Name -contains "rawParts") {
        if ($Profile.interception.rawParts -isnot [Array]) {
            throw "'interception.rawParts' must be an array."
        }
        foreach ($relativePath in @($Profile.interception.rawParts)) {
            if ($relativePath -isnot [string]) {
                throw "'interception.rawParts' paths must be strings."
            }
            [void](Resolve-TrafficProfilePath `
                $AppRoot `
                ([string]$relativePath) `
                ([IO.Path]::GetFullPath($AppRoot)) `
                "interception.rawParts")
        }
    }

    $blobNames = New-Object "Collections.Generic.HashSet[string]" (
        [StringComparer]::OrdinalIgnoreCase
    )
    if ($Profile.PSObject.Properties.Name -contains "blobs") {
        if ($Profile.blobs -isnot [Array]) {
            throw "'blobs' must be an array."
        }
        foreach ($blob in @($Profile.blobs)) {
            if ($blob -isnot [pscustomobject]) {
                throw "Every blob must be an object."
            }
            $blobName = [string]$blob.name
            if ($blobName -notmatch "^[a-zA-Z0-9_]+$") {
                throw "A blob name is missing or invalid."
            }
            if ($blobName.StartsWith(
                "tpm_game_",
                [StringComparison]::OrdinalIgnoreCase
            )) {
                throw "Blob prefix 'tpm_game_' is reserved."
            }
            if (-not $blobNames.Add($blobName)) {
                throw "Duplicate blob name: $blobName"
            }
            if ($blob.path -isnot [string]) {
                throw "Blob '$blobName' path must be a string."
            }
            [void](Resolve-TrafficProfilePath `
                $AppRoot `
                ([string]$blob.path) `
                (Join-Path $AppRoot "assets") `
                "blobs.path")
        }
    }

    if ($Profile.rules -isnot [Array] -or @($Profile.rules).Count -eq 0) {
        throw "'rules' must be a non-empty array."
    }
    $ruleNames = New-Object "Collections.Generic.HashSet[string]" (
        [StringComparer]::OrdinalIgnoreCase
    )
    foreach ($rule in @($Profile.rules)) {
        if ($rule -isnot [pscustomobject]) {
            throw "Every rule must be an object."
        }
        $ruleName = [string]$rule.name
        if ($ruleName -notmatch "^[a-zA-Z0-9_-]{1,80}$") {
            throw "A rule name is missing or invalid."
        }
        if (-not $ruleNames.Add($ruleName)) {
            throw "Duplicate rule name: $ruleName"
        }
        if ($rule.PSObject.Properties.Name -contains "scope") {
            if ($rule.scope -isnot [string]) {
                throw "Rule '$ruleName' scope must be a string."
            }
            $scope = [string]$rule.scope
            if ($scope -notin @("first", "all", "targets")) {
                throw "Rule '$ruleName' has an invalid scope."
            }
        }
        foreach ($field in @("match", "actions")) {
            if ($rule.$field -isnot [Array]) {
                throw "Rule '$ruleName' field '$field' must be an array."
            }
            if ($field -eq "actions" -and @($rule.$field).Count -eq 0) {
                throw "Rule '$ruleName' has no actions."
            }
            foreach ($argument in @($rule.$field)) {
                if ($argument -isnot [string]) {
                    throw "Rule '$ruleName' contains a non-string '$field' argument."
                }
                $text = [string]$argument
                if (
                    [string]::IsNullOrWhiteSpace($text) -or
                    $text.Length -gt 4096 -or
                    $text -match "[\r\n]" -or
                    -not $text.StartsWith("--")
                ) {
                    throw "Rule '$ruleName' contains an invalid '$field' argument."
                }
            }
        }
    }
    return $true
}

function Get-TrafficProfiles {
    param(
        [Parameter(Mandatory = $true)]
        [string]$AppRoot,

        [switch]$IncludeInvalid
    )

    $profileRoot = Join-Path $AppRoot "config\profiles"
    if (-not (Test-Path -LiteralPath $profileRoot -PathType Container)) {
        return @()
    }

    $items = New-Object "Collections.Generic.List[object]"
    foreach ($file in Get-ChildItem -LiteralPath $profileRoot -Filter "*.json" -File) {
        try {
            $profile = Get-Content -Raw -LiteralPath $file.FullName |
                ConvertFrom-Json
            [void](Test-TrafficProfileDefinition `
                $profile `
                $file.FullName `
                $AppRoot)
            $id = [string]$profile.name

            $displayName = if (
                $profile.PSObject.Properties.Name -contains "displayName" -and
                -not [string]::IsNullOrWhiteSpace([string]$profile.displayName)
            ) {
                [string]$profile.displayName
            } else {
                $id
            }
            $description = if (
                $profile.PSObject.Properties.Name -contains "description"
            ) {
                [string]$profile.description
            } else {
                ""
            }
            $order = 10000
            if ($profile.PSObject.Properties.Name -contains "order") {
                $parsedOrder = 0
                if ([int]::TryParse([string]$profile.order, [ref]$parsedOrder)) {
                    $order = $parsedOrder
                }
            }

            $items.Add([pscustomobject]@{
                Id = $id
                DisplayName = $displayName
                Description = $description
                Order = $order
                Path = $file.FullName
                Valid = $true
                Error = ""
            })
        } catch {
            if ($IncludeInvalid) {
                $items.Add([pscustomobject]@{
                    Id = $file.BaseName
                    DisplayName = $file.BaseName
                    Description = ""
                    Order = [int]::MaxValue
                    Path = $file.FullName
                    Valid = $false
                    Error = $_.Exception.Message
                })
            }
        }
    }

    $sorted = @(
        $items |
            Sort-Object Order, DisplayName, Id
    )
    for ($index = 0; $index -lt $sorted.Count; $index++) {
        $sorted[$index] | Add-Member `
            -NotePropertyName Number `
            -NotePropertyValue ($index + 1) `
            -Force
    }
    return $sorted
}
