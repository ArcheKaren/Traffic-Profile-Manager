param(
    [string]$ServiceName = "TrafficProfileService",

    [int]$InitialDelaySeconds = 30,

    [int]$RefreshSeconds = 300
)

$ErrorActionPreference = "SilentlyContinue"
$appRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$mappingTool = Join-Path $appRoot "manage-network-mappings.ps1"

if ($InitialDelaySeconds -gt 0) {
    Start-Sleep -Seconds $InitialDelaySeconds
}

while ($true) {
    $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if (-not $service) { break }

    if ($service.Status -eq "Running") {
        & $mappingTool refresh *> $null
        $delay = [Math]::Max(30, $RefreshSeconds)
    } else {
        $delay = 10
    }

    $deadline = [DateTime]::UtcNow.AddSeconds($delay)
    do {
        Start-Sleep -Seconds 5
        if (-not (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue)) {
            return
        }
    } while ([DateTime]::UtcNow -lt $deadline)
}
