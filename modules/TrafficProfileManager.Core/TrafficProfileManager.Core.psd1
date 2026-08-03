@{
    RootModule = "TrafficProfileManager.Core.psm1"
    ModuleVersion = "1.2.0"
    GUID = "06717eaa-b510-4a0c-bc98-2cb7545059d7"
    Author = "Traffic Profile Manager contributors"
    Description = "Shared normalization, privilege, and process-launch helpers."
    PowerShellVersion = "5.1"
    CompatiblePSEditions = @("Desktop", "Core")
    FunctionsToExport = @(
        "Get-TpmMeaningfulLines"
        "ConvertTo-TpmDomain"
        "ConvertTo-TpmIpNetwork"
        "Test-TpmIsAdministrator"
        "Test-TpmArgumentVector"
        "ConvertTo-TpmWindowsArgument"
        "New-TpmProcessStartInfo"
    )
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
}
