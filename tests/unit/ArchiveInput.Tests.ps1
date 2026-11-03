Describe 'Archive path input' {
    BeforeAll {
        $projectRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        Import-Module (Join-Path $projectRoot 'modules\TrafficProfileManager.Maintenance\TrafficProfileManager.Maintenance.psd1') -Force
    }
    BeforeEach {
        $root=Join-Path $TestDrive ([Guid]::NewGuid().ToString('N')+" user's path")
        New-Item -ItemType Directory -Path (Join-Path $root 'config') -Force|Out-Null
        [IO.File]::WriteAllText((Join-Path $root 'config/config.json'),'{"activeProfile":"custom"}')
        Mock Get-Service {} -ModuleName TrafficProfileManager.Maintenance
        Mock Get-Process {} -ModuleName TrafficProfileManager.Maintenance
    }
    It 'reports empty input without a raw GetFullPath exception' -TestCases @(@{Path=''},@{Path='   '}) {
        param($Path)
        {Get-TpmRestorePlan $root $Path}|Should -Throw '*Specify the path to an existing archive file*'
    }
    It 'accepts quoted paths with spaces and apostrophes' {
        $backup=New-TpmUserBackup $root
        (Resolve-TpmArchivePath ('"'+$backup.archive+'"'))|Should -Be $backup.archive
        (Resolve-TpmArchivePath ("'"+$backup.archive+"'"))|Should -Be $backup.archive
        @(Get-TpmRestorePlan $root ('"'+$backup.archive+'"')).path|Should -Contain 'config/config.json'
    }
    It 'restores from a quoted archive path' {
        $backup=New-TpmUserBackup $root
        [IO.File]::WriteAllText((Join-Path $root 'config/config.json'),'{"activeProfile":"changed"}')
        $transaction=Restore-TpmUserBackup $root ('"'+$backup.archive+'"')
        $transaction.purpose|Should -Be 'restore'
        ([IO.File]::ReadAllText((Join-Path $root 'config/config.json'))|ConvertFrom-Json).activeProfile|Should -Be 'custom'
    }
    It 'distinguishes folders, missing files and invalid paths' {
        {Resolve-TpmArchivePath $root}|Should -Throw '*not a folder*'
        {Resolve-TpmArchivePath (Join-Path $root 'missing.zip')}|Should -Throw '*Archive file was not found*'
        {Resolve-TpmArchivePath ('D:\invalid'+[char]0+'.zip')}|Should -Throw '*archive path is invalid*'
    }
    It 'explains when the selected file is not a ZIP archive' {
        $path=Join-Path $root 'invalid.zip'
        [IO.File]::WriteAllText($path,'not a zip')
        {Get-TpmRestorePlan $root $path}|Should -Throw '*Choose a valid backup or update ZIP*'
    }
}
