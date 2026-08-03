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

Write-Host "Traffic Profile Manager project checks" -ForegroundColor Cyan
Write-Host "Root: $projectRoot"
Write-Host ""

Import-Module (
    Get-ProjectPath `
        "modules\TrafficProfileManager.Core\TrafficProfileManager.Core.psd1"
) -Force -ErrorAction Stop

$requiredPaths = @(
    "LICENSE"
    "README.md"
    "THIRD-PARTY-LICENSES.txt"
    "Manager.bat"
    "zapretctl.ps1"
    "manage-network-mappings.ps1"
    "runtime\SOURCE.json"
    "config\config.json"
    "config\diagnostic-targets.json"
    "config\game-filters"
    "config\network-mappings"
    "config\profiles"
    "config\schemas\traffic-profile.schema.json"
    "config\rule-groups.json"
    "docs\DIAGNOSTICS.md"
    "docs\DOMAIN_PACKS.md"
    "docs\GAME_FILTERS.md"
    "lists\domains.txt"
    "lists\catalog.json"
    "lists\packs"
    "lists\domains-exclude.txt"
    "tests\targets.txt"
    "tools\profile-library.ps1"
    "tools\profile-manager.ps1"
    "tools\profile-benchmark.ps1"
    "tools\game-filter-library.ps1"
    "tools\game-filter-manager.ps1"
    "tools\catalog-library.ps1"
    "tools\domain-pack-manager.ps1"
    "tools\network-mapping-library.ps1"
    "tools\application-diagnostics.ps1"
    "tools\service-control.ps1"
    "modules\TrafficProfileManager.Core\TrafficProfileManager.Core.psd1"
    "modules\TrafficProfileManager.Controller\TrafficProfileManager.Controller.psd1"
    "modules\TrafficProfileManager.Controller\Private\AppState.ps1"
    "modules\TrafficProfileManager.Controller\Private\WinwsArguments.ps1"
    "modules\TrafficProfileManager.Controller\Private\RuntimeProcess.ps1"
    "modules\TrafficProfileManager.Profile\TrafficProfileManager.Profile.psd1"
    "modules\TrafficProfileManager.JsonSchema\TrafficProfileManager.JsonSchema.psd1"
    "modules\TrafficProfileManager.Operations\TrafficProfileManager.Operations.psd1"
)
$sourceCheckout = Test-Path -LiteralPath (
    Get-ProjectPath ".git"
) -PathType Container
if ($sourceCheckout) {
    $requiredPaths += @(
        ".github\workflows\release.yml"
        ".github\workflows\validate.yml"
    )
}
$missingPaths = @(
    $requiredPaths |
        Where-Object { -not (Test-Path -LiteralPath (Get-ProjectPath $_)) }
)
if ($missingPaths.Count) {
    foreach ($path in $missingPaths) { Add-Failure "Required path is missing: $path" }
} else {
    Add-Success "Required project files"
}

$workflowPinFailures = 0
if ($sourceCheckout) {
    foreach ($relativePath in @(
        ".github\workflows\release.yml"
        ".github\workflows\validate.yml"
    )) {
        $content = Get-Content -Raw -LiteralPath (Get-ProjectPath $relativePath)
        foreach ($match in [regex]::Matches(
            $content,
            "(?m)^\s*uses:\s*actions/checkout@(?<reference>\S+)"
        )) {
            if ($match.Groups["reference"].Value -notmatch "^[a-fA-F0-9]{40}$") {
                Add-Failure "Unpinned actions/checkout reference in $relativePath."
                $workflowPinFailures++
            }
        }
    }
    if ($workflowPinFailures -eq 0) {
        Add-Success "Immutable GitHub Action references"
    }
}

$excludedRoots = @(
    "release\"
    "runtime\"
    "state\"
    "logs\"
    "test-results\"
)
$scriptFiles = @(
    Get-ChildItem -LiteralPath $projectRoot -File -Recurse |
        Where-Object {
            $relative = $_.FullName.Substring($projectRoot.Length + 1)
            $_.Extension -in @(".ps1", ".psm1", ".psd1") -and
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

$controllerEntryPath = Get-ProjectPath "zapretctl.ps1"
$controllerEntryLines = @(Get-Content -LiteralPath $controllerEntryPath).Count
$controllerEntryContent = Get-Content -Raw -LiteralPath $controllerEntryPath
$controllerPrivateRoot = Get-ProjectPath `
    "modules\TrafficProfileManager.Controller\Private"
$oversizedControllerComponents = @(
    Get-ChildItem -LiteralPath $controllerPrivateRoot -Filter "*.ps1" -File |
        Where-Object { @(Get-Content -LiteralPath $_.FullName).Count -gt 500 }
)
if (
    $controllerEntryLines -gt 80 -or
    $controllerEntryContent -match '(?m)^function\s+' -or
    $oversizedControllerComponents.Count
) {
    Add-Failure (
        "Controller architecture boundary failed: zapretctl must remain a " +
        "thin entry point and private components must stay below 500 lines."
    )
} else {
    Add-Success "Thin CLI entry point and bounded controller components"
}

$cmdWrapper = Get-Content -Raw -LiteralPath (Get-ProjectPath "zapretctl.cmd")
$managerBatch = Get-Content -Raw -LiteralPath (Get-ProjectPath "Manager.bat")
$profileRunner = Get-Content -Raw -LiteralPath (
    Get-ProjectPath "tools\run-profile.bat"
)
if (
    $cmdWrapper.Contains("%*") -or
    $managerBatch -match '%(?:menu_choice|list_choice)%' -or
    $profileRunner -notmatch '\^\[A-Za-z0-9_-\]\{1,64\}\$'
) {
    Add-Failure (
        "Batch argument boundary failed: wrappers must not re-expand raw " +
        "arguments or unvalidated menu/profile input."
    )
} else {
    Add-Success "Safe batch argument boundaries"
}

$profileModule = Get-ProjectPath `
    "modules\TrafficProfileManager.Profile\TrafficProfileManager.Profile.psd1"
if (Test-Path -LiteralPath $profileModule -PathType Leaf) {
    Import-Module $profileModule -Force -ErrorAction Stop
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
        try {
            $json = Resolve-TrafficProfileDefinition $json $projectRoot
        } catch {
            Add-Failure "Profile '$($profile.Id)' could not resolve shared rules: $($_.Exception.Message)"
            continue
        }
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

    $serviceControl = Get-Content -Raw -LiteralPath (
        Get-ProjectPath "tools\service-control.ps1"
    )
    foreach ($requiredSnapshotPath in @(
        "zapretctl.ps1"
        "config\rule-groups.json"
        "config\schemas"
        "config\network-mappings"
        "modules"
        "tools\profile-library.ps1"
        "tools\network-mapping-library.ps1"
        "state\universal-game-transport.json"
    )) {
        if (-not $serviceControl.Contains($requiredSnapshotPath)) {
            Add-Failure "Protected service snapshot omits $requiredSnapshotPath."
        }
    }
    if (-not @($failures | Where-Object { $_ -match "service snapshot" }).Count) {
        Add-Success "Protected service snapshot dependencies"
    }
    if (
        $serviceControl -match '(?m)^\.\s+.*zapretctl\.ps1' -or
        $serviceControl.Contains('$script:AppRoot = $serviceRoot') -or
        $serviceControl.Contains('Ensure-Initialized') -or
        $serviceControl.Contains('Test-IsAdministrator') -or
        -not $serviceControl.Contains('Invoke-TpmControllerCommand') -or
        -not $serviceControl.Contains('"launch-spec"')
    ) {
        Add-Failure (
            "Service control must consume the versioned launch-spec API " +
            "without loading controller internals."
        )
    } else {
        Add-Success "Narrow service-to-runtime launch API"
    }
}

$catalogLibrary = Get-ProjectPath "tools\catalog-library.ps1"
if (Test-Path -LiteralPath $catalogLibrary -PathType Leaf) {
    . $catalogLibrary
    try {
        $catalogResult = Sync-DomainCatalog $projectRoot -CheckOnly
        if (-not $catalogResult.Synchronized) {
            Add-Failure "lists\domains.txt is not synchronized with the enabled domain packs."
        } else {
            Add-Success (
                "Domain catalog $($catalogResult.Catalog.revision) " +
                "($(@($catalogResult.Catalog.packs).Count) packs, " +
                "$($catalogResult.DomainCount) domains)"
            )
        }
    } catch {
        Add-Failure "Domain catalog validation failed: $($_.Exception.Message)"
    }
}

$mappingLibrary = Get-ProjectPath "tools\network-mapping-library.ps1"
if (Test-Path -LiteralPath $mappingLibrary -PathType Leaf) {
    . $mappingLibrary
    try {
        $mappingDefinitions = @(Get-NetworkMappingDefinitions $projectRoot)
        if (-not $mappingDefinitions.Count) {
            Add-Failure "No declarative network mappings were found."
        } else {
            Add-Success "Declarative network mappings ($($mappingDefinitions.Count) definitions)"
        }
    } catch {
        Add-Failure "Network mapping definitions are invalid: $($_.Exception.Message)"
    }
}

try {
    $diagnosticCatalog = Get-Content -Raw -LiteralPath (
        Get-ProjectPath "config\diagnostic-targets.json"
    ) | ConvertFrom-Json
    $diagnosticIds = @($diagnosticCatalog.targets | ForEach-Object { [string]$_.id })
    if (
        [int]$diagnosticCatalog.schemaVersion -ne 1 -or
        -not $diagnosticIds.Count -or
        @($diagnosticIds | Sort-Object -Unique).Count -ne $diagnosticIds.Count
    ) {
        throw "Invalid target catalog structure."
    }
    Add-Success "Application diagnostic targets ($($diagnosticIds.Count) targets)"
} catch {
    Add-Failure "Application diagnostic target catalog is invalid: $($_.Exception.Message)"
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
    foreach ($value in Get-TpmMeaningfulLines (Get-ProjectPath $relativePath)) {
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
    foreach ($value in Get-TpmMeaningfulLines (Get-ProjectPath $relativePath)) {
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
    foreach ($line in Get-TpmMeaningfulLines (Get-ProjectPath $relativePath)) {
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
