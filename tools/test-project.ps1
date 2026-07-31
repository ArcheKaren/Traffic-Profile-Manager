[CmdletBinding()]
param(
    [string]$AppRoot = "",
    [switch]$SkipRuntimeCheck
)

$ErrorActionPreference = "Stop"
$projectRoot = if ($AppRoot) {
    [IO.Path]::GetFullPath($AppRoot)
} else {
    Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
}
$failures = New-Object "Collections.Generic.List[string]"
$warnings = New-Object "Collections.Generic.List[string]"

function Add-Failure([string]$Message) {
    $failures.Add($Message)
    Write-Host "[FAIL] $Message" -ForegroundColor Red
}

function Add-Warning([string]$Message) {
    $warnings.Add($Message)
    Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function Add-Success([string]$Message) {
    Write-Host "[OK]   $Message" -ForegroundColor Green
}

function Get-ProjectPath([string]$RelativePath) {
    return [IO.Path]::GetFullPath((Join-Path $projectRoot $RelativePath))
}

function Get-MeaningfulLines([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
    return @(
        Get-Content -LiteralPath $Path |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -and -not $_.StartsWith("#") }
    )
}

Write-Host "Traffic Profile Manager project checks" -ForegroundColor Cyan
Write-Host "Root: $projectRoot"
Write-Host ""

$requiredPaths = @(
    "LICENSE"
    "README.md"
    "THIRD-PARTY-LICENSES.txt"
    "Manager.bat"
    "zapretctl.ps1"
    "manage-network-mappings.ps1"
    "runtime\SOURCE.json"
    "config\config.json"
    "config\game-filters"
    "config\profiles"
    "docs\GAME_FILTERS.md"
    "lists\domains.txt"
    "lists\domains-exclude.txt"
    "tests\targets.txt"
    "tools\profile-library.ps1"
    "tools\profile-manager.ps1"
    "tools\profile-benchmark.ps1"
    "tools\game-filter-library.ps1"
    "tools\game-filter-manager.ps1"
    "tools\service-control.ps1"
)
$missingPaths = @(
    $requiredPaths |
        Where-Object { -not (Test-Path -LiteralPath (Get-ProjectPath $_)) }
)
if ($missingPaths.Count) {
    foreach ($path in $missingPaths) { Add-Failure "Required path is missing: $path" }
} else {
    Add-Success "Required project files"
}

$excludedRoots = @(
    "release\"
    "runtime\"
    "state\"
    "logs\"
    "test-results\"
)
$scriptFiles = @(
    Get-ChildItem -LiteralPath $projectRoot -Filter "*.ps1" -File -Recurse |
        Where-Object {
            $relative = $_.FullName.Substring($projectRoot.Length + 1)
            -not @(
                $excludedRoots |
                    Where-Object {
                        $relative.StartsWith(
                            $_,
                            [StringComparison]::OrdinalIgnoreCase
                        )
                    }
            ).Count
        }
)
$parseFailureCount = 0
foreach ($file in $scriptFiles) {
    $tokens = $null
    $parseErrors = $null
    [void][Management.Automation.Language.Parser]::ParseFile(
        $file.FullName,
        [ref]$tokens,
        [ref]$parseErrors
    )
    foreach ($parseError in $parseErrors) {
        Add-Failure (
            "PowerShell syntax: {0}:{1}: {2}" -f
            $file.FullName.Substring($projectRoot.Length + 1),
            $parseError.Extent.StartLineNumber,
            $parseError.Message
        )
        $parseFailureCount++
    }
}
if ($parseFailureCount -eq 0) {
    Add-Success "PowerShell syntax ($($scriptFiles.Count) files)"
}

$profileLibrary = Get-ProjectPath "tools\profile-library.ps1"
if (Test-Path -LiteralPath $profileLibrary -PathType Leaf) {
    . $profileLibrary
    $profileFiles = @(
        Get-ChildItem `
            -LiteralPath (Get-ProjectPath "config\profiles") `
            -Filter "*.json" `
            -File
    )
    $profiles = @(Get-TrafficProfiles $projectRoot -IncludeInvalid)
    foreach ($profile in @($profiles | Where-Object { -not $_.Valid })) {
        Add-Failure "Invalid profile '$($profile.Id)': $($profile.Error)"
    }
    $validProfiles = @($profiles | Where-Object Valid)
    $runtimeBlobNames = @(
        "fake_default_http"
        "fake_default_tls"
    )
    if ($validProfiles.Count -ne $profileFiles.Count) {
        Add-Failure (
            "Profile catalog contains {0} valid entries for {1} JSON files." -f
            $validProfiles.Count,
            $profileFiles.Count
        )
    } elseif ($validProfiles.Count) {
        Add-Success "Dynamic profile catalog ($($validProfiles.Count) profiles)"
    }

    $orders = @{}
    foreach ($profile in $validProfiles) {
        if ($orders.ContainsKey($profile.Order)) {
            Add-Warning (
                "Profiles '$($orders[$profile.Order])' and '$($profile.Id)' " +
                "use the same order value $($profile.Order)."
            )
        } else {
            $orders[$profile.Order] = $profile.Id
        }

        $json = Get-Content -Raw -LiteralPath $profile.Path | ConvertFrom-Json
        $blobNames = New-Object "Collections.Generic.HashSet[string]" (
            [StringComparer]::OrdinalIgnoreCase
        )
        foreach ($blob in @($json.blobs)) {
            $blobName = [string]$blob.name
            if (-not $blobName -or -not $blobNames.Add($blobName)) {
                Add-Failure "Profile '$($profile.Id)' contains an empty or duplicate blob name."
                continue
            }
            $blobPath = [IO.Path]::GetFullPath(
                (Join-Path $projectRoot ([string]$blob.path))
            )
            $rootPrefix = $projectRoot.TrimEnd("\") + "\"
            if (-not $blobPath.StartsWith(
                $rootPrefix,
                [StringComparison]::OrdinalIgnoreCase
            )) {
                Add-Failure "Profile '$($profile.Id)' references a blob outside the project."
            } elseif (-not (Test-Path -LiteralPath $blobPath -PathType Leaf)) {
                Add-Failure "Profile '$($profile.Id)' blob was not found: $($blob.path)"
            }
        }

        foreach ($rule in @($json.rules)) {
            if (-not [string]$rule.name) {
                Add-Failure "Profile '$($profile.Id)' contains an unnamed rule."
            }
            if (@($rule.actions).Count -eq 0) {
                Add-Failure "Profile '$($profile.Id)' rule '$($rule.name)' has no actions."
            }
            foreach ($action in @($rule.actions)) {
                foreach ($match in [regex]::Matches([string]$action, "blob=([a-zA-Z0-9_-]+)")) {
                    if (
                        -not $blobNames.Contains($match.Groups[1].Value) -and
                        $match.Groups[1].Value -notin $runtimeBlobNames
                    ) {
                        Add-Failure (
                            "Profile '$($profile.Id)' rule '$($rule.name)' references " +
                            "unknown blob '$($match.Groups[1].Value)'."
                        )
                    }
                }
            }
        }

        $renderOutput = & powershell.exe `
            -NoLogo `
            -NoProfile `
            -ExecutionPolicy Bypass `
            -File (Get-ProjectPath "zapretctl.ps1") `
            render `
            $profile.Id 2>&1
        if ($LASTEXITCODE -ne 0) {
            Add-Failure (
                "Profile '$($profile.Id)' could not be rendered: " +
                ($renderOutput -join " ")
            )
        }
    }
    if (-not @($failures | Where-Object { $_ -match "^Profile " }).Count) {
        Add-Success "Profile structure, blobs, and rendered arguments"
    }

    try {
        $config = Get-Content -Raw -LiteralPath (Get-ProjectPath "config\config.json") |
            ConvertFrom-Json
        if ($config.activeProfile -notin $validProfiles.Id) {
            Add-Failure "config.json selects an unknown active profile."
        } else {
            Add-Success "Main configuration"
        }
    } catch {
        Add-Failure "Invalid config.json: $($_.Exception.Message)"
    }

    $launcherIds = New-Object "Collections.Generic.HashSet[string]" (
        [StringComparer]::OrdinalIgnoreCase
    )
    $launchers = @(
        Get-ChildItem -LiteralPath $projectRoot -Filter "*.bat" -File |
            Where-Object Name -Match "^\d+\s+-\s+"
    )
    foreach ($launcher in $launchers) {
        $content = Get-Content -Raw -LiteralPath $launcher.FullName
        if ($launcher.Name -notmatch "^(?<order>\d+)\s+-\s+") {
            Add-Failure "Invalid direct profile launcher: $($launcher.Name)"
            continue
        }
        $launcherOrder = [int]$Matches.order
        if ($content -notmatch 'run-profile\.bat"\s+(?<id>[a-zA-Z0-9_-]+)') {
            Add-Failure "Invalid direct profile launcher: $($launcher.Name)"
            continue
        }
        $launcherProfileId = $Matches.id
        $profile = $validProfiles |
            Where-Object Id -eq $launcherProfileId |
            Select-Object -First 1
        if (-not $profile) {
            Add-Failure "Launcher '$($launcher.Name)' selects an unknown profile."
        } elseif ($launcherOrder -ne $profile.Order) {
            Add-Failure "Launcher '$($launcher.Name)' does not match profile order."
        } else {
            $expectedLauncherName = "{0} - {1}.bat" -f @(
                $profile.Order,
                $profile.DisplayName
            )
            if ($launcher.Name -cne $expectedLauncherName) {
                Add-Failure (
                    "Launcher '$($launcher.Name)' should be named " +
                    "'$expectedLauncherName'."
                )
            }
        }
        if (-not $launcherIds.Add($launcherProfileId)) {
            Add-Failure "Multiple launchers select profile '$launcherProfileId'."
        }
    }
    if ($launchers.Count -ne $validProfiles.Count) {
        Add-Failure (
            "Direct launcher count $($launchers.Count) does not match " +
            "profile count $($validProfiles.Count)."
        )
    }
    foreach ($profile in $validProfiles) {
        if (-not $launcherIds.Contains($profile.Id)) {
            Add-Failure "No direct launcher selects profile '$($profile.Id)'."
        }
    }
    if (
        $launchers.Count -eq $validProfiles.Count -and
        -not @($failures | Where-Object { $_ -match "launcher" }).Count
    ) {
        Add-Success "Direct profile launchers ($($launchers.Count) files)"
    }

    foreach ($relativePath in @(
        "Manager.bat"
        "tools\profile-benchmark.ps1"
        "tools\validate-profiles.ps1"
    )) {
        $content = Get-Content -Raw -LiteralPath (Get-ProjectPath $relativePath)
        if ($content -match "strategy-wa-pc-pos1|strategy-current-default") {
            Add-Failure "Bundled profile IDs are hardcoded in $relativePath."
        }
    }
    if (-not @($failures | Where-Object { $_ -match "hardcoded" }).Count) {
        Add-Success "Dynamic manager, benchmark, and validator catalogs"
    }
}

$domainLists = @(
    "lists\domains.txt"
    "lists\domains-exclude.txt"
    "lists\user-domains.txt"
    "lists\user-domains-exclude.txt"
)
$listEntryCount = 0
foreach ($relativePath in $domainLists) {
    $seen = New-Object "Collections.Generic.HashSet[string]" (
        [StringComparer]::OrdinalIgnoreCase
    )
    foreach ($value in Get-MeaningfulLines (Get-ProjectPath $relativePath)) {
        $listEntryCount++
        $domain = $value.TrimStart("^").TrimEnd(".")
        $valid = $domain.Length -le 253 -and
            $domain -match "^[a-zA-Z0-9.-]+$" -and
            -not @(
                $domain.Split(".") |
                    Where-Object {
                        -not $_ -or
                        $_.Length -gt 63 -or
                        $_.StartsWith("-") -or
                        $_.EndsWith("-")
                    }
            ).Count
        if (-not $valid) {
            Add-Failure "Invalid domain in ${relativePath}: $value"
        }
        if (-not $seen.Add($value)) {
            Add-Failure "Duplicate domain in ${relativePath}: $value"
        }
    }
}

$ipLists = @(
    "lists\ips.txt"
    "lists\ips-exclude.txt"
    "lists\user-ips.txt"
    "lists\user-ips-exclude.txt"
)
foreach ($relativePath in $ipLists) {
    $seen = New-Object "Collections.Generic.HashSet[string]" (
        [StringComparer]::OrdinalIgnoreCase
    )
    foreach ($value in Get-MeaningfulLines (Get-ProjectPath $relativePath)) {
        $listEntryCount++
        $parts = $value.Split("/")
        $address = $null
        $valid = $parts.Count -le 2 -and
            [Net.IPAddress]::TryParse($parts[0], [ref]$address)
        if ($valid -and $parts.Count -eq 2) {
            $prefix = 0
            $maximum = if (
                $address.AddressFamily -eq
                [Net.Sockets.AddressFamily]::InterNetwork
            ) { 32 } else { 128 }
            $valid = [int]::TryParse($parts[1], [ref]$prefix) -and
                $prefix -ge 0 -and
                $prefix -le $maximum
        }
        if (-not $valid) {
            Add-Failure "Invalid IP/CIDR in ${relativePath}: $value"
        }
        if (-not $seen.Add($value)) {
            Add-Failure "Duplicate IP/CIDR in ${relativePath}: $value"
        }
    }
}
if (-not @($failures | Where-Object { $_ -match "in lists\\" }).Count) {
    Add-Success "Target and exclusion lists ($listEntryCount entries)"
}

$gameFilterLibrary = Get-ProjectPath "tools\game-filter-library.ps1"
if (Test-Path -LiteralPath $gameFilterLibrary -PathType Leaf) {
    . $gameFilterLibrary
    try {
        $gameFilters = @(Get-GameFilters $projectRoot -IncludeInvalid)
        foreach ($filter in @($gameFilters | Where-Object { -not $_.Valid })) {
            Add-Failure "Invalid game filter '$($filter.Id)': $($filter.Error)"
        }
        try {
            [void]@(Get-EnabledGameFilters $projectRoot -ThrowOnInvalid)
        } catch {
            Add-Failure "Invalid enabled game filter state: $($_.Exception.Message)"
        }
        if (-not @(
            $failures |
                Where-Object {
                    $_ -match "game filter"
                }
        ).Count) {
            Add-Success "Dynamic game filter catalog ($($gameFilters.Count) filters)"
        }
    } catch {
        Add-Failure "Game filter catalog could not be read: $($_.Exception.Message)"
    }
}

foreach ($relativePath in @("tests\targets.txt")) {
    $targetNames = New-Object "Collections.Generic.HashSet[string]" (
        [StringComparer]::OrdinalIgnoreCase
    )
    foreach ($line in Get-MeaningfulLines (Get-ProjectPath $relativePath)) {
        if ($line -notmatch '^(?<name>[A-Za-z0-9_-]+)\s*=\s*"(?<url>https://[^"]+)"\s*$') {
            Add-Failure "Invalid endpoint definition in ${relativePath}: $line"
            continue
        }
        $uri = $null
        if (-not [Uri]::TryCreate($Matches.url, [UriKind]::Absolute, [ref]$uri)) {
            Add-Failure "Invalid endpoint URL in ${relativePath}: $($Matches.url)"
        }
        if (-not $targetNames.Add($Matches.name)) {
            Add-Failure "Duplicate endpoint name in ${relativePath}: $($Matches.name)"
        }
    }
}
if (-not @($failures | Where-Object { $_ -match "endpoint" }).Count) {
    Add-Success "Comparison endpoint pools"
}

if (-not $SkipRuntimeCheck) {
    $runtimeFiles = [ordered]@{
        "winws2" = "runtime\winws2.exe"
        "winDivertDll" = "runtime\WinDivert.dll"
        "winDivertDriver" = "runtime\WinDivert64.sys"
        "cygwin" = "runtime\cygwin1.dll"
        "luaLib" = "runtime\lua\zapret-lib.lua"
        "luaAntidpi" = "runtime\lua\zapret-antidpi.lua"
    }
    $missingRuntime = @(
        $runtimeFiles.Values |
            Where-Object {
                -not (Test-Path -LiteralPath (Get-ProjectPath $_) -PathType Leaf)
            }
    )
    if ($missingRuntime.Count) {
        foreach ($path in $missingRuntime) {
            Add-Failure "Runtime component is missing: $path"
        }
    } else {
        try {
            $sourceManifest = Get-Content -Raw -LiteralPath (
                Get-ProjectPath "runtime\SOURCE.json"
            ) | ConvertFrom-Json
            foreach ($item in $runtimeFiles.GetEnumerator()) {
                $property = $sourceManifest.runtimeFiles.PSObject.Properties[
                    [string]$item.Key
                ]
                $expected = if ($property) { $property.Value } else { $null }
                if (
                    -not $expected -or
                    [string]$expected.sha256 -notmatch "^[A-Fa-f0-9]{64}$"
                ) {
                    throw "Missing provenance entry '$($item.Key)'."
                }
                $path = Get-ProjectPath ([string]$item.Value)
                $file = Get-Item -LiteralPath $path
                if (
                    $file.Length -ne [int64]$expected.length -or
                    (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine
                        [string]$expected.sha256
                ) {
                    throw "Runtime provenance mismatch: $($item.Value)"
                }
            }
            Add-Success "Portable runtime components and provenance"
        } catch {
            Add-Failure "Runtime provenance validation failed: $($_.Exception.Message)"
        }
    }
}

if ($failures.Count) {
    Write-Host ""
    Write-Host "Project checks failed: $($failures.Count)." -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host (
    "All project checks passed. Warnings: {0}." -f $warnings.Count
) -ForegroundColor Green
exit 0
