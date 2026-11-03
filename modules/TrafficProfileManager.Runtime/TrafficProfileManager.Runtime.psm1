function Resolve-TpmRuntimePath {
    param([string]$RuntimeRoot, [string]$RelativePath)

    if (
        [string]::IsNullOrWhiteSpace($RelativePath) -or
        [IO.Path]::IsPathRooted($RelativePath) -or
        @($RelativePath.Replace("\", "/").Split("/") | Where-Object {
            $_ -in @("", ".", "..") -or $_.Contains(":")
        }).Count
    ) {
        throw "Unsafe runtime provenance path: $RelativePath"
    }
    $root = [IO.Path]::GetFullPath($RuntimeRoot).TrimEnd("\")
    $path = [IO.Path]::GetFullPath((Join-Path $root $RelativePath))
    if (-not $path.StartsWith($root + "\", [StringComparison]::OrdinalIgnoreCase)) {
        throw "Runtime provenance path leaves runtime: $RelativePath"
    }
    return $path
}

function Get-TpmRuntimeManifest {
    param([string]$Path)

    $manifest = Get-Content -Raw -LiteralPath $Path -ErrorAction Stop |
        ConvertFrom-Json -ErrorAction Stop
    if (
        [string]$manifest.source -notmatch "^https://" -or
        [string]$manifest.archiveSha256 -notmatch "^[A-Fa-f0-9]{64}$"
    ) {
        throw "Runtime manifest contains invalid source metadata."
    }
    $root = Split-Path -Parent ([IO.Path]::GetFullPath($Path))
    foreach ($key in @(
        "winws2", "winDivertDll", "winDivertDriver", "cygwin", "luaLib", "luaAntidpi"
    )) {
        $entry = $manifest.runtimeFiles.$key
        if (
            -not $entry -or
            [string]$entry.sha256 -notmatch "^[A-Fa-f0-9]{64}$" -or
            [int64]$entry.length -le 0
        ) {
            throw "Missing or invalid runtime provenance entry '$key'."
        }
        [void](Resolve-TpmRuntimePath $root ([string]$entry.path))
        [void](Resolve-TpmRuntimePath $root ([string]$entry.releasePath))
    }
    return $manifest
}

function Assert-TpmRuntimeContent {
    param(
        [IO.Stream]$Stream,
        [string]$Sha256,
        [int64]$Length = -1,
        [string]$Label = "runtime component"
    )

    if ($Sha256 -notmatch "^[A-Fa-f0-9]{64}$") {
        throw "Invalid runtime SHA-256: $Label"
    }
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $buffer = New-Object byte[] 65536
        $count = [int64]0
        while (($read = $Stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $count += $read
            [void]$sha.TransformBlock($buffer, 0, $read, $buffer, 0)
        }
        [void]$sha.TransformFinalBlock($buffer, 0, 0)
        $actualHash = [BitConverter]::ToString($sha.Hash).Replace("-", "")
        if (($Length -ge 0 -and $count -ne $Length) -or $actualHash -ine $Sha256) {
            throw "Runtime provenance mismatch: $Label"
        }
    } finally {
        $sha.Dispose()
    }
}

function Get-TpmVerifiedRuntimeFile {
    param(
        [string]$RuntimeRoot,
        $Entry,
        [ValidateSet("Source", "Portable")]
        [string]$Layout = "Source"
    )

    $relativePath = if ($Layout -eq "Portable") { $Entry.releasePath } else { $Entry.path }
    $path = Resolve-TpmRuntimePath $RuntimeRoot ([string]$relativePath)
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Runtime component is missing: $relativePath"
    }
    $stream = [IO.File]::OpenRead($path)
    try {
        Assert-TpmRuntimeContent -Stream $stream -Sha256 $Entry.sha256 `
            -Length $Entry.length -Label $relativePath
    } finally {
        $stream.Dispose()
    }
    return $path
}

Export-ModuleMember -Function @(
    "Get-TpmRuntimeManifest"
    "Resolve-TpmRuntimePath"
    "Assert-TpmRuntimeContent"
    "Get-TpmVerifiedRuntimeFile"
)
