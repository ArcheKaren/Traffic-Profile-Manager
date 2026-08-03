@{
    RootModule = "TrafficProfileManager.Profile.psm1"
    ModuleVersion = "1.2.0"
    GUID = "b691dfa4-4c84-45c7-b01c-d3c267e073a4"
    Author = "Traffic Profile Manager contributors"
    Description = "Public profile discovery, schema validation, and semantic validation API."
    PowerShellVersion = "5.1"
    CompatiblePSEditions = @("Desktop", "Core")
    FunctionsToExport = @(
        "Resolve-TrafficProfileDefinition"
        "Test-TrafficProfileDefinition"
        "Get-TrafficProfiles"
    )
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
}
