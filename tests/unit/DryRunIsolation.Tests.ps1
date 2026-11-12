Describe 'Dry-run argument isolation' {
    BeforeAll {
        $projectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        Import-Module (Join-Path $projectRoot 'modules/TrafficProfileManager.Controller/TrafficProfileManager.Controller.psd1') -Force
        $controller = Get-Module TrafficProfileManager.Controller
        $fixtureRoot = Join-Path $TestDrive "dry-run user's configuration"
        New-Item -ItemType Directory -Path $fixtureRoot | Out-Null
        foreach ($directory in @('config', 'lists', 'assets')) {
            Copy-Item -LiteralPath (Join-Path $projectRoot $directory) -Destination (Join-Path $fixtureRoot $directory) -Recurse
        }
        Invoke-TpmControllerCommand -AppRoot $fixtureRoot -Command init *> $null
        # Argument generation only checks these paths; no executable is started.
        foreach ($name in @('winws2.exe', 'zapret-lib.lua', 'zapret-antidpi.lua')) {
            [IO.File]::WriteAllText((Join-Path $fixtureRoot "runtime/$name"), 'fixture')
        }
        [IO.File]::WriteAllText((Join-Path $fixtureRoot 'lists/user-ips.txt'), '203.0.113.8')
        $profiles = @(& $controller { param($Root) Get-TrafficProfiles $Root } $fixtureRoot)

        function Get-IsolatedWinwsArguments([bool]$DryRun, [string]$ProfileId = '') {
            & $controller {
                param($Root, $ValidateOnly, $Id)
                $script:AppRoot = $Root
                Build-WinwsArguments $ValidateOnly $Id
            } $fixtureRoot $DryRun $ProfileId
        }
    }

    It 'disables duplicate-instance checking only for parameter validation' {
        $arguments = @(Get-IsolatedWinwsArguments $true)
        $arguments | Should -Contain '--dry-run'
        $arguments | Should -Contain '--wf-dup-check=0'
        $arguments | Should -Not -Contain '--daemon'
        @($arguments | Where-Object { $_.StartsWith('--pidfile=') }).Count | Should -Be 0
    }

    It 'retains daemon and PID handling with default duplicate protection for normal launches' {
        $arguments = @(Get-IsolatedWinwsArguments $false)
        $arguments | Should -Contain '--daemon'
        $arguments | Should -Contain ("--pidfile=" + (Join-Path $fixtureRoot 'state\winws2.pid'))
        $arguments | Should -Not -Contain '--dry-run'
        @($arguments | Where-Object { $_.StartsWith('--wf-dup-check') }).Count | Should -Be 0
    }

    It 'validates the same capture filters, files and profile actions used by normal launches' {
        $profiles.Count | Should -BeGreaterThan 0
        foreach ($profile in $profiles) {
            $dryRunArguments = @(Get-IsolatedWinwsArguments $true $profile.Id)
            $normalArguments = @(Get-IsolatedWinwsArguments $false $profile.Id)
            @($normalArguments | Where-Object { $_ -match '^--wf-(tcp|udp)-(in|out)=|^--wf-raw-part=' }).Count | Should -BeGreaterThan 0
            @($normalArguments | Where-Object { $_.StartsWith('--lua-desync=') }).Count | Should -BeGreaterThan 0
            $dryRunContent = @($dryRunArguments | Where-Object { $_ -notin @('--dry-run', '--wf-dup-check=0') })
            $normalContent = @($normalArguments | Where-Object { $_ -ne '--daemon' -and -not $_.StartsWith('--pidfile=') })
            (ConvertTo-Json -InputObject $dryRunContent -Compress) | Should -BeExactly (ConvertTo-Json -InputObject $normalContent -Compress) -Because "profile '$($profile.Id)' must keep its real launch parameters during validation"
        }
    }
}
