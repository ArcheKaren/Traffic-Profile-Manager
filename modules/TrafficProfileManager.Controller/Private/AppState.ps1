$script:Utf8NoBom = New-Object Text.UTF8Encoding($false)
$script:UserListTemplates = [ordered]@{
    "lists\user-domains.txt" = @(
        "# Custom domains. Add one domain per line."
        "# example.org"
    )
    "lists\user-domains-exclude.txt" = @(
        "# Custom domain exclusions. One domain per line."
        "# example.org"
    )
    "lists\user-ips.txt" = @(
        "# Custom IPv4, IPv6, and CIDR values. Add one entry per line."
        "# 203.0.113.10"
        "# 2001:db8::/32"
    )
    "lists\user-ips-exclude.txt" = @(
        "# Custom IP/CIDR exclusions. One entry per line."
        "# 203.0.113.0/24"
    )
}

function Get-AppPath([string]$RelativePath) {
    return [IO.Path]::GetFullPath((Join-Path $script:AppRoot $RelativePath))
}

function Write-AtomicLines([string]$Path, [string[]]$Lines) {
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $temporary = "$Path.$PID.tmp"
    [IO.File]::WriteAllLines($temporary, $Lines, $script:Utf8NoBom)
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function Write-AtomicText([string]$Path, [string]$Text) {
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $temporary = "$Path.$PID.tmp"
    [IO.File]::WriteAllText($temporary, $Text, $script:Utf8NoBom)
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function Write-JsonFile([string]$Path, $Value) {
    Write-AtomicText `
        $Path `
        (($Value | ConvertTo-Json -Depth 20) + [Environment]::NewLine)
}

function Read-JsonFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "File not found: $Path. Run 'zapretctl init' first."
    }
    return Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
}

