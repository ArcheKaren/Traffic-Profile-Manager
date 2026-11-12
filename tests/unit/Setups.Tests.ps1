Describe 'Named setups and applied configuration' {
    BeforeAll {
        $projectRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        Import-Module (Join-Path $projectRoot 'modules/TrafficProfileManager.Maintenance/TrafficProfileManager.Maintenance.psd1') -Force
        function Write-SetupFixture([string]$Path,[string]$Text){New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force|Out-Null;[IO.File]::WriteAllText($Path,$Text,[Text.UTF8Encoding]::new($false))}
    }
    BeforeEach {
        $root=Join-Path $TestDrive ([Guid]::NewGuid().ToString('N')+" user's setup")
        New-Item -ItemType Directory -Path $root|Out-Null
        foreach($dir in @('config','lists','assets')){Copy-Item -LiteralPath (Join-Path $projectRoot $dir) -Destination (Join-Path $root $dir) -Recurse}
        Write-SetupFixture (Join-Path $root 'lists/user-domains.txt') 'original.example'
        Write-SetupFixture (Join-Path $root 'state/user-settings.json') '{"language":"ru","custom":42}'
        Mock Get-Service {} -ModuleName TrafficProfileManager.Maintenance
        Mock Get-Process {} -ModuleName TrafficProfileManager.Maintenance
    }
    It 'captures main without changing active settings and keeps setups out of source directories' {
        $before=(Get-FileHash (Join-Path $root 'config/config.json')).Hash
        Initialize-TpmSetups $root
        $sets=@(Get-TpmSetups $root)
        $sets.Count|Should -Be 1
        $sets[0].id|Should -Be main
        $sets[0].path|Should -Match 'state[\\/]setups'
        (Get-FileHash (Join-Path $root 'config/config.json')).Hash|Should -Be $before
    }
    It 'previews and switches editable TXT and JSON atomically while preserving UI settings' {
        Initialize-TpmSetups $root
        [void](Save-TpmSetup $root gaming 'Gaming')
        $path=Get-TpmSetupPath $root gaming
        $set=[IO.File]::ReadAllText($path)|ConvertFrom-Json
        $set.profile='strategy-variant-quic'
        Write-SetupFixture $path ($set|ConvertTo-Json -Depth 15)
        Write-SetupFixture (Join-Path (Split-Path $path) 'user-domains.txt') "gaming.example`r`n"
        $plan=@(Get-TpmSetupPlan $root gaming)
        $plan.path|Should -Contain 'lists/user-domains.txt'
        [IO.File]::ReadAllText((Join-Path $root 'lists/user-domains.txt'))|Should -Be original.example
        $result=Use-TpmSetup $root gaming
        ([IO.File]::ReadAllText((Join-Path $root 'config/config.json'))|ConvertFrom-Json).activeProfile|Should -Be strategy-variant-quic
        [IO.File]::ReadAllText((Join-Path $root 'lists/user-domains.txt')).Trim()|Should -Be gaming.example
        ([IO.File]::ReadAllText((Join-Path $root 'state/user-settings.json'))|ConvertFrom-Json).custom|Should -Be 42
        [void](Undo-TpmTransaction $root $result.transactionId)
        [IO.File]::ReadAllText((Join-Path $root 'lists/user-domains.txt'))|Should -Be original.example
    }
    It 'rejects missing references and invalid lists before any active file is replaced' {
        [void](Save-TpmSetup $root broken)
        $path=Get-TpmSetupPath $root broken
        $set=[IO.File]::ReadAllText($path)|ConvertFrom-Json;$set.domainPacks=@('missing')
        Write-SetupFixture $path ($set|ConvertTo-Json -Depth 15)
        {Use-TpmSetup $root broken}|Should -Throw '*missing domain packs*'
        [IO.File]::ReadAllText((Join-Path $root 'lists/user-domains.txt'))|Should -Be original.example
        $set.domainPacks=@();Write-SetupFixture $path ($set|ConvertTo-Json -Depth 15)
        Write-SetupFixture (Join-Path (Split-Path $path) 'user-domains.txt') 'bad domain !'
        {Use-TpmSetup $root broken}|Should -Throw
    }
    It 'refuses switching while a traffic process runs but permits a stopped installed service' {
        [void](Save-TpmSetup $root gaming)
        Mock Get-Process {[pscustomobject]@{Id=123}} -ModuleName TrafficProfileManager.Maintenance
        {Use-TpmSetup $root gaming}|Should -Throw '*Stop running*'
        Mock Get-Process {} -ModuleName TrafficProfileManager.Maintenance
        Mock Get-Service {[pscustomobject]@{Status='Stopped'}} -ModuleName TrafficProfileManager.Maintenance
        $result=Use-TpmSetup $root gaming
        {Undo-TpmTransaction $root $result.transactionId}|Should -Not -Throw
    }
    It 'rejects traversal and reserved IDs' {
        {Save-TpmSetup $root '../escape'}|Should -Throw
        {Save-TpmSetup $root CON}|Should -Throw
        {Get-TpmSetupPath $root 'home.with.dot'}|Should -Throw
    }
    It 'backs up and restores setup data and recipes without launch snapshots' {
        [void](Save-TpmSetup $root gaming)
        Write-SetupFixture (Join-Path $root 'state/profile-recipes/custom.json') '{"schemaVersion":1}'
        Write-SetupFixture (Join-Path $root 'state/applied-process.json') '{"process":123}'
        $backup=New-TpmUserBackup $root
        $paths=@(Get-TpmRestorePlan $root $backup.archive).path
        $paths|Should -Contain 'state/setups/gaming/setup.json'
        $paths|Should -Contain 'state/setups/gaming/user-domains.txt'
        $paths|Should -Contain 'state/profile-recipes/custom.json'
        $paths|Should -Not -Contain 'state/applied-process.json'
    }
    It 'detects relevant edits and ignores UI language and unrelated profiles' {
        $before=New-TpmConfigurationSnapshot $root
        $again=New-TpmConfigurationSnapshot $root
        $again.contentSha256|Should -Be $before.contentSha256
        Write-SetupFixture (Join-Path $root 'state/user-settings.json') '{"language":"en"}'
        Add-Content -LiteralPath (Join-Path $root 'config/profiles/strategy-variant-quic.json') -Value ' '
        @(Compare-TpmConfigurationSnapshots $before (New-TpmConfigurationSnapshot $root)).Count|Should -Be 0
        Write-SetupFixture (Join-Path $root 'lists/user-domains.txt') 'changed.example'
        @(Compare-TpmConfigurationSnapshots $before (New-TpmConfigurationSnapshot $root)).path|Should -Contain 'lists/user-domains.txt'
    }
    It 'does not treat a stale process snapshot as a running session' {
        $snapshot=New-TpmConfigurationSnapshot $root
        $snapshot|Add-Member -NotePropertyName process -NotePropertyValue @{pid=345;executable='other.exe';startTimeUtcTicks=123}
        Write-SetupFixture (Join-Path $root 'state/applied-process.json') ($snapshot|ConvertTo-Json -Depth 12)
        (Get-TpmConfigurationStatus $root).status|Should -Be stopped
        Write-SetupFixture (Join-Path $root 'lists/user-domains.txt') 'changed.example'
        (Get-TpmConfigurationStatus $root).status|Should -Be pending
    }
    It 'keeps an explicit BAT profile override applied until the configured selection actually changes' {
        $snapshot=New-TpmConfigurationSnapshot $root 'strategy-variant-quic'
        Write-SetupFixture (Join-Path $root 'state/applied-process.json') ($snapshot|ConvertTo-Json -Depth 12)
        $status=Get-TpmConfigurationStatus $root
        $status.status|Should -Be stopped
        $status.configuredProfile|Should -Be 'strategy-wa-pc-pos1'
        $status.effectiveProfile|Should -Be 'strategy-variant-quic'
        $configPath=Join-Path $root 'config/config.json'
        $config=[IO.File]::ReadAllText($configPath)|ConvertFrom-Json
        $config.activeProfile='strategy-variant-split1'
        Write-SetupFixture $configPath ($config|ConvertTo-Json)
        $status=Get-TpmConfigurationStatus $root
        $status.status|Should -Be pending
        $status.changes.path|Should -Contain 'options.profile'
    }
    It 'reports an adopted live process as unknown when no matching launch snapshot exists' {
        $start=[DateTime]::UtcNow.AddMinutes(-1)
        $script:adoptedFixture=[pscustomobject]@{ProcessName='winws2';Path='C:\fixture\winws2.exe';StartTime=$start}
        Mock Get-Process {param($Id) if($Id -eq 456){return $script:adoptedFixture}} -ModuleName TrafficProfileManager.Maintenance
        Write-SetupFixture (Join-Path $root 'state/winws2.identity.json') (@{pid=456;executable='C:\fixture\winws2.exe';startTimeUtcTicks=$start.Ticks}|ConvertTo-Json)
        $status=Get-TpmConfigurationStatus $root
        $status.running|Should -BeTrue
        $status.status|Should -Be unknown
        $status.appliedProfile|Should -BeNullOrEmpty
    }
}
