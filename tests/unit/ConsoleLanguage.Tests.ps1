Describe 'Console translation compatibility' {
    BeforeAll {
        $projectRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        Import-Module (Join-Path $projectRoot 'modules/TrafficProfileManager.Console/TrafficProfileManager.Console.psd1') -Force
        $dictionary=[IO.File]::ReadAllText((Join-Path $projectRoot 'modules/TrafficProfileManager.Console/ru.json'))|ConvertFrom-Json
        function Write-LanguageFixture([string]$Root,[string]$Language) {
            New-Item -ItemType Directory -Path (Join-Path $Root 'state') -Force|Out-Null
            [IO.File]::WriteAllText((Join-Path $Root 'state/user-settings.json'),('{"language":"'+$Language+'"}'))
        }
    }
    BeforeEach {
        $root=Join-Path $TestDrive ([Guid]::NewGuid().ToString('N')+" language user's path")
        Write-LanguageFixture $root 'ru'
        Set-TpmUiRoot $root
    }
    It 'keeps exact keys, dynamic values and indentation translated' {
        Get-TpmText 'Show status'|Should -Be $dictionary.'Show status'
        $value="C:\path\user's {0}.json"
        Get-TpmText ("  Created: "+$value)|Should -Be ('  '+($dictionary.'Created: {0}' -f $value))
        Get-TpmText 'Transport: {0}, {1}' -Values @('TCP+UDP','preset')|Should -Be ($dictionary.'Transport: {0}, {1}' -f 'TCP+UDP','preset')
        Get-TpmText 'Untranslated runtime output'|Should -Be 'Untranslated runtime output'
    }
    It 'notices an external language change even when the file length stays the same' {
        $path=Join-Path $root 'state/user-settings.json'
        Get-TpmLanguage|Should -Be 'ru'
        $stamp=[IO.File]::GetLastWriteTimeUtc($path)
        Write-LanguageFixture $root 'en'
        [IO.File]::SetLastWriteTimeUtc($path,$stamp.AddSeconds(2))
        Get-TpmLanguage|Should -Be 'en'
        Get-TpmText 'Show status'|Should -Be 'Show status'
    }
    It 'falls back to English after a preference file is removed' {
        Get-TpmLanguage|Should -Be 'ru'
        Remove-Item -LiteralPath (Join-Path $root 'state/user-settings.json')
        Get-TpmLanguage|Should -Be 'en'
    }
    It 'does not reuse the preference from another application root' {
        Get-TpmLanguage|Should -Be 'ru'
        $other=Join-Path $TestDrive 'second root'
        Write-LanguageFixture $other 'en'
        Set-TpmUiRoot $other
        Get-TpmLanguage|Should -Be 'en'
        Set-TpmUiRoot $root
        Get-TpmLanguage|Should -Be 'ru'
    }
    It 'keeps corrupt settings untouched and notices when they are repaired' {
        $path=Join-Path $root 'state/user-settings.json'
        Get-TpmLanguage|Should -Be 'ru'
        [IO.File]::WriteAllText($path,'{ invalid')
        Get-TpmLanguage|Should -Be 'en'
        [IO.File]::ReadAllText($path)|Should -Be '{ invalid'
        Write-LanguageFixture $root 'ru'
        Get-TpmLanguage|Should -Be 'ru'
    }
}
