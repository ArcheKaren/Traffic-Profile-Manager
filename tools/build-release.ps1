[CmdletBinding()]
param(
    [string]$RuntimeRoot = "",
    [string]$OutputRoot = "",
    [string]$ArchivePath = "",
    [switch]$SkipTests,
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
    ("{0}.build.zip" -f [IO.Path]::GetFileNameWithoutExtension($archive))

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
    "1 - Verified.bat"
    "2 - Split Position 1.bat"
    "3 - Fake TLS MD5.bat"
    "4 - Auto TTL.bat"
    "5 - QUIC Fake.bat"
    "6 - Multi Position.bat"
    "7 - Randomized TLS.bat"
    "8 - Sequence Overlap.bat"
    "9 - Current Default.bat"
    "10 - Full Fake MD5.bat"
    "11 - Full Auto TTL.bat"
    "12 - Full Multi Position.bat"
    "13 - Timestamp Overlap.bat"
    "14 - Mixed Aggressive.bat"
)
$releaseToolFiles = @(
    "profile-benchmark.ps1"
    "profile-library.ps1"
    "profile-manager.ps1"
    "run-profile.bat"
    "service-control.ps1"
    "validate-profiles.ps1"
    "watch-benchmark.ps1"
    "watch-service-mappings.ps1"
)

try {
    New-Item -ItemType Directory -Path $staging -Force | Out-Null

    foreach ($relativePath in $rootFiles) {
        Copy-ProjectFile $relativePath
    }
    foreach ($directory in @("assets", "config\profiles", "lists")) {
        Get-ChildItem -LiteralPath (Join-Path $projectRoot $directory) -File |
            ForEach-Object {
                Copy-ProjectFile (Join-Path $directory $_.Name)
            }
    }
    Copy-ProjectFile "config\config.json"
    foreach ($name in @("targets.txt")) {
        Copy-ProjectFile (Join-Path "tests" $name)
    }
    Copy-ProjectFile "docs\PROFILE_FORMAT.md"
    foreach ($name in $releaseToolFiles) {
        Copy-ProjectFile (Join-Path "tools" $name)
    }

    foreach ($directory in @("logs", "state", "test-results")) {
        New-Item -ItemType Directory -Path (Join-Path $staging $directory) -Force |
            Out-Null
    }

    $winws = Find-FirstFile @(
        "zapret-win-bundle-master\blockcheck\zapret2\nfq2\winws2.exe"
        "zapret-win-bundle-master\zapret-winws\winws2.exe"
        "winws2.exe"
    ) "winws2.exe"
    $winwsDirectory = if ($winws) { Split-Path -Parent $winws } else { "" }
    $winDivertDll = if ($winwsDirectory) {
        Join-Path $winwsDirectory "WinDivert.dll"
    } else { "" }
    $winDivertDriver = if ($winwsDirectory) {
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
    $luaLib = if ($luaRoot) { Join-Path $luaRoot "zapret-lib.lua" } else { "" }
    $luaAntidpi = if ($luaRoot) {
        Join-Path $luaRoot "zapret-antidpi.lua"
    } else { "" }
    if (-not (Test-Path -LiteralPath $luaLib -PathType Leaf)) {
        $luaLib = Find-FirstFile @("lua\zapret-lib.lua") "zapret-lib.lua"
    }
    if (-not (Test-Path -LiteralPath $luaAntidpi -PathType Leaf)) {
        $luaAntidpi = Find-FirstFile @("lua\zapret-antidpi.lua") "zapret-antidpi.lua"
    }
    $cygwin = Find-FirstFile @(
        "zapret-win-bundle-master\cygwin\bin\cygwin1.dll"
        "zapret-win-bundle-master\zapret-winws\cygwin1.dll"
        "cygwin1.dll"
    ) "cygwin1.dll"

    Copy-RuntimeFile $winws "runtime\winws2.exe"
    Copy-RuntimeFile $winDivertDll "runtime\WinDivert.dll"
    Copy-RuntimeFile $winDivertDriver "runtime\WinDivert64.sys"
    Copy-RuntimeFile $cygwin "runtime\cygwin1.dll"
    Copy-RuntimeFile $luaLib "runtime\lua\zapret-lib.lua"
    Copy-RuntimeFile $luaAntidpi "runtime\lua\zapret-antidpi.lua"

    if (-not $SkipTests) {
        & (Join-Path $projectRoot "tools\test-project.ps1") -AppRoot $staging
        if ($LASTEXITCODE -ne 0) {
            throw "Release validation failed."
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