function Initialize-UserLists {
    foreach ($item in $script:UserListTemplates.GetEnumerator()) {
        $path = Get-AppPath $item.Key
        if (Test-Path -LiteralPath $path -PathType Leaf) { continue }
        $parent = Split-Path -Parent $path
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        $temporary = "{0}.{1}.{2}.tmp" -f @(
            $path,
            $PID,
            [Guid]::NewGuid().ToString("N")
        )
        try {
            [IO.File]::WriteAllLines(
                $temporary,
                [string[]]$item.Value,
                $script:Utf8NoBom
            )
            try {
                [IO.File]::Move($temporary, $path)
            } catch [IO.IOException] {
                if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                    throw
                }
            }
        } finally {
            if (Test-Path -LiteralPath $temporary -PathType Leaf) {
                Remove-Item `
                    -LiteralPath $temporary `
                    -Force `
                    -ErrorAction SilentlyContinue
            }
        }
    }
}

function Write-ProcessIdentity(
    [Diagnostics.Process]$Process,
    [string]$Executable
) {
    $identity = [ordered]@{
        pid = $Process.Id
        startTimeUtcTicks = $Process.StartTime.ToUniversalTime().Ticks
        executable = [IO.Path]::GetFullPath($Executable)
    }
    Write-JsonFile (Get-AppPath "state\winws2.identity.json") $identity
}

function Remove-ProcessIdentity(
    [int]$ExpectedPid = 0,
    [int64]$ExpectedStartTicks = 0
) {
    $identityPath = Get-AppPath "state\winws2.identity.json"
    if (-not (Test-Path -LiteralPath $identityPath -PathType Leaf)) { return }
    if ($ExpectedPid -gt 0) {
        try {
            $identity = Read-JsonFile $identityPath
            if ([int]$identity.pid -ne $ExpectedPid) { return }
            if (
                $ExpectedStartTicks -gt 0 -and
                [int64]$identity.startTimeUtcTicks -ne $ExpectedStartTicks
            ) {
                return
            }
        } catch {
            return
        }
    }
    Remove-Item `
        -LiteralPath $identityPath `
        -Force `
        -ErrorAction SilentlyContinue
}

function Initialize-App {
    foreach ($directory in @(
        "config",
        "config\profiles",
        "config\game-filters",
        "lists",
        "lists\packs",
        "lists\user-packs",
        "logs",
        "runtime",
        "state"
    )) {
        New-Item `
            -ItemType Directory `
            -Path (Get-AppPath $directory) `
            -Force | Out-Null
    }

    $configPath = Get-AppPath "config\config.json"
    if (-not (Test-Path -LiteralPath $configPath)) {
        Write-JsonFile $configPath ([ordered]@{
            activeProfile = "strategy-wa-pc-pos1"
            runtimePath = ""
            allowAllWithoutTargets = $false
            autoHostlist = $false
            debug = $false
        })
    }

    $listHeaders = [ordered]@{
        "lists\domains.txt" = @(
            "# Domains handled by zapret2. One domain per line."
            "# example.org"
        )
        "lists\domains-exclude.txt" = @(
            "# Excluded domains. One domain per line."
        )
        "lists\domains-auto.txt" = @(
            "# Auto-detected domains. Do not edit while winws2 is running."
        )
        "lists\ips.txt" = @(
            "# IPv4, IPv6 or CIDR handled by zapret2. One entry per line."
            "# 203.0.113.0/24"
        )
        "lists\ips-exclude.txt" = @(
            "# Excluded IP/CIDR entries. One entry per line."
        )
    }
    foreach ($item in $listHeaders.GetEnumerator()) {
        $path = Get-AppPath $item.Key
        if (-not (Test-Path -LiteralPath $path)) {
            Write-AtomicLines $path $item.Value
        }
    }
    Initialize-UserLists
    if (Test-Path -LiteralPath (Get-AppPath "lists\catalog.json") -PathType Leaf) {
        [void](Sync-DomainCatalog $script:AppRoot)
    }

    Write-Host "Ready: $script:AppRoot"
    Write-Host "Add a target: zapretctl domain add example.org"
    Write-Host "Place the official Windows bundle in runtime and run: zapretctl doctor"
}

function Ensure-Initialized {
    if (-not (Test-Path -LiteralPath (Get-AppPath "config\config.json"))) {
        throw "The project is not initialized. Run 'zapretctl init'."
    }
    Initialize-UserLists
    if (Test-Path -LiteralPath (Get-AppPath "lists\catalog.json") -PathType Leaf) {
        [void](Sync-DomainCatalog $script:AppRoot)
    }
}

function Get-ListPath([string]$Kind, [bool]$Exclude) {
    if ($Kind -eq "domain") {
        return Get-AppPath $(if ($Exclude) {
            "lists\domains-exclude.txt"
        } else {
            "lists\user-domains.txt"
        })
    }
    return Get-AppPath $(if ($Exclude) {
        "lists\ips-exclude.txt"
    } else {
        "lists\user-ips.txt"
    })
}

function Normalize-ListValue([string]$Kind, [string]$Value) {
    if ($Kind -eq "domain") { return ConvertTo-TpmDomain $Value }
    return ConvertTo-TpmIpNetwork $Value
}

function Add-ListValue([string]$Kind, [string]$Value, [bool]$Exclude) {
    $path = Get-ListPath $Kind $Exclude
    $normalized = Normalize-ListValue $Kind $Value
    $lines = @(if (Test-Path -LiteralPath $path) {
        Get-Content -LiteralPath $path
    })
    if ($lines | Where-Object {
        $_.Trim().ToLowerInvariant() -eq $normalized.ToLowerInvariant()
    }) {
        Write-Host "Already present: $normalized"
        return
    }
    Write-AtomicLines $path @($lines + $normalized)
    Write-Host "Added: $normalized"
}

function Remove-ListValue([string]$Kind, [string]$Value, [bool]$Exclude) {
    $path = Get-ListPath $Kind $Exclude
    $normalized = Normalize-ListValue $Kind $Value
    $found = $false
    $lines = @(
        Get-Content -LiteralPath $path | Where-Object {
            if ($_.Trim().ToLowerInvariant() -eq $normalized.ToLowerInvariant()) {
                $found = $true
                return $false
            }
            return $true
        }
    )
    if (-not $found) {
        Write-Host "Not found: $normalized"
        return
    }
    Write-AtomicLines $path $lines
    Write-Host "Removed: $normalized"
}

function Import-List([string]$Kind, [string]$Source, [bool]$Exclude) {
    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) {
        throw "Import file not found: $Source"
    }
    $path = Get-ListPath $Kind $Exclude
    $existingLines = @(Get-Content -LiteralPath $path)
    $known = @{}
    foreach ($line in $existingLines) {
        $trimmed = $line.Trim()
        if ($trimmed -and -not $trimmed.StartsWith("#")) {
            $known[$trimmed.ToLowerInvariant()] = $true
        }
    }
    $added = New-Object Collections.Generic.List[string]
    $lineNumber = 0
    foreach ($line in Get-Content -LiteralPath $Source) {
        $lineNumber++
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith("#")) { continue }
        try {
            $normalized = Normalize-ListValue $Kind $trimmed
        } catch {
            throw "Error in '$Source', line $lineNumber`: $($_.Exception.Message)"
        }
        $key = $normalized.ToLowerInvariant()
        if (-not $known.ContainsKey($key)) {
            $known[$key] = $true
            $added.Add($normalized)
        }
    }
    $combined = New-Object Collections.Generic.List[string]
    foreach ($existingValue in $existingLines) {
        $combined.Add([string]$existingValue)
    }
    foreach ($newValue in $added) { $combined.Add([string]$newValue) }
    Write-AtomicLines $path $combined.ToArray()
    Write-Host "New entries imported: $($added.Count)"
}

function Invoke-ListCommand([string]$Kind, [string[]]$InputArgs) {
    Ensure-Initialized
    if (-not $InputArgs -or $InputArgs.Count -eq 0) {
        throw "Specify an action: add, remove, list, exclude, or import."
    }
    $action = $InputArgs[0].ToLowerInvariant()
    switch ($action) {
        "add" {
            if ($InputArgs.Count -lt 2) { throw "Specify a value." }
            Add-ListValue $Kind $InputArgs[1] $false
        }
        "remove" {
            if ($InputArgs.Count -lt 2) { throw "Specify a value." }
            Remove-ListValue $Kind $InputArgs[1] $false
        }
        "exclude" {
            if ($InputArgs.Count -lt 2) { throw "Specify a value." }
            $subAction = if ($InputArgs.Count -ge 3) {
                $InputArgs[1].ToLowerInvariant()
            } else { "add" }
            $valueIndex = if ($InputArgs.Count -ge 3) { 2 } else { 1 }
            if ($subAction -eq "remove") {
                Remove-ListValue $Kind $InputArgs[$valueIndex] $true
            } elseif ($subAction -eq "add") {
                Add-ListValue $Kind $InputArgs[$valueIndex] $true
            } else {
                throw "The exclude action accepts add or remove."
            }
        }
        "list" {
            $exclude = $InputArgs -contains "--exclude"
            $values = @(Get-TpmMeaningfulLines (Get-ListPath $Kind $exclude))
            if ($values.Count -eq 0) {
                Write-Host "(list is empty)"
                return
            }
            $values | ForEach-Object { Write-Output $_ }
        }
        "import" {
            if ($InputArgs.Count -lt 2) { throw "Specify an import file." }
            Import-List `
                $Kind `
                $InputArgs[1] `
                ($InputArgs -contains "--exclude")
        }
        default { throw "Unknown action '$action'." }
    }
}

function Get-Config {
    return Read-JsonFile (Get-AppPath "config\config.json")
}

function Save-Config($Config) {
    Write-JsonFile (Get-AppPath "config\config.json") $Config
}

function Get-ActiveProfile {
    $config = Get-Config
    $name = [string]$config.activeProfile
    if ($name -notmatch "^[a-zA-Z0-9_-]{1,64}$") {
        throw "config.json contains an invalid active profile name."
    }
    return Read-JsonFile (Get-AppPath "config\profiles\$name.json")
}

function Invoke-ProfileCommand([string[]]$InputArgs) {
    Ensure-Initialized
    $action = if ($InputArgs -and $InputArgs.Count) {
        $InputArgs[0].ToLowerInvariant()
    } else { "list" }
    switch ($action) {
        "list" {
            $config = Get-Config
            Get-ChildItem `
                -LiteralPath (Get-AppPath "config\profiles") `
                -Filter "*.json" |
                ForEach-Object {
                    $marker = if ($_.BaseName -eq $config.activeProfile) {
                        "*"
                    } else { " " }
                    Write-Output "$marker $($_.BaseName)"
                }
        }
        "use" {
            if ($InputArgs.Count -lt 2) { throw "Specify a profile name." }
            $name = $InputArgs[1]
            if ($name -notmatch "^[a-zA-Z0-9_-]+$") {
                throw "Invalid profile name."
            }
            if (-not (Test-Path -LiteralPath (
                Get-AppPath "config\profiles\$name.json"
            ))) {
                throw "Profile '$name' was not found."
            }
            $config = Get-Config
            $config.activeProfile = $name
            Save-Config $config
            Write-Host "Active profile: $name"
        }
        "show" {
            $profile = if ($InputArgs.Count -ge 2) {
                $name = [string]$InputArgs[1]
                if ($name -notmatch "^[a-zA-Z0-9_-]{1,64}$") {
                    throw "Invalid profile name."
                }
                Read-JsonFile (Get-AppPath "config\profiles\$name.json")
            } else {
                Get-ActiveProfile
            }
            $profile | ConvertTo-Json -Depth 20
        }
        default { throw "Unknown profile action '$action'." }
    }
}
