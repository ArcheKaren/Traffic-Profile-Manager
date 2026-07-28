param(
    [Parameter(Mandatory = $true)]
    [int]$ControllerPid,

    [Parameter(Mandatory = $true)]
    [int]$WinwsPid,

    [string]$ReadyPath = "",

    [switch]$CleanupMappings
)

$ErrorActionPreference = "SilentlyContinue"
$appRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$started = [DateTime]::UtcNow
$nextRefresh = [DateTime]::UtcNow

while (
    (Get-Process -Id $ControllerPid -ErrorAction SilentlyContinue) -and
    (Get-Process -Id $WinwsPid -ErrorAction SilentlyContinue)
) {
    $mappingReady = -not $ReadyPath -or
        (Test-Path -LiteralPath $ReadyPath -PathType Leaf)
    if (
        $CleanupMappings -and
        $mappingReady -and
        [DateTime]::UtcNow -ge $nextRefresh
    ) {
        & (Join-Path $appRoot "manage-network-mappings.ps1") refresh *> $null
        $elapsed = ([DateTime]::UtcNow - $started).TotalSeconds
        $nextRefresh = [DateTime]::UtcNow.AddSeconds(
            $(if ($elapsed -lt 30) { 3 } else { 30 })
        )
    }
    Start-Sleep -Milliseconds 250
}

if (
    -not (Get-Process -Id $ControllerPid -ErrorAction SilentlyContinue) -and
    (Get-Process -Id $WinwsPid -ErrorAction SilentlyContinue)
) {
    Stop-Process -Id $WinwsPid -Force -ErrorAction SilentlyContinue
}

if ($CleanupMappings) {
    & (Join-Path $appRoot "manage-network-mappings.ps1") cleanup
}
$windowsPidPath = Join-Path $appRoot "state\winws2.windows.pid"
if (Test-Path -LiteralPath $windowsPidPath -PathType Leaf) {
    $storedPid = 0
    if (
        [int]::TryParse(
            (Get-Content -Raw -LiteralPath $windowsPidPath).Trim(),
            [ref]$storedPid
        ) -and
        $storedPid -eq $WinwsPid
    ) {
        Remove-Item `
            -LiteralPath $windowsPidPath `
            -Force `
            -ErrorAction SilentlyContinue
    }
}
if ($ReadyPath -and (Test-Path -LiteralPath $ReadyPath)) {
    Remove-Item -LiteralPath $ReadyPath -Force -ErrorAction SilentlyContinue
}
