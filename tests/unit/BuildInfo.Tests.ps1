Describe "Build identity" {
    BeforeAll {
        $projectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        Import-Module (Join-Path $projectRoot (
            "modules\TrafficProfileManager.Core\TrafficProfileManager.Core.psd1"
        )) -Force
    }

    BeforeEach {
        $root = Join-Path $TestDrive ([Guid]::NewGuid().ToString("N") + " build's path")
        New-Item -ItemType Directory -Path $root | Out-Null
        Set-Content -LiteralPath (Join-Path $root "VERSION") "1.2.1"
    }

    It "does not infer a parent repository for an unpacked directory" {
        $info = Get-TpmBuildInfo $root
        $info.version | Should -Be "1.2.1"
        $info.source | Should -Be "unknown"
        $info.commit | Should -BeNullOrEmpty
        ($null -eq $info.localChanges) | Should -BeTrue
    }

    It "reads packaged identity without Git" {
        @{
            schemaVersion = 1; version = "1.2.1"; commit = "a" * 40
            localChanges = $true; contentSha256 = "B" * 64
        } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root "BUILD-INFO.json")
        $info = Get-TpmBuildInfo $root
        $info.source | Should -Be "package"
        $info.commit | Should -Be ("a" * 40)
        $info.localChanges | Should -BeTrue
        $info.contentSha256 | Should -Be ("B" * 64)
    }

    It "keeps the version available when build metadata is damaged or stale" {
        Set-Content -LiteralPath (Join-Path $root "BUILD-INFO.json") '{ invalid'
        (Get-TpmBuildInfo $root).source | Should -Be "invalid-metadata"
        @{
            schemaVersion = 1; version = "1.0.0"; contentSha256 = "B" * 64
        } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root "BUILD-INFO.json")
        $info = Get-TpmBuildInfo $root
        $info.version | Should -Be "1.2.1"
        $info.source | Should -Be "invalid-metadata"
        ($null -eq $info.localChanges) | Should -BeTrue
    }

    It "reads compact metadata and prefers it to stale legacy files" -TestCases @(@{KeepLegacy=$true},@{KeepLegacy=$false}) {
        param($KeepLegacy)
        New-Item -ItemType Directory -Path (Join-Path $root 'metadata')|Out-Null
        Set-Content -LiteralPath (Join-Path $root 'metadata/VERSION') '1.2.2'
        if(-not $KeepLegacy){Remove-Item -LiteralPath (Join-Path $root 'VERSION')}
        @{schemaVersion=1;version='1.2.2';commit=('c'*40);localChanges=$false;contentSha256=('D'*64)} |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root 'metadata/BUILD-INFO.json')
        Set-Content -LiteralPath (Join-Path $root 'BUILD-INFO.json') '{stale'
        $info=Get-TpmBuildInfo $root
        $info.version|Should -Be '1.2.2'
        $info.source|Should -Be 'package'
        $info.commit|Should -Be ('c'*40)
    }

    It "distinguishes clean, modified, staged and untracked sources" {
        & git init --quiet $root
        if ($LASTEXITCODE -ne 0) { throw "Fixture git init failed." }
        Set-Content -LiteralPath (Join-Path $root ".gitignore") "ignored.txt"
        & git -C $root add VERSION .gitignore
        & git -C $root -c user.name=Test -c user.email=test@example.org `
            -c commit.gpgsign=false commit --quiet -m fixture
        if ($LASTEXITCODE -ne 0) { throw "Fixture git commit failed." }
        $clean = Get-TpmBuildInfo $root
        $clean.source | Should -Be "git"
        $clean.commit | Should -Match '^[a-f0-9]{40,64}$'
        $clean.localChanges | Should -BeFalse
        Set-Content -LiteralPath (Join-Path $root "ignored.txt") "local state"
        (Get-TpmBuildInfo $root).localChanges | Should -BeFalse
        Set-Content -LiteralPath (Join-Path $root "new.txt") "new"
        (Get-TpmBuildInfo $root).localChanges | Should -BeTrue
        Remove-Item -LiteralPath (Join-Path $root "new.txt")
        Set-Content -LiteralPath (Join-Path $root "VERSION") "1.2.2"
        (Get-TpmBuildInfo $root).localChanges | Should -BeTrue
        & git -C $root add VERSION
        (Get-TpmBuildInfo $root).localChanges | Should -BeTrue
        (Get-TpmBuildInfo $root).commit | Should -Be $clean.commit
    }
}
