Describe "Runtime provenance audit" {
    BeforeAll {
        $projectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $runtimeCheck = Join-Path $projectRoot "tools\test-runtime.ps1"
        $restoreTool = Join-Path $projectRoot "tools\restore-runtime.ps1"
        Add-Type -AssemblyName System.IO.Compression.FileSystem
    }

    BeforeEach {
        $fixtureRoot = Join-Path $TestDrive ([Guid]::NewGuid().ToString("N"))
        $runtimeRoot = Join-Path $fixtureRoot "runtime"
        $manifestPath = Join-Path $runtimeRoot "SOURCE.json"
        $manifest = @{
            source = "https://example.org/runtime.zip"
            archiveSha256 = "A" * 64
            runtimeFiles = [ordered]@{}
        }
        foreach ($key in @(
            "winws2", "winDivertDll", "winDivertDriver", "cygwin", "luaLib", "luaAntidpi"
        )) {
            $sourcePath = "upstream\$key.bin"
            $portablePath = "portable\$key.bin"
            foreach ($relative in @($sourcePath, $portablePath)) {
                $path = Join-Path $runtimeRoot $relative
                New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force |
                    Out-Null
                [IO.File]::WriteAllBytes($path, [byte[]]@(1, 2, 3, 4))
            }
            $manifest.runtimeFiles[$key] = @{
                path = $sourcePath
                releasePath = $portablePath
                length = 4
                sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
            }
        }
        $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifestPath
    }

    It "restores all verified archive components to their declared source paths" {
        $moduleRoot = Join-Path $fixtureRoot "modules"
        New-Item -ItemType Directory -Path $moduleRoot | Out-Null
        Copy-Item -LiteralPath (Join-Path $projectRoot (
            "modules\TrafficProfileManager.Operations"
        )) -Destination $moduleRoot -Recurse
        $archivePath = Join-Path $fixtureRoot "bootstrap.zip"
        $zip = [IO.Compression.ZipFile]::Open($archivePath, "Create")
        try {
            foreach ($entry in $manifest.runtimeFiles.Values) {
                [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                    $zip, (Join-Path $runtimeRoot $entry.releasePath),
                    ("TrafficProfileManager/runtime/" + $entry.releasePath.Replace("\", "/"))
                )
                Remove-Item -LiteralPath (Join-Path $runtimeRoot $entry.path)
            }
        } finally { $zip.Dispose() }
        $manifest.bootstrapRelease = @{
            sha256 = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash
        }
        $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifestPath
        & $restoreTool -ArchivePath $archivePath -RootPath $fixtureRoot
        { & $runtimeCheck -AppRoot $fixtureRoot } | Should -Not -Throw

        # A changed ZIP is rejected before it can overwrite an installed component.
        [IO.File]::WriteAllBytes($archivePath, [byte[]]@(1, 2, 3, 4))
        { & $restoreTool -ArchivePath $archivePath -RootPath $fixtureRoot } |
            Should -Throw "*Runtime provenance mismatch*bootstrap archive*"
        { & $runtimeCheck -AppRoot $fixtureRoot } | Should -Not -Throw
    }

    It "rejects corrupted entry content inside an archive with an accepted archive hash" {
        Import-Module (Join-Path $projectRoot (
            "modules\TrafficProfileManager.Runtime\TrafficProfileManager.Runtime.psd1"
        )) -Force
        $archivePath = Join-Path $fixtureRoot "corrupt.zip"
        $zip = [IO.Compression.ZipFile]::Open($archivePath, "Create")
        try {
            $entry = $zip.CreateEntry("component")
            $stream = $entry.Open()
            try { $stream.Write([byte[]]@(4, 3, 2, 1), 0, 4) } finally { $stream.Dispose() }
        } finally { $zip.Dispose() }
        $zip = [IO.Compression.ZipFile]::OpenRead($archivePath)
        try {
            $stream = $zip.GetEntry("component").Open()
            try {
                { Assert-TpmRuntimeContent -Stream $stream `
                    -Sha256 $manifest.runtimeFiles.winws2.sha256 -Length 4 } |
                    Should -Throw "*Runtime provenance mismatch*"
            } finally { $stream.Dispose() }
        } finally { $zip.Dispose() }
    }

    It "checks source paths even without a Git directory" {
        Remove-Item -LiteralPath (Join-Path $runtimeRoot "portable\winws2.bin")
        { & $runtimeCheck -AppRoot $fixtureRoot } | Should -Not -Throw
    }

    It "checks packaged paths when the release marker exists" -TestCases @(@{Marker='.tpm-release-manifest.json'},@{Marker='metadata/release-manifest.json'}) {
        param($Marker)
        New-Item -ItemType Directory -Path (Join-Path $fixtureRoot 'metadata') -Force|Out-Null
        Set-Content -LiteralPath (Join-Path $fixtureRoot $Marker) "{}"
        Remove-Item -LiteralPath (Join-Path $runtimeRoot "upstream\winws2.bin")
        { & $runtimeCheck -AppRoot $fixtureRoot } | Should -Not -Throw
    }

    It "does not replace a missing source component with a packaged copy" {
        Remove-Item -LiteralPath (Join-Path $runtimeRoot "upstream\winws2.bin")
        { & $runtimeCheck -AppRoot $fixtureRoot } |
            Should -Throw "*Runtime component is missing*"
    }

    It "does not replace a missing packaged component with an upstream copy" {
        Set-Content -LiteralPath (Join-Path $fixtureRoot ".tpm-release-manifest.json") "{}"
        Remove-Item -LiteralPath (Join-Path $runtimeRoot "portable\winws2.bin")
        { & $runtimeCheck -AppRoot $fixtureRoot } |
            Should -Throw "*Runtime component is missing*"
    }

    It "rejects modified content even when its size is unchanged" {
        [IO.File]::WriteAllBytes(
            (Join-Path $runtimeRoot "upstream\winws2.bin"), [byte[]]@(4, 3, 2, 1)
        )
        { & $runtimeCheck -AppRoot $fixtureRoot } |
            Should -Throw "*Runtime provenance mismatch*"
    }

    It "requires all six provenance entries" {
        $manifest.runtimeFiles.Remove("luaAntidpi")
        $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifestPath
        { & $runtimeCheck -AppRoot $fixtureRoot } |
            Should -Throw "*provenance entry 'luaAntidpi'*"
    }

    It "rejects paths outside runtime" {
        $manifest.runtimeFiles.winws2.path = "..\outside.bin"
        $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifestPath
        { & $runtimeCheck -AppRoot $fixtureRoot } |
            Should -Throw "*Unsafe runtime provenance path*"
    }
}
