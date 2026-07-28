param(
    [Parameter(Mandatory = $true)]
    [int]$ControllerPid
)

$ErrorActionPreference = "SilentlyContinue"
$appRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)

while (Get-Process -Id $ControllerPid -ErrorAction SilentlyContinue) {
    Start-Sleep -Milliseconds 250
}

& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File `
    (Join-Path $appRoot "zapretctl.ps1") stop *> $null
& (Join-Path $appRoot "manage-network-mappings.ps1") cleanup *> $null

$benchmarkList = Join-Path $appRoot "state\benchmark-domains.txt"
if (Test-Path -LiteralPath $benchmarkList) {
    Remove-Item -LiteralPath $benchmarkList -Force
}
