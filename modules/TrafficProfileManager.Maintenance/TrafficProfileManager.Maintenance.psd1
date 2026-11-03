@{
    RootModule = 'TrafficProfileManager.Maintenance.psm1'
    ModuleVersion = '1.2.1'
    GUID = 'fa376aff-0876-4fae-b52e-d42a17be5041'
    PowerShellVersion = '5.1'
    FunctionsToExport = @('Resolve-TpmArchivePath','Get-TpmOverview','Get-TpmAdvice','New-TpmUserBackup','Get-TpmRestorePlan','Restore-TpmUserBackup','Get-TpmUpdatePlan','Install-TpmUpdate','Undo-TpmTransaction','Get-TpmLatestRelease','Save-TpmLatestRelease','Get-TpmComparisonResults','Set-TpmComparisonProfile')
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
}
