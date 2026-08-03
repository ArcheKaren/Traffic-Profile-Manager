@{
    RootModule = "TrafficProfileManager.Operations.psm1"
    ModuleVersion = "1.2.0"
    GUID = "795d4fd3-73bd-45ee-acbc-9e55f8d0c218"
    Author = "Traffic Profile Manager contributors"
    Description = "Append-only local JSONL journal for privileged operations."
    PowerShellVersion = "5.1"
    CompatiblePSEditions = @("Desktop", "Core")
    FunctionsToExport = @("Write-TpmOperationLog")
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
}
