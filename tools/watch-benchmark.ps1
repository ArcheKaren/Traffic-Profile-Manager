param(
    [Parameter(Mandatory = $true)]
    [int]$ControllerPid,

    [Parameter(Mandatory = $true)]
    [int64]$ControllerStartTicks
)

$ErrorActionPreference = "SilentlyContinue"
$appRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)

while ($true) {
    $controller = Get-Process -Id $ControllerPid -ErrorAction SilentlyContinue
    if (-not $controller) { break }
    try {
        if (
            $controller.StartTime.ToUniversalTime().Ticks -ne
                $ControllerStartTicks
        ) {
            break
        }
    } catch {
        break
    }
    Start-Sleep -Milliseconds 250
}

& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File `
    (Join-Path $appRoot "zapretctl.ps1") stop *> $null
& (Join-Path $appRoot "manage-network-mappings.ps1") cleanup *> $null

$benchmarkList = Join-Path $appRoot "state\benchmark-domains.txt"
if (Test-Path -LiteralPath $benchmarkList) {
    Remove-Item -LiteralPath $benchmarkList -Force
}
