Describe 'User data, updates and language' {
    BeforeAll {
        $projectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        Import-Module (Join-Path $projectRoot 'modules\TrafficProfileManager.Core\TrafficProfileManager.Core.psd1') -Force
        Import-Module (Join-Path $projectRoot 'modules\TrafficProfileManager.Maintenance\TrafficProfileManager.Maintenance.psd1') -Force
        Import-Module (Join-Path $projectRoot 'modules\TrafficProfileManager.Console\TrafficProfileManager.Console.psd1') -Force
        function Write-FixtureFile([string]$Path,[string]$Text) {
            New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
            [IO.File]::WriteAllText($Path,$Text,[Text.UTF8Encoding]::new($false))
        }
        function New-UpdateFixture([string]$Directory, [switch]$Legacy) {
            $package=Join-Path $Directory 'package'
            $files=@{
                'VERSION'='2.0.0'; 'BUILD-INFO.json'='{"schemaVersion":1,"version":"2.0.0"}'
                'Manager.bat'='new manager'; 'zapretctl.ps1'='new controller'
                'config/config.json'='{"activeProfile":"new","debug":false}'
                'lists/user-domains.txt'='new defaults'; 'tools/new.ps1'='new helper'
            }
            $runtime=@{source='https://example.org/runtime.zip';archiveSha256=('A'*64);runtimeFiles=@{}}
            foreach($key in @('winws2','winDivertDll','winDivertDriver','cygwin','luaLib','luaAntidpi')) {
                $relative="runtime/$key.bin"
                Write-FixtureFile (Join-Path $package $relative) "runtime $key"
                $runtime.runtimeFiles[$key]=@{path="upstream/$key.bin";releasePath="$key.bin";length=(Get-Item (Join-Path $package $relative)).Length;sha256=(Get-FileHash (Join-Path $package $relative)).Hash}
                $files[$relative]="runtime $key"
            }
            $files['runtime/SOURCE.json']=$runtime|ConvertTo-Json -Depth 8
            $manifestName='.tpm-release-manifest.json'
            if (-not $Legacy) {
                $files['metadata/VERSION']=$files['VERSION']; $files.Remove('VERSION')
                $files['metadata/BUILD-INFO.json']=$files['BUILD-INFO.json']; $files.Remove('BUILD-INFO.json')
                $manifestName='metadata/release-manifest.json'
            }
            foreach($relative in $files.Keys) { Write-FixtureFile (Join-Path $package $relative) $files[$relative] }
            Write-FixtureFile (Join-Path $package $manifestName) (@{schemaVersion=1;managedFiles=@($files.Keys)}|ConvertTo-Json -Depth 5)
            $archive=Join-Path $Directory 'update.zip'
            $zip=[IO.Compression.ZipFile]::Open($archive,'Create')
            try {
                Get-ChildItem $package -File -Recurse -Force|ForEach-Object {
                    $relative=$_.FullName.Substring($package.Length+1).Replace('\','/')
                    [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip,$_.FullName,"TrafficProfileManager/$relative")
                }
            } finally { $zip.Dispose() }
            return $archive
        }
    }
    BeforeEach {
        $root=Join-Path $TestDrive ([Guid]::NewGuid().ToString('N')+" user's path")
        New-Item -ItemType Directory -Path $root|Out-Null
        Write-FixtureFile (Join-Path $root 'VERSION') '1.2.1'
        Write-FixtureFile (Join-Path $root 'config/config.json') '{"activeProfile":"old","debug":true,"custom":"keep"}'
        Write-FixtureFile (Join-Path $root 'lists/user-domains.txt') 'custom.example'
        Write-FixtureFile (Join-Path $root 'state/user-settings.json') '{"language":"en","customFlag":42}'
        Write-FixtureFile (Join-Path $root 'state/winws2.windows.pid') 'not-a-pid'
        Mock Get-Service {} -ModuleName TrafficProfileManager.Maintenance
        Mock Get-Process {} -ModuleName TrafficProfileManager.Maintenance
        Set-TpmUiRoot $root
    }

    It 'defaults to English and preserves other user preferences when selecting Russian' {
        (Get-TpmLanguage $root)|Should -Be 'en'
        Set-TpmLanguage -Language ru -AppRoot $root
        (Get-TpmLanguage $root)|Should -Be 'ru'
        ([IO.File]::ReadAllText((Join-Path $root 'state/user-settings.json'))|ConvertFrom-Json).customFlag|Should -Be 42
        (Get-TpmText 'Show status')|Should -Not -Be 'Show status'
        (Get-TpmText 'Created: example.json')|Should -Match 'example.json'
        (Get-TpmText 'Created: example.json')|Should -Not -Be 'Created: example.json'
        Set-TpmLanguage -Language en -AppRoot $root
        (Get-TpmText 'Show status')|Should -Be 'Show status'
    }
    It 'uses English when the preference is missing or corrupt without overwriting it' {
        $path=Join-Path $root 'state/user-settings.json'
        [IO.File]::WriteAllText($path,'{bad')
        (Get-TpmLanguage $root)|Should -Be 'en'
        {Set-TpmLanguage -Language ru -AppRoot $root}|Should -Throw
        [IO.File]::ReadAllText($path)|Should -Be '{bad'
    }
    It 'backs up user data without runtime, logs, process IDs or executable code' {
        Write-FixtureFile (Join-Path $root 'config/profiles/custom.json') '{"name":"custom"}'
        Write-FixtureFile (Join-Path $root 'lists/user-packs/custom/domains.txt') 'private.example'
        Write-FixtureFile (Join-Path $root 'state/service-profile.txt') 'custom-service'
        Write-FixtureFile (Join-Path $root 'logs/private.log') 'do not archive'
        Write-FixtureFile (Join-Path $root 'runtime/winws2.exe') 'binary'
        $backup=New-TpmUserBackup $root
        $plan=@(Get-TpmRestorePlan $root $backup.archive)
        $plan.path|Should -Contain 'config/profiles/custom.json'
        $plan.path|Should -Contain 'lists/user-packs/custom/domains.txt'
        $plan.path|Should -Contain 'state/user-settings.json'
        $plan.path|Should -Contain 'state/service-profile.txt'
        $plan.path|Should -Not -Contain 'state/winws2.windows.pid'
        $plan.path|Should -Not -Contain 'logs/private.log'
        $plan.path|Should -Not -Contain 'runtime/winws2.exe'
    }
    It 'previews a restore without writes, restores settings, and rolls the restore back' {
        $backup=New-TpmUserBackup $root
        Write-FixtureFile (Join-Path $root 'lists/user-domains.txt') 'changed.example'
        [void](Get-TpmRestorePlan $root $backup.archive)
        [IO.File]::ReadAllText((Join-Path $root 'lists/user-domains.txt'))|Should -Be 'changed.example'
        $transaction=Restore-TpmUserBackup $root $backup.archive
        [IO.File]::ReadAllText((Join-Path $root 'lists/user-domains.txt'))|Should -Be 'custom.example'
        [void](Undo-TpmTransaction $root $transaction.transactionId)
        [IO.File]::ReadAllText((Join-Path $root 'lists/user-domains.txt'))|Should -Be 'changed.example'
    }
    It 'refuses restoration with an installed service before changing user files' {
        $backup=New-TpmUserBackup $root
        Mock Get-Service { [pscustomobject]@{Status='Stopped'} } -ModuleName TrafficProfileManager.Maintenance
        {Restore-TpmUserBackup $root $backup.archive}|Should -Throw '*service is installed*'
        [IO.File]::ReadAllText((Join-Path $root 'lists/user-domains.txt'))|Should -Be 'custom.example'
    }
    It 'updates product files while preserving settings and supports a complete rollback' {
        Write-FixtureFile (Join-Path $root 'zapretctl.ps1') 'old controller'
        Write-FixtureFile (Join-Path $root 'obsolete.ps1') 'old helper'
        Write-FixtureFile (Join-Path $root '.tpm-release-manifest.json') '{"schemaVersion":1,"managedFiles":["VERSION","zapretctl.ps1","obsolete.ps1"]}'
        $archive=New-UpdateFixture (Join-Path $TestDrive ([Guid]::NewGuid().ToString('N')))
        $hash=(Get-FileHash $archive).Hash
        $plan=@(Get-TpmUpdatePlan $root $archive $hash)
        ($plan|Where-Object path -eq 'config/config.json').action|Should -Be 'preserve'
        [IO.File]::ReadAllText((Join-Path $root 'VERSION'))|Should -Be '1.2.1'
        $transaction=Install-TpmUpdate $root $archive $hash
        [IO.File]::ReadAllText((Join-Path $root 'metadata/VERSION'))|Should -Be '2.0.0'
        Test-Path (Join-Path $root 'VERSION')|Should -BeFalse
        Test-Path (Join-Path $root '.tpm-release-manifest.json')|Should -BeFalse
        Test-Path (Join-Path $root 'metadata/release-manifest.json')|Should -BeTrue
        [IO.File]::ReadAllText((Join-Path $root 'lists/user-domains.txt'))|Should -Be 'custom.example'
        ([IO.File]::ReadAllText((Join-Path $root 'config/config.json'))|ConvertFrom-Json).custom|Should -Be 'keep'
        Test-Path (Join-Path $root 'obsolete.ps1')|Should -BeFalse
        [void](Undo-TpmTransaction $root $transaction.transactionId)
        [IO.File]::ReadAllText((Join-Path $root 'VERSION'))|Should -Be '1.2.1'
        [IO.File]::ReadAllText((Join-Path $root 'zapretctl.ps1'))|Should -Be 'old controller'
        [IO.File]::ReadAllText((Join-Path $root 'obsolete.ps1'))|Should -Be 'old helper'
        Test-Path (Join-Path $root 'tools/new.ps1')|Should -BeFalse
        Test-Path (Join-Path $root '.tpm-release-manifest.json')|Should -BeTrue
        Test-Path (Join-Path $root 'metadata/release-manifest.json')|Should -BeFalse
        Test-Path (Join-Path $root 'metadata/VERSION')|Should -BeFalse
    }
    It 'still accepts archives that use the legacy root metadata paths' {
        $archive=New-UpdateFixture (Join-Path $TestDrive ([Guid]::NewGuid().ToString('N'))) -Legacy
        $transaction=Install-TpmUpdate $root $archive (Get-FileHash $archive).Hash
        [IO.File]::ReadAllText((Join-Path $root 'VERSION'))|Should -Be '2.0.0'
        Test-Path (Join-Path $root 'metadata/VERSION')|Should -BeFalse
        [void](Undo-TpmTransaction $root $transaction.transactionId)
        [IO.File]::ReadAllText((Join-Path $root 'VERSION'))|Should -Be '1.2.1'
    }
    It 'updates and rolls back an already compact installation' {
        Write-FixtureFile (Join-Path $root 'metadata/VERSION') '1.2.1'
        Remove-Item -LiteralPath (Join-Path $root 'VERSION')
        Write-FixtureFile (Join-Path $root 'zapretctl.ps1') 'old controller'
        $manifest='{"schemaVersion":1,"managedFiles":["metadata/VERSION","zapretctl.ps1"]}'
        Write-FixtureFile (Join-Path $root 'metadata/release-manifest.json') $manifest
        $archive=New-UpdateFixture (Join-Path $TestDrive ([Guid]::NewGuid().ToString('N')))
        $transaction=Install-TpmUpdate $root $archive (Get-FileHash $archive).Hash
        (Get-TpmBuildInfo $root).version|Should -Be '2.0.0'
        Test-Path (Join-Path $root 'VERSION')|Should -BeFalse
        Test-Path (Join-Path $root '.tpm-release-manifest.json')|Should -BeFalse
        [void](Undo-TpmTransaction $root $transaction.transactionId)
        (Get-TpmBuildInfo $root).version|Should -Be '1.2.1'
        [IO.File]::ReadAllText((Join-Path $root 'metadata/release-manifest.json'))|Should -Be $manifest
    }

    It 'refuses bad archive hashes and downgrades before creating a transaction' {
        $archive=New-UpdateFixture (Join-Path $TestDrive ([Guid]::NewGuid().ToString('N')))
        {Install-TpmUpdate $root $archive ('0'*64)}|Should -Throw '*SHA-256 mismatch*'
        Write-FixtureFile (Join-Path $root 'VERSION') '3.0.0'
        {Install-TpmUpdate $root $archive (Get-FileHash $archive).Hash}|Should -Throw '*older release*'
        Test-Path (Join-Path $root 'backups/transactions')|Should -BeFalse
    }
    It 'restores the previous installation automatically after a write failure' {
        Write-FixtureFile (Join-Path $root 'tools/new.ps1') 'old helper'
        Write-FixtureFile (Join-Path $root 'zapretctl.ps1') 'old controller'
        $archive=New-UpdateFixture (Join-Path $TestDrive ([Guid]::NewGuid().ToString('N')))
        Mock Copy-MaintenanceFile {
            param($Source,$Destination)
            if($Destination -match '[\\/]tools[\\/]new\.ps1$' -and $Destination -notmatch '[\\/]backups[\\/]'){throw 'Simulated write failure'}
            New-Item -ItemType Directory -Path (Split-Path -Parent $Destination) -Force|Out-Null
            [IO.File]::Copy($Source,$Destination,$true)
        } -ModuleName TrafficProfileManager.Maintenance
        {Install-TpmUpdate $root $archive (Get-FileHash $archive).Hash}|Should -Throw '*Simulated write failure*'
        [IO.File]::ReadAllText((Join-Path $root 'VERSION'))|Should -Be '1.2.1'
        [IO.File]::ReadAllText((Join-Path $root 'zapretctl.ps1'))|Should -Be 'old controller'
        [IO.File]::ReadAllText((Join-Path $root 'tools/new.ps1'))|Should -Be 'old helper'
    }
    It 'rejects a modified backup before replacing any user file' {
        $backup=New-TpmUserBackup $root
        $zip=[IO.Compression.ZipFile]::Open($backup.archive,'Update')
        try {
            $zip.GetEntry('lists/user-domains.txt').Delete()
            $entry=$zip.CreateEntry('lists/user-domains.txt')
            $writer=[IO.StreamWriter]::new($entry.Open())
            try{$writer.Write('tampered.example')}finally{$writer.Dispose()}
        }finally{$zip.Dispose()}
        {Restore-TpmUserBackup $root $backup.archive}|Should -Throw '*provenance mismatch*'
        [IO.File]::ReadAllText((Join-Path $root 'lists/user-domains.txt'))|Should -Be 'custom.example'
    }
    It 'uses the official release digest and rejects unexpected download hosts' {
        Mock Invoke-RestMethod {
            [pscustomobject]@{tag_name='v2.0.0';assets=@([pscustomobject]@{name='TrafficProfileManager.zip';digest=('sha256:'+('A'*64));browser_download_url='https://github.com/ArcheKaren/Traffic-Profile-Manager/releases/download/v2.0.0/TrafficProfileManager.zip'})}
        } -ModuleName TrafficProfileManager.Maintenance
        $release=Get-TpmLatestRelease
        $release.version|Should -Be '2.0.0'
        $release.sha256|Should -Be ('A'*64)
        Mock Invoke-RestMethod {
            [pscustomobject]@{assets=@([pscustomobject]@{name='TrafficProfileManager.zip';browser_download_url='https://example.org/payload.zip'})}
        } -ModuleName TrafficProfileManager.Maintenance
        {Get-TpmLatestRelease}|Should -Throw '*Unexpected update URL*'
    }
    It 'does not download a release older than the current installation' {
        Mock Get-TpmLatestRelease { [pscustomobject]@{version='1.2.0'} } -ModuleName TrafficProfileManager.Maintenance
        Mock Invoke-WebRequest { throw 'Unexpected download' } -ModuleName TrafficProfileManager.Maintenance
        {Save-TpmLatestRelease $root}|Should -Throw '*No newer release*'
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly -ModuleName TrafficProfileManager.Maintenance
    }
    It 'rejects duplicate and escaping archive paths' {
        $archive=Join-Path $TestDrive ([Guid]::NewGuid().ToString('N')+'.zip')
        $zip=[IO.Compression.ZipFile]::Open($archive,'Create')
        try {[void]$zip.CreateEntry('../outside.txt')}finally{$zip.Dispose()}
        {Get-TpmRestorePlan $root $archive}|Should -Throw '*Unsafe*'
        $archive2=Join-Path $TestDrive ([Guid]::NewGuid().ToString('N')+'.zip')
        $zip=[IO.Compression.ZipFile]::Open($archive2,'Create')
        try {[void]$zip.CreateEntry('config/x.json');[void]$zip.CreateEntry('CONFIG/X.JSON')}finally{$zip.Dispose()}
        {Get-TpmRestorePlan $root $archive2}|Should -Throw '*Duplicate*'
    }
    It 'will not roll back over edits made after the update' {
        $archive=New-UpdateFixture (Join-Path $TestDrive ([Guid]::NewGuid().ToString('N')))
        $transaction=Install-TpmUpdate $root $archive (Get-FileHash $archive).Hash
        Write-FixtureFile (Join-Path $root 'zapretctl.ps1') 'my later edit'
        {Undo-TpmTransaction $root $transaction.transactionId}|Should -Throw '*changed after*'
        [IO.File]::ReadAllText((Join-Path $root 'zapretctl.ps1'))|Should -Be 'my later edit'
    }
    It 'reads saved comparison results without selecting a profile' {
        Write-FixtureFile (Join-Path $root 'test-results/profile-comparison-20261102-120000.csv') @'
ProfileId,Profile,Success
profile-a,Profile A,True
profile-a,Profile A,False
profile-b,Profile B,True
'@
        $config=[IO.File]::ReadAllText((Join-Path $root 'config/config.json'))
        $report=@(Get-TpmComparisonResults $root)[0]
        $report.ranking[0].profileId|Should -Be 'profile-b'
        $report.ranking[0].score|Should -Be 100
        [IO.File]::ReadAllText((Join-Path $root 'config/config.json'))|Should -Be $config
    }
    It 'detects incomplete mapping blocks without editing the hosts file' {
        $hosts=Join-Path $root 'hosts'
        $text="203.0.113.10 unrelated.example`n# TrafficProfileManager Mapping BEGIN`n"
        Write-FixtureFile $hosts $text
        $overview=Get-TpmOverview -AppRoot $root -HostsPath $hosts
        $overview.mappings|Should -Be 'incomplete'
        @(Get-TpmAdvice $overview).code|Should -Contain 'hosts-incomplete'
        [IO.File]::ReadAllText($hosts)|Should -Be $text
    }
}
