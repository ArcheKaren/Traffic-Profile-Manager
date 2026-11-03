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
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) (
    "modules\TrafficProfileManager.Runtime\TrafficProfileManager.Runtime.psd1"
)) -ErrorAction Stop

Write-TpmOperationLog `
    -AppRoot $projectRoot `
    -Component "runtime-restore" `
    -Operation "restore" `
    -Status "started" `
    -Data @{ archive = [IO.Path]::GetFullPath($ArchivePath) }

try {
$archive = [IO.Path]::GetFullPath($ArchivePath)
$manifestPath = Join-Path $projectRoot "runtime\SOURCE.json"
$manifest = Get-TpmRuntimeManifest $manifestPath
$archiveStream = [IO.File]::OpenRead($archive)
try {
    Assert-TpmRuntimeContent -Stream $archiveStream `
        -Sha256 $manifest.bootstrapRelease.sha256 -Label "bootstrap archive"
} finally {
    $archiveStream.Dispose()
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
        [void](Resolve-TpmRuntimePath $runtimeRoot $releasePath)
        $destination = Resolve-TpmRuntimePath $runtimeRoot $runtimePath
        $entryName = (
            "TrafficProfileManager/runtime/{0}" -f
            $releasePath.Replace("\", "/")
        )
        $entry = @($zip.Entries | Where-Object FullName -ceq $entryName) |
            Select-Object -First 1
        if (-not $entry -or $entry.Length -ne [int64]$entryMetadata.length) {
            throw "Runtime bootstrap entry is missing or has the wrong size: $entryName"
        }
        $input = $entry.Open()
        try {
            Assert-TpmRuntimeContent -Stream $input `
                -Sha256 $entryMetadata.sha256 -Length $entryMetadata.length `
                -Label $entryName
        } finally {
            $input.Dispose()
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
