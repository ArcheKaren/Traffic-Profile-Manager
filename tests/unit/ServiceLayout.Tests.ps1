Describe 'Service deployment with compact product paths' {
    BeforeAll {
        $projectRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        . (Join-Path $projectRoot 'tests/fixtures/acl-signature.ps1')
        Import-Module (Join-Path $projectRoot 'modules/TrafficProfileManager.Core/TrafficProfileManager.Core.psd1') -Force
        $tokens=$null;$errors=$null
        $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $projectRoot 'tools/service-control.ps1'),[ref]$tokens,[ref]$errors)
        if($errors){throw 'Service control did not parse.'}
        # Load definitions only; do not execute service-control actions or touch SCM.
        foreach($definition in $ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst]},$false)) {
            . ([scriptblock]::Create($definition.Extent.Text))
        }
        function Clear-DnsClientCache {}
    }
    BeforeEach {
        $appRoot=$projectRoot
        $serviceRoot=Join-Path $TestDrive ([Guid]::NewGuid().ToString('N')+" service user's path")
        $serviceMarker=Join-Path $serviceRoot '.tpm-managed-service'
        $serviceMappingTool=Join-Path $serviceRoot 'tools/manage-network-mappings.ps1'
        $script:fakeRuntimeFile=Join-Path $TestDrive 'fake-runtime.bin'
        [IO.File]::WriteAllText($script:fakeRuntimeFile,'fixture runtime; never executed')
        Mock Test-TpmIsAdministrator {$true}
        Mock Assert-ServiceDeploymentPath {}
        Mock Remove-ServiceDeployment {}
        Mock Set-ProtectedServiceAcl {}
        Mock Get-VerifiedServiceRuntimeFile {$script:fakeRuntimeFile}
    }
    It 'copies a self-contained service tree with a working CLI and mapping cleanup' {
        New-ServiceDeployment 'strategy-wa-pc-pos1'
        foreach($relative in @('tools/manage-network-mappings.ps1','tools/watch-service-mappings.ps1','metadata/VERSION','zapretctl.ps1','config/rule-groups.json')) {
            Test-Path -LiteralPath (Join-Path $serviceRoot $relative) -PathType Leaf|Should -BeTrue
        }
        Test-Path -LiteralPath (Join-Path $serviceRoot 'manage-network-mappings.ps1')|Should -BeFalse
        Test-Path -LiteralPath (Join-Path $serviceRoot 'VERSION')|Should -BeFalse
        $output=& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $serviceRoot 'zapretctl.ps1') version --json
        $LASTEXITCODE|Should -Be 0
        ($output -join [Environment]::NewLine|ConvertFrom-Json).version|Should -Be (Get-TpmBuildInfo $projectRoot).version

        $hosts=Join-Path $serviceRoot 'fixture-hosts'
        $text=@('203.0.113.10 unrelated.example','# TrafficProfileManager Mapping BEGIN','198.51.100.42 managed.example','# TrafficProfileManager Mapping END') -join [Environment]::NewLine
        [IO.File]::WriteAllText($hosts,$text)
        $acl=Get-TpmTestAclSignature $hosts
        & (Join-Path $serviceRoot 'tools/manage-network-mappings.ps1') cleanup -AppRoot $serviceRoot -HostsPath $hosts
        [IO.File]::ReadAllText($hosts)|Should -Match 'unrelated.example'
        [IO.File]::ReadAllText($hosts)|Should -Not -Match 'Mapping BEGIN|managed.example'
        (Get-TpmTestAclSignature $hosts)|Should -Be $acl
    }
    It 'detects a real change to ACL inheritance protection' {
        $path=Join-Path $TestDrive 'acl-protection-fixture'
        [IO.File]::WriteAllText($path,'fixture')
        $original=Get-TpmTestAclSignature $path
        $acl=Get-Acl -LiteralPath $path
        $acl.SetAccessRuleProtection($true,$true)
        Set-Acl -LiteralPath $path -AclObject $acl
        (Get-TpmTestAclSignature $path)|Should -Not -Be $original
    }
    It 'uses the legacy mapping tool when controlling an older service snapshot' {
        New-Item -ItemType Directory -Path $serviceRoot|Out-Null
        $legacy='param([string]$Action,[string]$AppRoot); [pscustomobject]@{Action=$Action;Root=$AppRoot}'
        [IO.File]::WriteAllText((Join-Path $serviceRoot 'manage-network-mappings.ps1'),$legacy)
        $result=Invoke-ServiceMapping refresh
        $result.Action|Should -Be 'refresh'
        $result.Root|Should -Be $serviceRoot
    }
}
