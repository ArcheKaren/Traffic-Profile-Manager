[CmdletBinding()]
param(
    [string]$RuntimeRoot = "",
    [string]$OutputRoot = "",
    [string]$ArchivePath = "",
    [switch]$SkipTests,
    [switch]$SkipRuntimeProvenanceCheck,
    [switch]$NoDirectorySync
)

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$releaseRoot = Join-Path $projectRoot "release"
$runtimeSource = if ($RuntimeRoot) {
    [IO.Path]::GetFullPath($RuntimeRoot)
} else {
    Join-Path $projectRoot "runtime"
}
$output = if ($OutputRoot) {
    [IO.Path]::GetFullPath($OutputRoot)
} else {
    Join-Path $releaseRoot "TrafficProfileManager"
}
$archive = if ($ArchivePath) {
    [IO.Path]::GetFullPath($ArchivePath)
} else {
    Join-Path $releaseRoot "TrafficProfileManager.zip"
}
$buildContainer = Join-Path $releaseRoot (
    ".tmp-build-{0}-{1}" -f $PID, [Guid]::NewGuid().ToString("N")
)
$staging = Join-Path $buildContainer "TrafficProfileManager"
$archiveTemporary = Join-Path `
    (Split-Path -Parent $archive) `
    ("{0}.{1}.{2}.build.zip" -f @(
        [IO.Path]::GetFileNameWithoutExtension($archive),
        $PID,
        [Guid]::NewGuid().ToString("N")
    ))
$sourceManifestPath = Join-Path $projectRoot "runtime\SOURCE.json"
$releaseManifestName = ".tpm-release-manifest.json"

function Copy-ProjectFile([string]$RelativePath) {
    $source = Join-Path $projectRoot $RelativePath
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        throw "Release source file is missing: $RelativePath"
    }
    $destination = Join-Path $staging $RelativePath
    $parent = Split-Path -Parent $destination
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    Copy-Item -LiteralPath $source -Destination $destination -Force
}

