Describe 'WinDivert removal is independent of driver location' {
    BeforeAll {
        $projectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $tokens = $null
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $projectRoot 'tools/service-control.ps1'),
            [ref]$tokens,
            [ref]$errors
        )
        if ($errors) { throw 'Service control did not parse.' }
        # Load definitions and the real action dispatcher without executing its startup code.
        foreach ($definition in $ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst]
        }, $false)) {
            . ([scriptblock]::Create($definition.Extent.Text))
        }
        $dispatcher = $ast.Find({
            param($node)
            $node -is [Management.Automation.Language.SwitchStatementAst] -and
                $node.Condition.Extent.Text -eq '$Action'
        }, $false)
        if (-not $dispatcher) { throw 'Service action dispatcher was not found.' }
        $script:serviceDispatcher = [scriptblock]::Create($dispatcher.Extent.Text)

        # Fail closed if any test accidentally bypasses the SCM mock.
        function sc.exe([string]$Operation, [string]$Name) {
            throw "Native SCM must never run in these tests: $Operation $Name"
        }
        function Write-TpmUi([string]$Object, [ConsoleColor]$ForegroundColor) {}
        function Invoke-TpmControllerCommand {
            throw 'The real controller must never run in these tests.'
        }
    }

    BeforeEach {
        $script:serviceRoot = Join-Path $TestDrive ([Guid]::NewGuid().ToString('N') + " service user's path")
        $script:serviceMarker = Join-Path $serviceRoot '.tpm-managed-service'
        $script:profileState = Join-Path $TestDrive ([Guid]::NewGuid().ToString('N') + '-profile.txt')
        New-Item -ItemType Directory -Path $serviceRoot | Out-Null
        [IO.File]::WriteAllText($serviceMarker, 'managed fixture')
        [IO.File]::WriteAllText($profileState, 'fixture-profile')
        $script:driverPath = [IO.Path]::GetFullPath((Join-Path $serviceRoot 'runtime/WinDivert64.sys'))
        $script:stopExitCode = 0
        $script:deleteExitCode = 0
        $script:driverRegistered = $true
        $script:driverRemovedAfterDelete = $true
        $script:scmCalls = New-Object 'Collections.Generic.List[string]'
        $script:messages = New-Object 'Collections.Generic.List[object]'
        $script:removeEvents = New-Object 'Collections.Generic.List[string]'
        $script:previousExitCode = $global:LASTEXITCODE
        $global:LASTEXITCODE = 0


        Mock sc.exe {
            param($Operation, $Name)
            if ($Name -ne 'WinDivert') { throw "Unexpected driver: $Name" }
            $script:scmCalls.Add("$Operation $Name")
            $script:removeEvents.Add("driver:$Operation")
            switch ($Operation) {
                'stop' { $global:LASTEXITCODE = $script:stopExitCode }
                'delete' { $global:LASTEXITCODE = $script:deleteExitCode; if ($script:driverRemovedAfterDelete) { $script:driverRegistered = $false } }
                default { throw "Unexpected SCM operation: $Operation" }
            }
        }
        Mock Test-Path { return $script:driverRegistered } -ParameterFilter {
            $LiteralPath -eq 'HKLM:\SYSTEM\CurrentControlSet\Services\WinDivert'
        }
        Mock Get-ItemPropertyValue { return $script:driverPath }
        Mock Write-TpmUi {
            param($Object, $ForegroundColor)
            $script:messages.Add([pscustomobject]@{
                Text = [string]$Object
                Color = $ForegroundColor
            })
        }
        Mock Assert-ManagedServiceOwnership { $script:removeEvents.Add('ownership:service') }
        Mock Assert-ServiceDeploymentPath {}
        Mock Invoke-TpmControllerCommand {}
        Mock Get-Process {}
        Mock Remove-ManagedRefreshTask { $script:removeEvents.Add('task:remove') }
        Mock Remove-ManagedService { $script:removeEvents.Add('service:remove') }
        Mock Invoke-ServiceMapping {
            param($MappingAction)
            $script:removeEvents.Add("mapping:$MappingAction")
        }
        Mock Remove-ServiceDeployment { $script:removeEvents.Add('deployment:remove') }
    }

    AfterEach {
        $global:LASTEXITCODE = $script:previousExitCode
    }

    It 'removes the registered driver regardless of its location: <Location>' -TestCases @(
        @{ Location = 'protected deployment' }
        @{ Location = 'portable folder' }
        @{ Location = 'another application' }
        @{ Location = 'Windows system folder' }
    ) {
        param($Location)
        $script:driverPath = switch ($Location) {
            'protected deployment' { Join-Path $serviceRoot 'runtime/WinDivert64.sys' }
            'portable folder' { Join-Path $TestDrive "portable user's folder/runtime/WinDivert64.sys" }
            'another application' { Join-Path $TestDrive 'other application/WinDivert64.sys' }
            default { '\SystemRoot\System32\drivers\WinDivert64.sys' }
        }
        { Remove-ManagedWinDivertDriver } | Should -Not -Throw
        ($script:scmCalls -join ',') | Should -Be 'stop WinDivert,delete WinDivert'
        $script:driverRegistered | Should -BeFalse
        Should -Invoke Get-ItemPropertyValue -Times 0 -Exactly
    }

    It 'does nothing when no driver is registered' {
        $script:driverRegistered = $false
        { Remove-ManagedWinDivertDriver } | Should -Not -Throw
        $script:scmCalls.Count | Should -Be 0
    }

    It 'deletes an already stopped driver' {
        $script:stopExitCode = 1062
        { Remove-ManagedWinDivertDriver } | Should -Not -Throw
        ($script:scmCalls -join ',') | Should -Be 'stop WinDivert,delete WinDivert'
        $global:LASTEXITCODE | Should -Be 0
    }

    It 'accepts a nonzero delete result when registration has disappeared' {
        $script:deleteExitCode = 1072
        { Remove-ManagedWinDivertDriver } | Should -Not -Throw
        $script:driverRegistered | Should -BeFalse
        $global:LASTEXITCODE | Should -Be 0
    }

    It 'reports both native exit codes when deletion fails and registration remains' {
        $script:stopExitCode = 1062
        $script:deleteExitCode = 5
        $script:driverRemovedAfterDelete = $false
        { Remove-ManagedWinDivertDriver } | Should -Throw '*exit code 5 (stop exit code 1062)*'
        ($script:scmCalls -join ',') | Should -Be 'stop WinDivert,delete WinDivert'
    }

    It 'does not report success when Windows keeps the driver registered after a successful delete request' {
        $script:driverRemovedAfterDelete = $false
        { Remove-ManagedWinDivertDriver } | Should -Throw '*still registered or in use*'
        $script:driverRegistered | Should -BeTrue
    }

    It 'keeps the driver file available for the next portable launch' {
        $file = Join-Path $TestDrive "another user's driver.sys"
        [IO.File]::WriteAllText($file, 'fixture driver; never loaded')
        $script:driverPath = $file
        $hash = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash
        Remove-ManagedWinDivertDriver
        (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash | Should -Be $hash
        $script:driverRegistered | Should -BeFalse
    }

    It 'finishes removing the service, driver and mappings for an external driver location' {
        $script:Action = 'remove'
        $script:driverPath = Join-Path $TestDrive 'other application/WinDivert64.sys'
        { & $script:serviceDispatcher } | Should -Not -Throw
        ($script:scmCalls -join ',') | Should -Be 'stop WinDivert,delete WinDivert'
        Test-Path -LiteralPath $profileState | Should -BeFalse
        $script:removeEvents | Should -Contain 'mapping:cleanup'
        $script:removeEvents | Should -Contain 'deployment:remove'
        $script:removeEvents.IndexOf('service:remove') | Should -BeLessThan ($script:removeEvents.IndexOf('driver:stop'))
        $script:removeEvents.IndexOf('driver:delete') | Should -BeLessThan ($script:removeEvents.IndexOf('mapping:cleanup'))
        @($script:messages | Where-Object Color -eq 'Green').Count | Should -Be 1
    }

    It 'keeps the deployment and profile state when driver removal is incomplete' {
        $script:Action = 'remove'
        Mock Remove-ManagedWinDivertDriver { throw 'Fixture: driver still in use.' }
        { & $script:serviceDispatcher } | Should -Throw '*driver still in use*'
        Test-Path -LiteralPath $profileState | Should -BeTrue
        Should -Invoke Invoke-ServiceMapping -Times 0 -Exactly
        Should -Invoke Remove-ServiceDeployment -Times 0 -Exactly
        @($script:messages | Where-Object Color -eq 'Green').Count | Should -Be 0
    }

    It 'refuses an unmarked deployment before modifying services or mappings' {
        $script:Action = 'remove'
        Remove-Item -LiteralPath $serviceMarker
        { & $script:serviceDispatcher } | Should -Throw '*unrecognized protected service directory*'
        $script:scmCalls.Count | Should -Be 0
        Should -Invoke Remove-ManagedService -Times 0 -Exactly
        Should -Invoke Invoke-ServiceMapping -Times 0 -Exactly
        Should -Invoke Remove-ServiceDeployment -Times 0 -Exactly
    }

    It 'removes an existing external driver before creating a new protected deployment' {
        $script:Action = 'install'
        $script:Profile = 'fixture-profile'
        $script:appRoot = Join-Path $TestDrive 'application fixture'
        $profiles = Join-Path $appRoot 'config/profiles'
        New-Item -ItemType Directory -Path $profiles -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $profiles ($Profile + '.json')), '{}')
        $script:driverPath = Join-Path $TestDrive 'other application/WinDivert64.sys'
        Mock New-ServiceDeployment {
            if ($script:driverRegistered) { throw 'The external driver must be unregistered first.' }
            $script:removeEvents.Add('deployment:create')
            throw 'Fixture: stop installation before native service creation.'
        }
        { & $script:serviceDispatcher } | Should -Throw '*stop installation before native service creation*'
        ($script:scmCalls -join ',') | Should -Be 'stop WinDivert,delete WinDivert'
        $script:removeEvents.IndexOf('driver:delete') | Should -BeLessThan ($script:removeEvents.IndexOf('deployment:create'))
        Should -Invoke New-ServiceDeployment -Times 1 -Exactly
    }
}

Describe 'WinDivert removal error translation' {
    BeforeAll {
        $projectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        Import-Module (Join-Path $projectRoot 'modules/TrafficProfileManager.Console/TrafficProfileManager.Console.psd1') -Force
        $dictionary = [IO.File]::ReadAllText((Join-Path $projectRoot 'modules/TrafficProfileManager.Console/ru.json')) | ConvertFrom-Json
    }
    It 'translates an incomplete driver removal error' {
        $root = Join-Path $TestDrive 'language fixture'
        $message = 'WinDivert is still registered or in use. Stop applications that use it and retry.'
        Set-TpmLanguage -Language en -AppRoot $root
        Get-TpmText $message | Should -Be $message
        Set-TpmLanguage -Language ru -AppRoot $root
        Get-TpmText $message | Should -Be $dictionary.$message
        Get-TpmText $message | Should -Not -Be $message
    }
}
