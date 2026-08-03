Import-Module (
    Join-Path `
        (Split-Path -Parent $PSScriptRoot) `
        "modules\TrafficProfileManager.JsonSchema\TrafficProfileManager.JsonSchema.psd1"
) -ErrorAction Stop

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

function Get-TrafficProfileRuleGroups([string]$AppRoot) {
    $path = Join-Path $AppRoot "config\rule-groups.json"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return @{}
    }
    $document = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json
    if ([int]$document.schemaVersion -ne 1 -or $document.matchGroups -isnot [pscustomobject]) {
        throw "config\rule-groups.json has an unsupported structure."
    }
    $result = @{}
    foreach ($property in $document.matchGroups.PSObject.Properties) {
        $id = [string]$property.Name
        if ($id -notmatch "^[a-zA-Z0-9_-]{1,80}$" -or $result.ContainsKey($id)) {
            throw "Invalid or duplicate rule group: $id"
        }
        if ($property.Value -isnot [Array] -or @($property.Value).Count -eq 0) {
            throw "Rule group '$id' must be a non-empty array."
        }
        $arguments = @()
        foreach ($argument in @($property.Value)) {
            if ($argument -isnot [string]) {
                throw "Rule group '$id' contains a non-string argument."
            }
            $text = [string]$argument
            if (
                [string]::IsNullOrWhiteSpace($text) -or
                $text.Length -gt 4096 -or
                $text -match "[\r\n]" -or
                -not $text.StartsWith("--")
            ) {
                throw "Rule group '$id' contains an invalid argument."
            }
            $arguments += $text
        }
        $result[$id] = $arguments
    }
    return $result
}

function Resolve-TrafficProfileDefinition(
    [object]$Profile,
    [string]$AppRoot
) {
    $copy = $Profile | ConvertTo-Json -Depth 30 | ConvertFrom-Json
    $groups = Get-TrafficProfileRuleGroups $AppRoot
    foreach ($rule in @($copy.rules)) {
        $hasMatch = $rule.PSObject.Properties.Name -contains "match"
        $hasGroup = $rule.PSObject.Properties.Name -contains "matchGroup"
        if ($hasMatch -eq $hasGroup) {
            throw "Rule '$($rule.name)' must define exactly one of 'match' or 'matchGroup'."
        }
        if ($hasGroup) {
            $id = [string]$rule.matchGroup
            if (-not $groups.ContainsKey($id)) {
                throw "Rule '$($rule.name)' references unknown match group '$id'."
            }
            $rule.PSObject.Properties.Remove("matchGroup")
            $rule | Add-Member -NotePropertyName match -NotePropertyValue @($groups[$id])
        }
    }
    return $copy
}

function Test-TrafficProfileDefinition(
    [object]$Profile,
    [string]$ProfilePath,
    [string]$AppRoot
) {
    $schemaPath = Join-Path `
        $AppRoot `
        "config\schemas\traffic-profile.schema.json"
    if (-not (Test-Path -LiteralPath $schemaPath -PathType Leaf)) {
        $moduleSchemaPath = Join-Path `
            (Split-Path -Parent $PSScriptRoot) `
            "config\schemas\traffic-profile.schema.json"
        if (Test-Path -LiteralPath $moduleSchemaPath -PathType Leaf) {
            $schemaPath = $moduleSchemaPath
        }
    }
    [void](Assert-TpmJsonSchema -Instance $Profile -SchemaPath $schemaPath)

    $id = [string]$Profile.name
    if ($id -cne [IO.Path]::GetFileNameWithoutExtension($ProfilePath)) {
        throw "The 'name' field must match the file name."
    }
    foreach ($field in @("tcpOut", "udpOut", "tcpIn", "udpIn")) {
        if ($Profile.interception.PSObject.Properties.Name -contains $field) {
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
        foreach ($relativePath in @($Profile.interception.rawParts)) {
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
        foreach ($blob in @($Profile.blobs)) {
            $blobName = [string]$blob.name
            if ($blobName.StartsWith(
                "tpm_game_",
                [StringComparison]::OrdinalIgnoreCase
            )) {
                throw "Blob prefix 'tpm_game_' is reserved."
            }
            if (-not $blobNames.Add($blobName)) {
                throw "Duplicate blob name: $blobName"
            }
            [void](Resolve-TrafficProfilePath `
                $AppRoot `
                ([string]$blob.path) `
                (Join-Path $AppRoot "assets") `
                "blobs.path")
        }
    }

    $ruleNames = New-Object "Collections.Generic.HashSet[string]" (
        [StringComparer]::OrdinalIgnoreCase
    )
    $matchGroups = Get-TrafficProfileRuleGroups $AppRoot
    foreach ($rule in @($Profile.rules)) {
        $ruleName = [string]$rule.name
        if (-not $ruleNames.Add($ruleName)) {
            throw "Duplicate rule name: $ruleName"
        }
        $hasGroup = $rule.PSObject.Properties.Name -contains "matchGroup"
        if ($hasGroup) {
            $groupId = [string]$rule.matchGroup
            if (-not $matchGroups.ContainsKey($groupId)) {
                throw "Rule '$ruleName' references unknown match group '$groupId'."
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