function Find-FirstFile(
    [string[]]$PreferredPaths,
    [string]$Name
) {
    foreach ($relativePath in $PreferredPaths) {
        $candidate = Join-Path $runtimeSource $relativePath
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return [IO.Path]::GetFullPath($candidate)
        }
    }
    return (
        Get-ChildItem `
            -LiteralPath $runtimeSource `
            -Filter $Name `
            -File `
            -Recurse `
            -ErrorAction SilentlyContinue |
            Select-Object -First 1
    ).FullName
}

function Get-VerifiedRuntimeFile([string]$Key) {
    if (-not (Test-Path -LiteralPath $sourceManifestPath -PathType Leaf)) {
        throw "Runtime provenance manifest was not found: $sourceManifestPath"
    }
    $manifest = Get-Content -Raw -LiteralPath $sourceManifestPath |
        ConvertFrom-Json
    if (
        [string]$manifest.source -notmatch "^https://" -or
        [string]$manifest.archiveSha256 -notmatch "^[A-Fa-f0-9]{64}$"
    ) {
        throw "runtime\SOURCE.json contains invalid source metadata."
    }
    $entry = $manifest.runtimeFiles.$Key
    if (-not $entry) {
        throw "runtime\SOURCE.json has no '$Key' file entry."
    }
    $relativePath = [string]$entry.path
    if ([IO.Path]::IsPathRooted($relativePath)) {
        throw "Runtime provenance path must be relative: $relativePath"
    }
    $runtimeRoot = [IO.Path]::GetFullPath($runtimeSource).TrimEnd("\")
    $candidate = [IO.Path]::GetFullPath(
        (Join-Path $runtimeRoot $relativePath)
    )
    if (-not $candidate.StartsWith(
        $runtimeRoot + "\",
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw "Runtime provenance path leaves RuntimeRoot: $relativePath"
    }
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        throw "Verified runtime component was not found: $relativePath"
    }
    $file = Get-Item -LiteralPath $candidate
    if ([int64]$entry.length -ne $file.Length) {
        throw "Runtime component size mismatch: $relativePath"
    }
    $actualHash = (Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash
    if ($actualHash -ine [string]$entry.sha256) {
        throw "Runtime component SHA-256 mismatch: $relativePath"
    }
    return $candidate
}

function Copy-RuntimeFile(
    [string]$SourcePath,
    [string]$RelativeDestination
) {
    if (-not $SourcePath -or -not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) {
        throw "Runtime component was not found: $RelativeDestination"
    }
    $destination = Join-Path $staging $RelativeDestination
    New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force |
        Out-Null
    Copy-Item -LiteralPath $SourcePath -Destination $destination -Force
}

function Compare-ArchiveToDirectory(
    [string]$ArchiveFile,
    [string]$Directory
) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $directoryParent = Split-Path -Parent $Directory
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $disk = @{}
        Get-ChildItem -LiteralPath $Directory -File -Recurse |
            ForEach-Object {
                $key = $_.FullName.Substring($directoryParent.Length + 1).
                    Replace("\", "/")
                $stream = [IO.File]::OpenRead($_.FullName)
                try {
                    $disk[$key] = [BitConverter]::ToString(
                        $sha.ComputeHash($stream)
                    ).Replace("-", "")
                } finally {
                    $stream.Dispose()
                }
            }

        $zip = @{}
        $zipFile = [IO.Compression.ZipFile]::OpenRead($ArchiveFile)
        try {
            foreach ($entry in @($zipFile.Entries | Where-Object Name)) {
                $stream = $entry.Open()
                try {
                    $zip[$entry.FullName.Replace("\", "/")] =
                        [BitConverter]::ToString(
                            $sha.ComputeHash($stream)
                        ).Replace("-", "")
                } finally {
                    $stream.Dispose()
                }
            }
        } finally {
            $zipFile.Dispose()
        }

        $missing = @($disk.Keys | Where-Object { -not $zip.ContainsKey($_) })
        $extra = @($zip.Keys | Where-Object { -not $disk.ContainsKey($_) })
        $different = @(
            $disk.Keys |
                Where-Object {
                    $zip.ContainsKey($_) -and $disk[$_] -ne $zip[$_]
                }
        )
        if ($missing.Count -or $extra.Count -or $different.Count) {
            throw (
                "Archive verification failed: missing={0}, extra={1}, changed={2}." -f
                $missing.Count,
                $extra.Count,
                $different.Count
            )
        }
        return $disk.Count
    } finally {
        $sha.Dispose()
    }
}

function New-DeterministicArchive(
    [string]$Directory,
    [string]$ArchiveFile
) {
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $directoryParent = Split-Path -Parent $Directory
    $fixedTimestamp = [DateTimeOffset]::Parse("2026-07-28T00:00:00Z")
    $fileStream = [IO.File]::Open(
        $ArchiveFile,
        [IO.FileMode]::CreateNew,
        [IO.FileAccess]::ReadWrite,
        [IO.FileShare]::None
    )
    try {
        $zip = [IO.Compression.ZipArchive]::new(
            $fileStream,
            [IO.Compression.ZipArchiveMode]::Create,
            $false
        )
        try {
            foreach ($file in @(
                Get-ChildItem -LiteralPath $Directory -File -Recurse |
                    Sort-Object FullName
            )) {
                $entryName = $file.FullName.Substring($directoryParent.Length + 1).
                    Replace("\", "/")
                $entry = $zip.CreateEntry(
                    $entryName,
                    [IO.Compression.CompressionLevel]::Optimal
                )
                $entry.LastWriteTime = $fixedTimestamp
                $inputStream = [IO.File]::OpenRead($file.FullName)
                $outputStream = $entry.Open()
                try {
                    $inputStream.CopyTo($outputStream)
                } finally {
                    $outputStream.Dispose()
                    $inputStream.Dispose()
                }
            }
        } finally {
            $zip.Dispose()
        }
    } finally {
        $fileStream.Dispose()
    }
}

function Write-ReleaseManifest {
    $managedFiles = @(
        Get-ChildItem -LiteralPath $staging -File -Recurse |
            ForEach-Object {
                $_.FullName.Substring($staging.Length + 1).Replace("\", "/")
            } |
            Where-Object { $_ -ne $releaseManifestName } |
            Sort-Object
    )
    $manifest = [ordered]@{
        schemaVersion = 1
        managedFiles = $managedFiles
    }
    [IO.File]::WriteAllText(
        (Join-Path $staging $releaseManifestName),
        ($manifest | ConvertTo-Json -Depth 5) + [Environment]::NewLine,
        [Text.UTF8Encoding]::new($false)
    )
}

function Assert-NoReleaseReparsePoint(
    [string]$Path,
    [string]$Root
) {
    $resolvedRoot = [IO.Path]::GetFullPath($Root).TrimEnd("\")
    $current = Get-Item -LiteralPath $Path -Force
    while ($current -and $current.FullName.Length -ge $resolvedRoot.Length) {
        if ($current.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "Release cleanup path contains a reparse point: $($current.FullName)"
        }
        if ($current.FullName -ieq $resolvedRoot) { return }
        $parent = Split-Path -Parent $current.FullName
        if (-not $parent -or -not (Test-Path -LiteralPath $parent)) { break }
        $current = Get-Item -LiteralPath $parent -Force
    }
    throw "Release cleanup path is outside the output directory: $Path"
}

function Remove-StaleManagedFiles([string]$Directory) {
    $resolvedOutput = [IO.Path]::GetFullPath($Directory).TrimEnd("\")
    Assert-NoReleaseReparsePoint $resolvedOutput $resolvedOutput
    $manifestPath = Join-Path $resolvedOutput $releaseManifestName
    $currentManifest = Get-Content -Raw -LiteralPath (
        Join-Path $staging $releaseManifestName
    ) | ConvertFrom-Json
    $current = New-Object "Collections.Generic.HashSet[string]" (
        [StringComparer]::OrdinalIgnoreCase
    )
    foreach ($path in @($currentManifest.managedFiles)) {
        [void]$current.Add(([string]$path).Replace("/", "\"))
    }

    if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
        $previous = Get-Content -Raw -LiteralPath $manifestPath |
            ConvertFrom-Json
        if ([int]$previous.schemaVersion -ne 1) {
            throw "Unsupported release manifest in output directory."
        }
        foreach ($relativePathValue in @($previous.managedFiles)) {
            $relativePath = ([string]$relativePathValue).Replace("/", "\")
            if ($current.Contains($relativePath)) { continue }
            $candidate = [IO.Path]::GetFullPath(
                (Join-Path $resolvedOutput $relativePath)
            )
            if (-not $candidate.StartsWith(
                $resolvedOutput + "\",
                [StringComparison]::OrdinalIgnoreCase
            )) {
                throw "Unsafe path in previous release manifest: $relativePath"
            }
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                Assert-NoReleaseReparsePoint $candidate $resolvedOutput
                Remove-Item -LiteralPath $candidate -Force
            }
        }
    } else {
        foreach ($legacyLauncher in @(
            Get-ChildItem -LiteralPath $resolvedOutput -Filter "*.bat" -File |
                Where-Object Name -Match "^\d+\s+-\s+"
        )) {
            $relativePath = $legacyLauncher.Name
            if (-not $current.Contains($relativePath)) {
                Assert-NoReleaseReparsePoint `
                    $legacyLauncher.FullName `
                    $resolvedOutput
                Remove-Item -LiteralPath $legacyLauncher.FullName -Force
            }
        }
    }
}

$rootFiles = @(
    "VERSION"
    "LICENSE"
    "README.md"
    "CHANGELOG.md"
    "CONTRIBUTING.md"
    "SECURITY.md"
    "THIRD-PARTY-LICENSES.txt"
    "Manager.bat"
    "Test Profiles.bat"
    "Validate Profiles.bat"
    "manage-network-mappings.ps1"
    "watch-foreground.ps1"
    "zapretctl.cmd"
    "zapretctl.ps1"
    "1 - Base.bat"
    "2 - Base (Split position 1).bat"
    "3 - Base (Fake TLS with MD5).bat"
    "4 - Base (Automatic TTL).bat"
    "5 - Base (QUIC fake).bat"
    "6 - Base (Multiple split positions).bat"
    "7 - Base (Randomized TLS).bat"
    "8 - Base (Sequence overlap).bat"
    "9 - Base (Current defaults).bat"
    "10 - Base (Full fake TLS with MD5).bat"
    "11 - Base (Full automatic TTL).bat"
    "12 - Base (Full multiple positions).bat"
    "13 - Base (Timestamp overlap).bat"
    "14 - Base (Mixed aggressive).bat"
)
$releaseToolFiles = @(
    "application-diagnostics.ps1"
    "catalog-library.ps1"
    "domain-pack-manager.ps1"
    "profile-benchmark.ps1"
    "game-filter-library.ps1"
    "game-filter-manager.ps1"
    "network-mapping-library.ps1"
    "profile-library.ps1"
    "profile-manager.ps1"
    "run-profile.bat"
    "service-control.ps1"
    "validate-profiles.ps1"
    "watch-benchmark.ps1"
    "watch-service-mappings.ps1"
)
$runtimeCreatedUserLists = @(
    "lists\user-domains.txt"
    "lists\user-domains-exclude.txt"
    "lists\user-ips.txt"
    "lists\user-ips-exclude.txt"
    "state\domain-packs.json"
)

try {
    New-Item -ItemType Directory -Path $staging -Force | Out-Null

    foreach ($relativePath in $rootFiles) {
        Copy-ProjectFile $relativePath
    }
    foreach ($directory in @("assets", "config\profiles", "lists")) {
        Get-ChildItem -LiteralPath (Join-Path $projectRoot $directory) -File -Recurse |
            ForEach-Object {
                $relativePath = $_.FullName.Substring($projectRoot.Length + 1)
                $isUserPack = $relativePath.StartsWith(
                    "lists\user-packs\",
                    [StringComparison]::OrdinalIgnoreCase
                )
                if (
                    $relativePath -notin $runtimeCreatedUserLists -and
                    -not $isUserPack
                ) {
                    Copy-ProjectFile $relativePath
                }
            }
    }
    foreach ($directory in @("config\game-filters", "config\network-mappings")) {
        Get-ChildItem `
            -LiteralPath (Join-Path $projectRoot $directory) `
            -File `
            -Recurse |
            ForEach-Object {
                Copy-ProjectFile $_.FullName.Substring($projectRoot.Length + 1)
            }
    }
    foreach ($name in @(
        "config.json"
        "diagnostic-targets.json"
        "rule-groups.json"
    )) {
        Copy-ProjectFile (Join-Path "config" $name)
    }
    foreach ($name in @("targets.txt")) {
        Copy-ProjectFile (Join-Path "tests" $name)
    }
    Copy-ProjectFile "docs\PROFILE_FORMAT.md"
    Copy-ProjectFile "docs\GAME_FILTERS.md"
    Copy-ProjectFile "docs\DOMAIN_PACKS.md"
    Copy-ProjectFile "docs\DIAGNOSTICS.md"
    foreach ($name in $releaseToolFiles) {
        Copy-ProjectFile (Join-Path "tools" $name)
    }
    Copy-ProjectFile "runtime\SOURCE.json"

    foreach ($directory in @("logs", "state", "test-results")) {
        New-Item -ItemType Directory -Path (Join-Path $staging $directory) -Force |
            Out-Null
    }

    $winws = if ($SkipRuntimeProvenanceCheck) {
        Find-FirstFile @(
            "zapret-win-bundle-master\blockcheck\zapret2\nfq2\winws2.exe"
            "zapret-win-bundle-master\zapret-winws\winws2.exe"
            "winws2.exe"
        ) "winws2.exe"
    } else {
        Get-VerifiedRuntimeFile "winws2"
    }
    $winwsDirectory = if ($winws) { Split-Path -Parent $winws } else { "" }
    $winDivertDll = if (-not $SkipRuntimeProvenanceCheck) {
        Get-VerifiedRuntimeFile "winDivertDll"
    } elseif ($winwsDirectory) {
        Join-Path $winwsDirectory "WinDivert.dll"
    } else { "" }
    $winDivertDriver = if (-not $SkipRuntimeProvenanceCheck) {
        Get-VerifiedRuntimeFile "winDivertDriver"
    } elseif ($winwsDirectory) {
        Join-Path $winwsDirectory "WinDivert64.sys"
    } else { "" }
    if (-not (Test-Path -LiteralPath $winDivertDll -PathType Leaf)) {
        $winDivertDll = Find-FirstFile @("WinDivert.dll") "WinDivert.dll"
    }
    if (-not (Test-Path -LiteralPath $winDivertDriver -PathType Leaf)) {
        $winDivertDriver = Find-FirstFile @("WinDivert64.sys") "WinDivert64.sys"
    }
    $luaRoot = if ($winwsDirectory -and (Split-Path -Leaf $winwsDirectory) -eq "nfq2") {
        Join-Path (Split-Path -Parent $winwsDirectory) "lua"
    } elseif ($winwsDirectory) {
        Join-Path $winwsDirectory "lua"
    } else { "" }
    $luaLib = if (-not $SkipRuntimeProvenanceCheck) {
        Get-VerifiedRuntimeFile "luaLib"
    } elseif ($luaRoot) {
        Join-Path $luaRoot "zapret-lib.lua"
    } else { "" }
    $luaAntidpi = if (-not $SkipRuntimeProvenanceCheck) {
        Get-VerifiedRuntimeFile "luaAntidpi"
    } elseif ($luaRoot) {
        Join-Path $luaRoot "zapret-antidpi.lua"
    } else { "" }
    if (-not (Test-Path -LiteralPath $luaLib -PathType Leaf)) {
        $luaLib = Find-FirstFile @("lua\zapret-lib.lua") "zapret-lib.lua"
    }
    if (-not (Test-Path -LiteralPath $luaAntidpi -PathType Leaf)) {
        $luaAntidpi = Find-FirstFile @("lua\zapret-antidpi.lua") "zapret-antidpi.lua"
    }
    $cygwin = if ($SkipRuntimeProvenanceCheck) {
        Find-FirstFile @(
            "zapret-win-bundle-master\cygwin\bin\cygwin1.dll"
            "zapret-win-bundle-master\zapret-winws\cygwin1.dll"
            "cygwin1.dll"
        ) "cygwin1.dll"
    } else {
        Get-VerifiedRuntimeFile "cygwin"
    }

    Copy-RuntimeFile $winws "runtime\winws2.exe"
    Copy-RuntimeFile $winDivertDll "runtime\WinDivert.dll"
    Copy-RuntimeFile $winDivertDriver "runtime\WinDivert64.sys"
    Copy-RuntimeFile $cygwin "runtime\cygwin1.dll"
    Copy-RuntimeFile $luaLib "runtime\lua\zapret-lib.lua"
    Copy-RuntimeFile $luaAntidpi "runtime\lua\zapret-antidpi.lua"
    Write-ReleaseManifest

    if (-not $SkipTests) {
        if ($SkipRuntimeProvenanceCheck) {
            Write-Warning (
                "Runtime provenance and packaged runtime checks were explicitly " +
                "disabled for this diagnostic build."
            )
            & (Join-Path $projectRoot "tools\test-project.ps1") `
                -AppRoot $staging `
                -SkipRuntimeCheck
        } else {
            & (Join-Path $projectRoot "tools\test-project.ps1") -AppRoot $staging
        }
        if ($LASTEXITCODE -ne 0) {
            throw "Release validation failed."
        }
    }
    foreach ($relativePath in $runtimeCreatedUserLists) {
        $generatedPath = Join-Path $staging $relativePath
        if (Test-Path -LiteralPath $generatedPath -PathType Leaf) {
            Remove-Item -LiteralPath $generatedPath -Force
        }
    }

    $archiveParent = Split-Path -Parent $archive
    New-Item -ItemType Directory -Path $archiveParent -Force | Out-Null
    if (Test-Path -LiteralPath $archiveTemporary) {
        Remove-Item -LiteralPath $archiveTemporary -Force
    }
    New-DeterministicArchive $staging $archiveTemporary
    $verifiedFiles = Compare-ArchiveToDirectory $archiveTemporary $staging
    Move-Item -LiteralPath $archiveTemporary -Destination $archive -Force

    if (-not $NoDirectorySync) {
        New-Item -ItemType Directory -Path $output -Force | Out-Null
        Remove-StaleManagedFiles $output
        Get-ChildItem -LiteralPath $staging -File -Recurse |
            ForEach-Object {
                $relativePath = $_.FullName.Substring($staging.Length + 1)
                $destination = Join-Path $output $relativePath
                New-Item `
                    -ItemType Directory `
                    -Path (Split-Path -Parent $destination) `
                    -Force | Out-Null
                $unchanged = (
                    (Test-Path -LiteralPath $destination -PathType Leaf) -and
                    $_.Length -eq (Get-Item -LiteralPath $destination).Length -and
                    (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash -eq
                    (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash
                )
                if (-not $unchanged) {
                    Copy-Item `
                        -LiteralPath $_.FullName `
                        -Destination $destination `
                        -Force
                }
            }
        foreach ($directory in @("logs", "state", "test-results")) {
            New-Item -ItemType Directory -Path (Join-Path $output $directory) -Force |
                Out-Null
        }
    }

    Write-Host ""
    Write-Host "Release build completed." -ForegroundColor Green
    Write-Host "Archive: $archive"
    Write-Host "Files:   $verifiedFiles"
    Write-Host "SHA-256: $((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash)"
} finally {
    if (Test-Path -LiteralPath $archiveTemporary) {
        Remove-Item -LiteralPath $archiveTemporary -Force -ErrorAction SilentlyContinue
    }
    $resolvedRelease = [IO.Path]::GetFullPath($releaseRoot).TrimEnd("\") + "\"
    $resolvedBuild = [IO.Path]::GetFullPath($buildContainer)
    if (
        $resolvedBuild.StartsWith(
            $resolvedRelease,
            [StringComparison]::OrdinalIgnoreCase
        ) -and
        (Split-Path -Leaf $resolvedBuild).StartsWith(".tmp-build-") -and
        (Test-Path -LiteralPath $resolvedBuild)
    ) {
        Remove-Item -LiteralPath $resolvedBuild -Recurse -Force
    }
}
