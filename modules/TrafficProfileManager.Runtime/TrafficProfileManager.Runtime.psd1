@{
    RootModule = "TrafficProfileManager.Runtime.psm1"
    ModuleVersion = "1.2.1"
    GUID = "a3fce97d-8eb8-4111-bc55-e2dfc85cc225"
    Author = "Traffic Profile Manager contributors"
    Description = "Shared runtime provenance validation for source files and archives."
    PowerShellVersion = "5.1"
    CompatiblePSEditions = @("Desktop", "Core")
    FunctionsToExport = @(
        "Get-TpmRuntimeManifest"
        "Resolve-TpmRuntimePath"
        "Assert-TpmRuntimeContent"
        "Get-TpmVerifiedRuntimeFile"
    )
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
}
