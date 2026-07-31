param(
    [Parameter(Mandatory = $true)]
    [int]$ControllerPid,

    [Parameter(Mandatory = $true)]
    [int64]$ControllerStartTicks,

    [Parameter(Mandatory = $true)]
    [int]$WinwsPid,

    [Parameter(Mandatory = $true)]
    [int64]$WinwsStartTicks,

    [Parameter(Mandatory = $true)]
    [string]$WinwsPath,

    [string]$ReadyPath = "",

    [switch]$CleanupMappings
)

$ErrorActionPreference = "SilentlyContinue"
$appRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$started = [DateTime]::UtcNow
$nextRefresh = [DateTime]::UtcNow

function Get-MatchingProcess(
    [int]$ProcessId,
    [int64]$StartTicks,
    [string]$ExpectedPath = ""
) {
    $process = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if (-not $process) { return $null }
    try {
        if ($process.StartTime.ToUniversalTime().Ticks -ne $StartTicks) {
            return $null
        }
        if (
            $ExpectedPath -and
            [IO.Path]::GetFullPath($process.Path) -ine
                [IO.Path]::GetFullPath($ExpectedPath)
        ) {
            return $null
        }
        return $process
    } catch {
        return $null
    }
}

while (
    (Get-MatchingProcess $ControllerPid $ControllerStartTicks) -and
    (Get-MatchingProcess $WinwsPid $WinwsStartTicks $WinwsPath)
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
    -not (Get-MatchingProcess $ControllerPid $ControllerStartTicks) -and
    (Get-MatchingProcess $WinwsPid $WinwsStartTicks $WinwsPath)
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
$identityPath = Join-Path $appRoot "state\winws2.identity.json"
if (Test-Path -LiteralPath $identityPath -PathType Leaf) {
    try {
        $identity = Get-Content -Raw -LiteralPath $identityPath |
            ConvertFrom-Json
        if (
            [int]$identity.pid -eq $WinwsPid -and
            [int64]$identity.startTimeUtcTicks -eq $WinwsStartTicks
        ) {
            Remove-Item `
                -LiteralPath $identityPath `
                -Force `
                -ErrorAction SilentlyContinue
        }
    } catch {}
}
if ($ReadyPath -and (Test-Path -LiteralPath $ReadyPath)) {
    Remove-Item -LiteralPath $ReadyPath -Force -ErrorAction SilentlyContinue
}
