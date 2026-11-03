Describe 'Runtime overview provenance' {
    BeforeAll {
        $projectRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        Import-Module (Join-Path $projectRoot 'modules/TrafficProfileManager.Maintenance/TrafficProfileManager.Maintenance.psd1') -Force
        function Write-OverviewFixture([string]$Path,[string]$Text) {
            New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force|Out-Null
            [IO.File]::WriteAllText($Path,$Text,[Text.UTF8Encoding]::new($false))
        }
    }
    BeforeEach {
        $root=Join-Path $TestDrive ([Guid]::NewGuid().ToString('N')+" overview user's path")
        Write-OverviewFixture (Join-Path $root 'config/config.json') '{"activeProfile":"fixture","runtimePath":"runtime/winws2.exe"}'
        Write-OverviewFixture (Join-Path $root 'metadata/VERSION') '1.2.1'
        Write-OverviewFixture (Join-Path $root 'metadata/release-manifest.json') '{}'
        $manifest=@{source='https://example.org/runtime.zip';archiveSha256=('A'*64);runtimeFiles=@{}}
        foreach($key in @('winws2','winDivertDll','winDivertDriver','cygwin','luaLib','luaAntidpi')) {
            $name=if($key -eq 'winws2'){'winws2.exe'}else{"$key.bin"}
            $path=Join-Path $root "runtime/$name"
            Write-OverviewFixture $path "fixture $key"
            $manifest.runtimeFiles[$key]=@{path="upstream/$name";releasePath=$name;length=(Get-Item -LiteralPath $path).Length;sha256=(Get-FileHash -LiteralPath $path).Hash}
        }
        Write-OverviewFixture (Join-Path $root 'runtime/SOURCE.json') ($manifest|ConvertTo-Json -Depth 6)
        $hostsPath=Join-Path $root 'fixture-hosts'
        Write-OverviewFixture $hostsPath '203.0.113.10 unrelated.example'
        Mock Get-Service {} -ModuleName TrafficProfileManager.Maintenance
        Mock Get-Process {} -ModuleName TrafficProfileManager.Maintenance
        Mock Get-TrafficProfiles {[pscustomobject]@{Id='fixture';Valid=$true}} -ModuleName TrafficProfileManager.Maintenance
    }
    It 'keeps an explicitly configured bundled executable verified' {
        (Get-TpmOverview $root -HostsPath $hostsPath).runtime|Should -Be 'verified'
    }
    It 'does not hide corrupted bundled components behind an explicit runtime path' -TestCases @(@{File='winws2.exe'},@{File='luaLib.bin'}) {
        param($File)
        Write-OverviewFixture (Join-Path $root "runtime/$File") 'damaged component'
        $overview=Get-TpmOverview $root -HostsPath $hostsPath
        $overview.runtime|Should -Be 'missing-or-invalid'
        @(Get-TpmAdvice $overview).code|Should -Contain 'runtime-invalid'
    }
    It 'reports an invalid explicit path even if the bundle is otherwise valid' {
        $config=@{activeProfile='fixture';runtimePath=('runtime/'+[char]0+'invalid.exe')}|ConvertTo-Json
        Write-OverviewFixture (Join-Path $root 'config/config.json') $config
        (Get-TpmOverview $root -HostsPath $hostsPath).runtime|Should -Be 'missing-or-invalid'
    }
    It 'keeps missing or invalid portable provenance visible' -TestCases @(@{Missing=$true},@{Missing=$false}) {
        param($Missing)
        $source=Join-Path $root 'runtime/SOURCE.json'
        if($Missing){Remove-Item -LiteralPath $source}else{[IO.File]::WriteAllText($source,'{invalid')}
        (Get-TpmOverview $root -HostsPath $hostsPath).runtime|Should -Be 'missing-or-invalid'
    }
    It 'continues to support a separate explicit executable' {
        $external=Join-Path $root 'custom/runtime.exe'
        Write-OverviewFixture $external 'user-provided runtime'
        Write-OverviewFixture (Join-Path $root 'config/config.json') (@{activeProfile='fixture';runtimePath=$external}|ConvertTo-Json)
        (Get-TpmOverview $root -HostsPath $hostsPath).runtime|Should -Be 'external-unverified'
    }
}
