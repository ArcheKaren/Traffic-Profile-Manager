@{
    RootModule = 'TrafficProfileManager.Maintenance.psm1'
    ModuleVersion = '1.3.0'
    GUID = 'fa376aff-0876-4fae-b52e-d42a17be5041'
    PowerShellVersion = '5.1'
    FunctionsToExport = @('Resolve-TpmArchivePath','Get-TpmOverview','Get-TpmAdvice','New-TpmUserBackup','Get-TpmRestorePlan','Restore-TpmUserBackup','Get-TpmUpdatePlan','Install-TpmUpdate','Undo-TpmTransaction','Get-TpmLatestRelease','Save-TpmLatestRelease','Get-TpmComparisonResults','Set-TpmComparisonProfile','Get-TpmSetups','Save-TpmSetup','Initialize-TpmSetups','Get-TpmSetupPath','Get-TpmSetupPlan','Use-TpmSetup','New-TpmConfigurationSnapshot','Save-TpmAppliedConfiguration','Compare-TpmConfigurationSnapshots','Get-TpmConfigurationStatus','New-TpmBuiltProfile','Save-TpmBuiltProfile')
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
}
