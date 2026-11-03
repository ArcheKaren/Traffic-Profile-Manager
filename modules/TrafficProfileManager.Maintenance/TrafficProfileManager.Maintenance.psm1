$moduleRoot = Split-Path -Parent $PSScriptRoot
foreach ($name in @('Core','Runtime','Profile','Console')) {
    Import-Module (Join-Path $moduleRoot "TrafficProfileManager.$name\TrafficProfileManager.$name.psd1") -ErrorAction Stop
}
Add-Type -AssemblyName System.IO.Compression.FileSystem
. (Join-Path $PSScriptRoot 'Files.ps1')
. (Join-Path $PSScriptRoot 'Backup.ps1')
. (Join-Path $PSScriptRoot 'Update.ps1')
. (Join-Path $PSScriptRoot 'Overview.ps1')
Export-ModuleMember -Function @('Resolve-TpmArchivePath','Get-TpmOverview','Get-TpmAdvice','New-TpmUserBackup','Get-TpmRestorePlan','Restore-TpmUserBackup','Get-TpmUpdatePlan','Install-TpmUpdate','Undo-TpmTransaction','Get-TpmLatestRelease','Save-TpmLatestRelease','Get-TpmComparisonResults','Set-TpmComparisonProfile')
