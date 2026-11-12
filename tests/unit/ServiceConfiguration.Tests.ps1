Describe 'Transactional application to a protected service copy' {
    BeforeAll {
        $projectRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        Import-Module (Join-Path $projectRoot 'modules/TrafficProfileManager.Maintenance/TrafficProfileManager.Maintenance.psd1') -Force
        . (Join-Path $projectRoot 'tools/service-configuration.ps1')
        function Assert-ManagedServiceOwnership {}
        function Assert-ServiceDeploymentOwnership {}
        function Get-ManagedRefreshTask {}
        function Set-ProtectedServiceAcl {}
        function Invoke-ServiceMapping {}
        function Get-ProtectedLaunchBinaryPath { return 'new-command' }
        function Set-ManagedServiceBinaryPath([string]$BinaryPath) {
            $script:binaryChanges.Add($BinaryPath)
            if($BinaryPath -eq 'new-command' -and $script:rejectActivation){throw 'Injected SCM failure'}
        }
        function Write-ServiceFixture([string]$Path,[string]$Text){New-Item -ItemType Directory -Path (Split-Path $Path) -Force|Out-Null;[IO.File]::WriteAllText($Path,$Text,[Text.UTF8Encoding]::new($false))}
    }
    BeforeEach {
        $script:appRoot=Join-Path $TestDrive ('a'+[Guid]::NewGuid().ToString('N').Substring(0,6))
        $script:serviceRoot=Join-Path $TestDrive ('s'+[Guid]::NewGuid().ToString('N').Substring(0,6))
        foreach($root in @($appRoot,$serviceRoot)){
            New-Item -ItemType Directory -Path $root|Out-Null
            foreach($dir in @('config','lists','assets')){Copy-Item -LiteralPath (Join-Path $projectRoot $dir) -Destination (Join-Path $root $dir) -Recurse}
        }
        $script:serviceName='TrafficProfileService';$script:mappingTaskName='TrafficProfileMappingRefresh';$script:Profile=''
        $script:binaryChanges=New-Object 'Collections.Generic.List[string]';$script:rejectActivation=$false
        Write-ServiceFixture (Join-Path $appRoot 'lists/user-domains.txt') 'new.example'
        Write-ServiceFixture (Join-Path $serviceRoot 'lists/user-domains.txt') 'old.example'
        $service=[pscustomobject]@{Status='Running'};$service|Add-Member -MemberType ScriptMethod -Name WaitForStatus -Value {param($Status,$Timeout)}
        Mock Get-Service {return $service}
        Mock Get-CimInstance {[pscustomobject]@{PathName='old-command';ProcessId=321}}
        Mock Get-Process {}
        Mock Start-Service {}
        Mock Stop-Service {}
        Mock Invoke-TpmCandidateCheck {} -ModuleName TrafficProfileManager.Maintenance
        Mock Get-Service {return $service} -ModuleName TrafficProfileManager.Maintenance
        Mock Start-Service {} -ModuleName TrafficProfileManager.Maintenance
        Mock Stop-Service {} -ModuleName TrafficProfileManager.Maintenance
    }
    It 'applies configuration without removing the service or changing startup policy' {
        $result=Apply-ManagedServiceConfiguration
        $result.applied|Should -BeTrue
        [IO.File]::ReadAllText((Join-Path $serviceRoot 'lists/user-domains.txt'))|Should -Be new.example
        $script:binaryChanges|Should -Contain new-command
        Test-Path -LiteralPath (Join-Path $serviceRoot 'state/applied-service.json')|Should -BeTrue
        Should -Invoke Stop-Service -Times 1 -Exactly -ModuleName TrafficProfileManager.Maintenance
    }
    It 'restores files and the previous SCM command if activation fails' {
        $script:rejectActivation=$true
        {Apply-ManagedServiceConfiguration}|Should -Throw '*Injected SCM failure*'
        [IO.File]::ReadAllText((Join-Path $serviceRoot 'lists/user-domains.txt'))|Should -Be old.example
        $script:binaryChanges.ToArray()[-1]|Should -Be old-command
    }
    It 'does not stop the service if candidate validation fails' {
        Mock Invoke-TpmCandidateCheck {throw 'Invalid candidate'} -ModuleName TrafficProfileManager.Maintenance
        {Apply-ManagedServiceConfiguration}|Should -Throw '*Invalid candidate*'
        [IO.File]::ReadAllText((Join-Path $serviceRoot 'lists/user-domains.txt'))|Should -Be old.example
        Should -Invoke Stop-Service -Times 0 -Exactly -ModuleName TrafficProfileManager.Maintenance
    }
    It 'keeps a previously stopped service stopped after applying settings' {
        Mock Get-Service {[pscustomobject]@{Status='Stopped'}}
        $result=Apply-ManagedServiceConfiguration
        $result.running|Should -BeFalse
        [IO.File]::ReadAllText((Join-Path $serviceRoot 'lists/user-domains.txt'))|Should -Be new.example
        Should -Invoke Start-Service -Times 0 -Exactly
        Should -Invoke Start-Service -Times 0 -Exactly -ModuleName TrafficProfileManager.Maintenance
        Should -Invoke Stop-Service -Times 0 -Exactly -ModuleName TrafficProfileManager.Maintenance
    }
    It 'reports the protected profile after applying settings instead of a stale source hint' {
        $script:profileState=Join-Path $appRoot 'state/service-profile.txt'
        Write-ServiceFixture $script:profileState 'old-profile'
        Write-ServiceFixture (Join-Path $serviceRoot 'config/config.json') '{"activeProfile":"new-profile"}'
        Get-ManagedServiceProfile|Should -Be new-profile
    }
}
