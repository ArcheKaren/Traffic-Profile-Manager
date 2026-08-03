function Get-TpmSchemaProperty($Object, [string]$Name) {
    if ($null -eq $Object -or $Object -isnot [pscustomobject]) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Test-TpmSchemaProperty($Object, [string]$Name) {
    return (
        $null -ne $Object -and
        $Object -is [pscustomobject] -and
        $null -ne $Object.PSObject.Properties[$Name]
    )
}

function Test-TpmJsonType($Value, [string]$TypeName) {
    switch ($TypeName) {
        "null" { return $null -eq $Value }
        "object" { return $Value -is [pscustomobject] }
        "array" { return $Value -is [Array] }
        "string" { return $Value -is [string] }
        "boolean" { return $Value -is [bool] }
        "integer" {
            return $Value -is [sbyte] -or $Value -is [byte] -or
                $Value -is [int16] -or $Value -is [uint16] -or
                $Value -is [int32] -or $Value -is [uint32] -or
                $Value -is [int64] -or $Value -is [uint64]
        }
        "number" {
            return (Test-TpmJsonType $Value "integer") -or
                $Value -is [single] -or $Value -is [double] -or
                $Value -is [decimal]
        }
        default { throw "Unsupported JSON Schema type: $TypeName" }
    }
}

function Resolve-TpmSchemaReference($RootSchema, [string]$Reference) {
    if (-not $Reference.StartsWith("#/")) {
        throw "Only local JSON Schema references are supported: $Reference"
    }
    $current = $RootSchema
    foreach ($rawPart in $Reference.Substring(2).Split("/")) {
        $part = $rawPart.Replace("~1", "/").Replace("~0", "~")
        if (-not (Test-TpmSchemaProperty $current $part)) {
            throw "JSON Schema reference was not found: $Reference"
        }
        $current = Get-TpmSchemaProperty $current $part
    }
    return $current
}

function Test-TpmJsonValueEqual($Left, $Right) {
    $leftJson = $Left | ConvertTo-Json -Depth 50 -Compress
    $rightJson = $Right | ConvertTo-Json -Depth 50 -Compress
    return $leftJson -ceq $rightJson
}

function Assert-TpmJsonSchemaNode(
    $Instance,
    $Schema,
    $RootSchema,
    [string]$Path
) {
    if ($Schema -is [bool]) {
        if (-not $Schema) { throw "$Path is rejected by the schema." }
        return
    }
    if ($Schema -isnot [pscustomobject]) {
        throw "The JSON Schema node at $Path is not an object."
    }

    if (Test-TpmSchemaProperty $Schema '$ref') {
        $resolved = Resolve-TpmSchemaReference `
            $RootSchema `
            ([string](Get-TpmSchemaProperty $Schema '$ref'))
        Assert-TpmJsonSchemaNode $Instance $resolved $RootSchema $Path
        return
    }

    if (Test-TpmSchemaProperty $Schema "allOf") {
        foreach ($candidate in @(Get-TpmSchemaProperty $Schema "allOf")) {
            Assert-TpmJsonSchemaNode $Instance $candidate $RootSchema $Path
        }
    }
    if (Test-TpmSchemaProperty $Schema "anyOf") {
        $matched = 0
        foreach ($candidate in @(Get-TpmSchemaProperty $Schema "anyOf")) {
            try {
                Assert-TpmJsonSchemaNode $Instance $candidate $RootSchema $Path
                $matched++
            } catch {}
        }
        if ($matched -eq 0) { throw "$Path does not match any allowed schema." }
    }
    if (Test-TpmSchemaProperty $Schema "oneOf") {
        $matched = 0
        foreach ($candidate in @(Get-TpmSchemaProperty $Schema "oneOf")) {
            try {
                Assert-TpmJsonSchemaNode $Instance $candidate $RootSchema $Path
                $matched++
            } catch {}
        }
        if ($matched -ne 1) {
            throw "$Path must match exactly one allowed schema; matched $matched."
        }
    }

    if (Test-TpmSchemaProperty $Schema "type") {
        $allowedTypes = @((Get-TpmSchemaProperty $Schema "type"))
        $typeMatched = $false
        foreach ($typeName in $allowedTypes) {
            if (Test-TpmJsonType $Instance ([string]$typeName)) {
                $typeMatched = $true
                break
            }
        }
        if (-not $typeMatched) {
            throw "$Path must have JSON type: $($allowedTypes -join ', ')."
        }
    }

    if (Test-TpmSchemaProperty $Schema "enum") {
        $enumMatched = $false
        foreach ($allowedValue in @(Get-TpmSchemaProperty $Schema "enum")) {
            if (Test-TpmJsonValueEqual $Instance $allowedValue) {
                $enumMatched = $true
                break
            }
        }
        if (-not $enumMatched) { throw "$Path contains a value outside enum." }
    }
    if (
        (Test-TpmSchemaProperty $Schema "const") -and
        -not (Test-TpmJsonValueEqual `
            $Instance `
            (Get-TpmSchemaProperty $Schema "const"))
    ) {
        throw "$Path does not match the required constant value."
    }

    if ($Instance -is [string]) {
        if (
            (Test-TpmSchemaProperty $Schema "minLength") -and
            $Instance.Length -lt [int](Get-TpmSchemaProperty $Schema "minLength")
        ) { throw "$Path is shorter than minLength." }
        if (
            (Test-TpmSchemaProperty $Schema "maxLength") -and
            $Instance.Length -gt [int](Get-TpmSchemaProperty $Schema "maxLength")
        ) { throw "$Path is longer than maxLength." }
        if (
            (Test-TpmSchemaProperty $Schema "pattern") -and
            $Instance -notmatch [string](Get-TpmSchemaProperty $Schema "pattern")
        ) { throw "$Path does not match the required pattern." }
    }

    if (Test-TpmJsonType $Instance "number") {
        if (
            (Test-TpmSchemaProperty $Schema "minimum") -and
            [decimal]$Instance -lt [decimal](Get-TpmSchemaProperty $Schema "minimum")
        ) { throw "$Path is below minimum." }
        if (
            (Test-TpmSchemaProperty $Schema "maximum") -and
            [decimal]$Instance -gt [decimal](Get-TpmSchemaProperty $Schema "maximum")
        ) { throw "$Path is above maximum." }
    }

    if ($Instance -is [Array]) {
        if (
            (Test-TpmSchemaProperty $Schema "minItems") -and
            $Instance.Count -lt [int](Get-TpmSchemaProperty $Schema "minItems")
        ) { throw "$Path has fewer items than minItems." }
        if (
            (Test-TpmSchemaProperty $Schema "maxItems") -and
            $Instance.Count -gt [int](Get-TpmSchemaProperty $Schema "maxItems")
        ) { throw "$Path has more items than maxItems." }
        if (
            (Test-TpmSchemaProperty $Schema "uniqueItems") -and
            [bool](Get-TpmSchemaProperty $Schema "uniqueItems")
        ) {
            $seen = @{}
            foreach ($item in $Instance) {
                $key = $item | ConvertTo-Json -Depth 50 -Compress
                if ($seen.ContainsKey($key)) { throw "$Path contains duplicate items." }
                $seen[$key] = $true
            }
        }
        if (Test-TpmSchemaProperty $Schema "items") {
            $itemSchema = Get-TpmSchemaProperty $Schema "items"
            for ($index = 0; $index -lt $Instance.Count; $index++) {
                Assert-TpmJsonSchemaNode `
                    $Instance[$index] `
                    $itemSchema `
                    $RootSchema `
                    "$Path[$index]"
            }
        }
    }

    if ($Instance -is [pscustomobject]) {
        if (Test-TpmSchemaProperty $Schema "required") {
            foreach ($requiredName in @(Get-TpmSchemaProperty $Schema "required")) {
                if (-not (Test-TpmSchemaProperty $Instance ([string]$requiredName))) {
                    throw "$Path is missing required property '$requiredName'."
                }
            }
        }
        $propertySchemas = Get-TpmSchemaProperty $Schema "properties"
        foreach ($property in $Instance.PSObject.Properties) {
            $propertySchema = if (
                $null -ne $propertySchemas -and
                (Test-TpmSchemaProperty $propertySchemas $property.Name)
            ) {
                Get-TpmSchemaProperty $propertySchemas $property.Name
            } else { $null }
            if ($null -ne $propertySchema) {
                Assert-TpmJsonSchemaNode `
                    $property.Value `
                    $propertySchema `
                    $RootSchema `
                    "$Path.$($property.Name)"
                continue
            }
            if (Test-TpmSchemaProperty $Schema "additionalProperties") {
                $additional = Get-TpmSchemaProperty $Schema "additionalProperties"
                if ($additional -is [bool] -and -not $additional) {
                    throw "$Path contains unknown property '$($property.Name)'."
                }
                if ($additional -is [pscustomobject]) {
                    Assert-TpmJsonSchemaNode `
                        $property.Value `
                        $additional `
                        $RootSchema `
                        "$Path.$($property.Name)"
                }
            }
        }
    }
}

function Assert-TpmJsonSchema {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Instance,

        [Parameter(Mandatory = $true)]
        [string]$SchemaPath
    )
    if (-not (Test-Path -LiteralPath $SchemaPath -PathType Leaf)) {
        throw "JSON Schema file was not found: $SchemaPath"
    }
    $schema = Get-Content -Raw -LiteralPath $SchemaPath | ConvertFrom-Json
    try {
        Assert-TpmJsonSchemaNode $Instance $schema $schema '$'
    } catch {
        throw "JSON Schema validation failed: $($_.Exception.Message)"
    }
    return $true
}

Export-ModuleMember -Function "Assert-TpmJsonSchema"
