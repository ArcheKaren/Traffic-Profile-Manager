Describe 'Benchmark profile readiness' {
    BeforeAll {
        $projectRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        Import-Module (Join-Path $projectRoot 'modules/TrafficProfileManager.Core/TrafficProfileManager.Core.psd1') -Force
        $script:originalStartInfo=(Get-Command New-TpmProcessStartInfo).ScriptBlock
        $tokens=$null;$errors=$null
        $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $projectRoot 'tools/profile-benchmark.ps1'),[ref]$tokens,[ref]$errors)
        $function=$ast.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Start-Profile'},$true)
        . ([scriptblock]::Create($function.Extent.Text))
        function Stop-ActiveProfile {}
    }
    BeforeEach {
        $script:stateRoot=Join-Path $TestDrive ([Guid]::NewGuid().ToString('N')+" state user's path")
        New-Item -ItemType Directory -Path $script:stateRoot|Out-Null
        $script:appRoot=$projectRoot
        $script:StartupSeconds=0
        $script:controller=$null
        $script:readyDelay=0
        $script:exitBeforeReady=$false
        Mock New-TpmProcessStartInfo {
            $arguments=@('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $projectRoot 'tests/fixtures/benchmark-controller.ps1'),'-StateRoot',$script:stateRoot,'-ReadyDelayMs',[string]$script:readyDelay)
            if($script:exitBeforeReady){$arguments+='-ExitBeforeReady'}
            & $script:originalStartInfo -FilePath powershell.exe -ArgumentList $arguments -CreateNoWindow
        }
        Mock Select-String { throw 'Benchmark must not inspect the system hosts file.' }
    }
    AfterEach {
        if($script:controller){if(-not $script:controller.HasExited){$script:controller.Kill();[void]$script:controller.WaitForExit(5000)};$script:controller.Dispose()}
    }
    It 'starts endpoint checks when the session is ready without any specific host mapping' {
        { Start-Profile 'fixture' }|Should -Not -Throw
        Test-Path -LiteralPath (Join-Path $script:stateRoot ("mapping-ready-$($script:controller.Id).flag"))|Should -BeTrue
        Should -Invoke Select-String -Times 0 -Exactly
    }
    It 'waits for mapping preparation even when a legacy host lookup would already succeed' {
        $script:readyDelay=1000
        Mock Select-String { return $true }
        { Start-Profile 'fixture' }|Should -Not -Throw
        Test-Path -LiteralPath (Join-Path $script:stateRoot ("mapping-ready-$($script:controller.Id).flag"))|Should -BeTrue
        Should -Invoke Select-String -Times 0 -Exactly
    }
    It 'reports a controller exit while mapping preparation has not finished' {
        $script:readyDelay=700
        $script:exitBeforeReady=$true
        Mock Select-String { return $false }
        { Start-Profile 'fixture' }|Should -Throw '*stopped*'
    }
}