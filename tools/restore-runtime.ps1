[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ArchivePath,

    [string]$RootPath = ""
)

$ErrorActionPreference = "Stop"
$projectRoot = if ($RootPath) {
    [IO.Path]::GetFullPath($RootPath)
} else {
    Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
}
Import-Module (
    Join-Path $projectRoot `
        "modules\TrafficProfileManager.Operations\TrafficProfileManager.Operations.psd1"
) -ErrorAction Stop

Write-TpmOperationLog `
    -AppRoot $projectRoot `
    -Component "runtime-restore" `
    -Operation "restore" `
    -Status "started" `
    -Data @{ archive = [IO.Path]::GetFullPath($ArchivePath) }

try {
$archive = [IO.Path]::GetFullPath($ArchivePath)
$manifestPath = Join-Path $projectRoot "runtime\SOURCE.json"
$manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
if (
    [string]$manifest.bootstrapRelease.sha256 -notmatch "^[A-Fa-f0-9]{64}$" -or
    (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ine
        [string]$manifest.bootstrapRelease.sha256
) {
    throw "Runtime bootstrap archive SHA-256 mismatch."
}

Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [IO.Compression.ZipFile]::OpenRead($archive)
try {
    $runtimeRoot = [IO.Path]::GetFullPath(
        (Join-Path $projectRoot "runtime")
    ).TrimEnd("\")
    foreach ($property in $manifest.runtimeFiles.PSObject.Properties) {
        $entryMetadata = $property.Value
        $releasePath = [string]$entryMetadata.releasePath
        $runtimePath = [string]$entryMetadata.path
        if (
            [string]::IsNullOrWhiteSpace($releasePath) -or
            [IO.Path]::IsPathRooted($releasePath) -or
            @($releasePath.Replace("\", "/").Split("/") | Where-Object {
                $_ -in @("", ".", "..")
            }).Count
        ) {
            throw "Unsafe runtime bootstrap release path: $releasePath"
        }
        $entryName = (
            "TrafficProfileManager/runtime/{0}" -f
            $releasePath.Replace("\", "/")
        )
        $entry = @($zip.Entries | Where-Object FullName -ceq $entryName) |
            Select-Object -First 1
        if (-not $entry -or $entry.Length -ne [int64]$entryMetadata.length) {
            throw "Runtime bootstrap entry is missing or has the wrong size: $entryName"
        }
        $sha = [Security.Cryptography.SHA256]::Create()
        $input = $entry.Open()
        try {
            $actualHash = [BitConverter]::ToString(
                $sha.ComputeHash($input)
            ).Replace("-", "")
        } finally {
            $input.Dispose()
            $sha.Dispose()
        }
        if ($actualHash -ine [string]$entryMetadata.sha256) {
            throw "Runtime bootstrap entry SHA-256 mismatch: $entryName"
        }

        if (
            [string]::IsNullOrWhiteSpace($runtimePath) -or
            [IO.Path]::IsPathRooted($runtimePath)
        ) {
            throw "Unsafe runtime destination path: $runtimePath"
        }
        $destination = [IO.Path]::GetFullPath(
            (Join-Path $runtimeRoot $runtimePath)
        )
        if (-not $destination.StartsWith(
            $runtimeRoot + "\",
            [StringComparison]::OrdinalIgnoreCase
        )) {
            throw "Runtime destination leaves the runtime directory: $runtimePath"
        }
        New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force |
            Out-Null
        $temporary = "$destination.$PID.$([Guid]::NewGuid().ToString('N')).tmp"
        try {
            $input = $entry.Open()
            $output = [IO.File]::Open(
                $temporary,
                [IO.FileMode]::CreateNew,
                [IO.FileAccess]::Write,
                [IO.FileShare]::None
            )
            try { $input.CopyTo($output) } finally {
                $output.Dispose()
                $input.Dispose()
            }
            Move-Item -LiteralPath $temporary -Destination $destination -Force
        } finally {
            if (Test-Path -LiteralPath $temporary) {
                Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
            }
        }
    }
} finally {
    $zip.Dispose()
}

Write-TpmOperationLog `
    -AppRoot $projectRoot `
    -Component "runtime-restore" `
    -Operation "restore" `
    -Status "succeeded" `
    -Data @{ archive = $archive }
Write-Host "Verified runtime restored from $archive" -ForegroundColor Green
} catch {
    $restoreError = $_
    try {
        Write-TpmOperationLog `
            -AppRoot $projectRoot `
            -Component "runtime-restore" `
            -Operation "restore" `
            -Status "failed" `
            -Message $restoreError.Exception.Message `
            -Data @{ archive = [IO.Path]::GetFullPath($ArchivePath) }
    } catch {
        Write-Warning "The runtime restore journal could not be updated: $($_.Exception.Message)"
    }
    throw $restoreError
}
