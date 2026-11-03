Describe 'Console status colours' {
    BeforeAll {
        $root=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        Import-Module (Join-Path $root 'modules\TrafficProfileManager.Console\TrafficProfileManager.Console.psd1') -Force
    }
    BeforeEach {
        Set-TpmUiRoot $TestDrive
        Mock Test-TpmTrueColor { $false } -ModuleName TrafficProfileManager.Console
        Mock 'Microsoft.PowerShell.Utility\Write-Host' {} -ModuleName TrafficProfileManager.Console
    }
    It 'marks success green and failures red' {
        Write-TpmStatus -Label State -Value Running -Tone Success
        Write-TpmStatus -Label State -Value Failed -Tone Error
        Should -Invoke 'Microsoft.PowerShell.Utility\Write-Host' -ModuleName TrafficProfileManager.Console -Times 1 -Exactly -ParameterFilter {
            $Object -like '*Running*' -and $ForegroundColor -eq [ConsoleColor]::Green
        }
        Should -Invoke 'Microsoft.PowerShell.Utility\Write-Host' -ModuleName TrafficProfileManager.Console -Times 1 -Exactly -ParameterFilter {
            $Object -like '*Failed*' -and $ForegroundColor -eq [ConsoleColor]::Red
        }
    }
    It 'uses a readable warning colour without escape sequences in a legacy console' {
        Write-TpmUi 'Check the configuration' -Tone Warning
        Should -Invoke 'Microsoft.PowerShell.Utility\Write-Host' -ModuleName TrafficProfileManager.Console -Times 1 -Exactly -ParameterFilter {
            $ForegroundColor -eq [ConsoleColor]::DarkYellow -and $Object -notmatch ([string][char]27)
        }
    }
    It 'uses orange when the terminal supports true colour' {
        Mock Test-TpmTrueColor { $true } -ModuleName TrafficProfileManager.Console
        Write-TpmUi 'Check the configuration' -Tone Warning
        Should -Invoke 'Microsoft.PowerShell.Utility\Write-Host' -ModuleName TrafficProfileManager.Console -Times 1 -Exactly -ParameterFilter {
            $Object.Contains(([string][char]27) + '[38;2;255;165;0m') -and $Object.EndsWith(([string][char]27) + '[0m')
        }
    }
    It 'keeps existing explicit colours available' {
        Write-TpmUi 'Existing message' -ForegroundColor Cyan
        Should -Invoke 'Microsoft.PowerShell.Utility\Write-Host' -ModuleName TrafficProfileManager.Console -Times 1 -Exactly -ParameterFilter {
            $ForegroundColor -eq [ConsoleColor]::Cyan -and $Object -eq 'Existing message'
        }
    }
    It 'shows a terminal profile state without a running label or a stop shortcut' -TestCases @(
        @{State='Stopped';Color=[ConsoleColor]::DarkGray},
        @{State='Failed';Color=[ConsoleColor]::Red}
    ) {
        param($State,$Color)
        Show-TpmProfileSession -ProfileId fixture -State $State
        Should -Invoke 'Microsoft.PowerShell.Utility\Write-Host' -ModuleName TrafficProfileManager.Console -Times 1 -Exactly -ParameterFilter {
            $Object -like "*State: $State" -and $ForegroundColor -eq $Color
        }
        Should -Invoke 'Microsoft.PowerShell.Utility\Write-Host' -ModuleName TrafficProfileManager.Console -Times 0 -Exactly -ParameterFilter {
            $Object -like '*State: Running*' -or $Object -like '*Ctrl+C*'
        }
    }
}
