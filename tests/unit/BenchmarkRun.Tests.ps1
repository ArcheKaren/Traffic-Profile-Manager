Describe 'Comparison workflow without live network traffic' {
    BeforeAll {
        $projectRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        Import-Module (Join-Path $projectRoot 'modules/TrafficProfileManager.Maintenance/TrafficProfileManager.Maintenance.psd1') -Force
        Import-Module (Join-Path $projectRoot 'modules/TrafficProfileManager.Console/TrafficProfileManager.Console.psd1') -Force
        Import-Module (Join-Path $projectRoot 'modules/TrafficProfileManager.Core/TrafficProfileManager.Core.psd1') -Force
        . (Join-Path $projectRoot 'tools/benchmark-library.ps1')
        $script:realStartInfo=(Get-Command New-TpmProcessStartInfo).ScriptBlock
        function Read-Targets {return @([pscustomobject]@{Name='one';Url='https://one.example';Host='one.example'},[pscustomobject]@{Name='two';Url='https://two.example';Host='two.example'})}
        function Start-Profile([string]$Id){$script:fakeProfile=$Id;$script:startedProfiles.Add($Id)}
        function Stop-ActiveProfile {$script:fakeProfile=''}
        function Invoke-TargetChecks($Targets){foreach($target in $Targets){$success=$script:fakeProfile -eq 'strategy-wa-pc-pos1';[pscustomobject]@{Target=$target.Name;Url=$target.Url;Success=$success;Healthy=$success;HttpCode=$(if($success){'200'}else{'000'});ExitCode=$(if($success){0}else{28});Detail='fixture'}}}
    }
    BeforeEach {
        $appRoot=Join-Path $TestDrive ([Guid]::NewGuid().ToString('N').Substring(0,8))
        New-Item -ItemType Directory -Path $appRoot|Out-Null
        foreach($dir in @('config','lists','assets')){Copy-Item -LiteralPath (Join-Path $projectRoot $dir) -Destination (Join-Path $appRoot $dir) -Recurse}
        New-Item -ItemType Directory -Path (Join-Path $appRoot 'tools')|Out-Null
        [IO.File]::WriteAllText((Join-Path $appRoot 'tools/manage-network-mappings.ps1'),'param($Action) Add-Content -LiteralPath (Join-Path (Split-Path $PSScriptRoot) "mapping-calls.txt") -Value $Action')
        $profileCatalog=@([pscustomobject]@{Id='strategy-wa-pc-pos1';Label='Base';Number=1},[pscustomobject]@{Id='strategy-variant-quic';Label='QUIC';Number=2})
        $invalidProfiles=@();$Profiles=@();$NonInteractive=$true;$Mode='quick';$Rounds=1;$SkipBaseline=$false
        $settings=[pscustomobject]@{baseline=$true;fullRounds=2;quickRounds=1;finalistCount=1;finalistExtraRounds=2}
        $resultRoot=Join-Path $appRoot 'test-results';$stateRoot=Join-Path $appRoot 'state';$benchmarkHostList=Join-Path $stateRoot 'benchmark-domains.txt'
        $script:managedMappingsInstalled=$false;$script:fakeProfile='';$script:startedProfiles=New-Object 'Collections.Generic.List[string]'
        $originalBenchmarkEnvironment=$env:TRAFFIC_PROFILE_BENCHMARK_LIST
        Mock Test-TpmIsAdministrator {return $true}
        Mock Get-Service {}
        Mock Get-Process {param($Id,$Name) if($Id){return [pscustomobject]@{StartTime=[DateTime]::Now}}}
        Mock Write-TpmUi {}
        Mock New-TpmProcessStartInfo {& $script:realStartInfo -FilePath powershell.exe -ArgumentList @('-NoLogo','-NoProfile','-NonInteractive','-Command','exit 0') -CreateNoWindow -RedirectStandardOutput -RedirectStandardError}
    }
    It 'measures the baseline, repeats leaders and keeps reports compatible with saved results' {
        . (Join-Path $projectRoot 'tools/benchmark-run.ps1')
        $rows=@(Import-Csv (Get-ChildItem $resultRoot -Filter '*.csv').FullName)
        @($rows|Where-Object ProfileId -eq '__baseline__').Count|Should -Be 2
        @($rows|Where-Object ProfileId -eq 'strategy-wa-pc-pos1').Count|Should -Be 6
        @($rows|Where-Object ProfileId -eq 'strategy-variant-quic').Count|Should -Be 2
        $results=@(Get-TpmComparisonResults $appRoot)
        $results[0].ranking[0].profileId|Should -Be strategy-wa-pc-pos1
        $results[0].ranking[0].stable|Should -Be 2
        $results[0].ranking.profileId|Should -Not -Contain '__baseline__'
        [IO.File]::ReadAllLines((Join-Path $appRoot 'mapping-calls.txt'))|Should -Be @('install','cleanup')
        Test-Path -LiteralPath $benchmarkHostList|Should -BeFalse
    }
    It 'cancels before mappings, reports or worker processes are created' {
        $NonInteractive=$false
        Mock Read-TpmUi {'0'}
        . (Join-Path $projectRoot 'tools/benchmark-run.ps1')
        $script:startedProfiles.Count|Should -Be 0
        Test-Path -LiteralPath (Join-Path $appRoot 'mapping-calls.txt')|Should -BeFalse
        Test-Path -LiteralPath $resultRoot|Should -BeFalse
        Should -Invoke New-TpmProcessStartInfo -Times 0 -Exactly
    }
    It 'uses repeated checks for all profiles in full mode without finalist-only extra rounds' {
        $Mode='full';$Rounds=2
        . (Join-Path $projectRoot 'tools/benchmark-run.ps1')
        $rows=@(Import-Csv (Get-ChildItem $resultRoot -Filter '*.csv').FullName)
        $rows.Count|Should -Be 12
        foreach($group in @($rows|Group-Object ProfileId)){$group.Count|Should -Be 4}
    }
    It 'refuses an existing traffic process without starting or stopping it' {
        Mock Get-Process {return [pscustomobject]@{Id=123}}
        {. (Join-Path $projectRoot 'tools/benchmark-run.ps1')}|Should -Throw '*Stop running profiles*'
        $script:startedProfiles.Count|Should -Be 0
        Test-Path -LiteralPath (Join-Path $appRoot 'mapping-calls.txt')|Should -BeFalse
    }
}
