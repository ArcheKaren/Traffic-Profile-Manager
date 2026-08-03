. (Join-Path `
    (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) `
    "tools\profile-library.ps1")

Export-ModuleMember -Function @(
    "Resolve-TrafficProfileDefinition"
    "Test-TrafficProfileDefinition"
    "Get-TrafficProfiles"
)
