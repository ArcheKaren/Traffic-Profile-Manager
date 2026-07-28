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
            $id = [string]$profile.name
            if (-not $id -or $id -notmatch "^[a-zA-Z0-9_-]+$") {
                throw "The 'name' field is missing or invalid."
            }
            if ($id -ne $file.BaseName) {
                throw "The 'name' field must match the file name."
            }
            if (-not $profile.interception) {
                throw "The 'interception' section is missing."
            }
            if (@($profile.rules).Count -eq 0) {
                throw "The profile has no rules."
            }

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
