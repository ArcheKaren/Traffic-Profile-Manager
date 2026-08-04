[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$serviceTool = Join-Path $projectRoot "tools\service-control.ps1"
$serviceName = "TrafficProfileService"
$taskName = "TrafficProfileMappingRefresh"
$serviceRoot = Join-Path $env:ProgramData "TrafficProfileManager\Service"
$serviceMarker = Join-Path $serviceRoot ".tpm-managed-service"
$serviceState = Join-Path $projectRoot "state\service-profile.txt"
$hostsPath = Join-Path $env:SystemRoot "System32\drivers\etc\hosts"
$hostsMarker = "# TrafficProfileManager Mapping BEGIN"
$profile = "strategy-wa-pc-pos1"
$testFailure = $null
$cleanupFailure = $null

Import-Module (
    Join-Path $projectRoot `
        "modules\TrafficProfileManager.Core\TrafficProfileManager.Core.psd1"
) -Force -ErrorAction Stop

function Assert-Condition([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Write-CiFailure([string]$Message) {
    if ($env:GITHUB_ACTIONS -ne "true") { return }
    $annotationMessage = $Message.Replace("`r", " ").Replace("`n", " ")
    Write-Host "::error title=Service lifecycle integration::$annotationMessage"
}

function Get-HostsHash {
    return (Get-FileHash -LiteralPath $hostsPath -Algorithm SHA256).Hash
}

function Test-HostsMarker {
    return [bool](Select-String `
        -LiteralPath $hostsPath `
        -SimpleMatch `
        -Pattern $hostsMarker `
        -Quiet `
        -ErrorAction SilentlyContinue)
}

function Wait-ServiceRemoval {
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    do {
        if (-not (Get-Service -Name $serviceName -ErrorAction SilentlyContinue)) {
            return
        }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
}

if (-not (Test-TpmIsAdministrator)) {
    throw "The service lifecycle integration test requires an elevated runner."
}

$preexistingArtifacts = @(
    Get-Service -Name $serviceName -ErrorAction SilentlyContinue
    Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    Get-Process -Name "winws2" -ErrorAction SilentlyContinue
    Get-Item -LiteralPath $serviceRoot -Force -ErrorAction SilentlyContinue
    Get-Item -LiteralPath $serviceState -Force -ErrorAction SilentlyContinue
)
if ($preexistingArtifacts.Count -gt 0 -or (Test-HostsMarker)) {
    throw (
        "Refusing to run because Traffic Profile Manager service artifacts " +
        "already exist on this runner."
    )
}

$originalHostsHash = Get-HostsHash

try {
    & $serviceTool install $profile

    $service = Get-Service -Name $serviceName -ErrorAction Stop
    $service.WaitForStatus("Running", [TimeSpan]::FromSeconds(15))
    Assert-Condition ($service.Status -eq "Running") `
        "The installed service did not reach the Running state."
    Assert-Condition (Test-Path -LiteralPath $serviceMarker -PathType Leaf) `
        "The protected deployment marker was not created."
    Assert-Condition (-not (Get-ScheduledTask `
        -TaskName $taskName `
        -ErrorAction SilentlyContinue)) `
        "The startup refresh task must be off after installation."

    $serviceAcl = Get-Acl -LiteralPath $serviceRoot
    Assert-Condition $serviceAcl.AreAccessRulesProtected `
        "The protected deployment still inherits filesystem permissions."
    $privilegedSids = @("S-1-5-18", "S-1-5-32-544")
    $usersSid = "S-1-5-32-545"
    $allowedSids = @($privilegedSids + $usersSid)
    $accessRules = @($serviceAcl.GetAccessRules(
        $true,
        $true,
        [Security.Principal.SecurityIdentifier]
    ))
    $unexpectedRule = @(
        $accessRules | Where-Object {
            $_.IdentityReference.Value -notin $allowedSids
        }
    ) | Select-Object -First 1
    Assert-Condition ($null -eq $unexpectedRule) `
        "The protected deployment grants access to an unexpected identity."
    $writeMask = (
        [Security.AccessControl.FileSystemRights]::WriteData -bor
        [Security.AccessControl.FileSystemRights]::AppendData -bor
        [Security.AccessControl.FileSystemRights]::WriteExtendedAttributes -bor
        [Security.AccessControl.FileSystemRights]::WriteAttributes -bor
        [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor
        [Security.AccessControl.FileSystemRights]::Delete -bor
        [Security.AccessControl.FileSystemRights]::ChangePermissions -bor
        [Security.AccessControl.FileSystemRights]::TakeOwnership
    )
    $unsafeUserRule = @(
        $accessRules | Where-Object {
            $_.IdentityReference.Value -eq $usersSid -and
            $_.AccessControlType -eq (
                [Security.AccessControl.AccessControlType]::Allow
            ) -and
            (([int64]$_.FileSystemRights -band [int64]$writeMask) -ne 0)
        }
    ) | Select-Object -First 1
    Assert-Condition ($null -eq $unsafeUserRule) `
        "The protected deployment grants write access to standard users."

    & $serviceTool task-on
    Assert-Condition ([bool](Get-ScheduledTask `
        -TaskName $taskName `
        -ErrorAction SilentlyContinue)) `
        "The startup refresh task was not created."

    & $serviceTool task-off
    Assert-Condition (-not (Get-ScheduledTask `
        -TaskName $taskName `
        -ErrorAction SilentlyContinue)) `
        "The startup refresh task was not removed."

    & $serviceTool stop
    $service = Get-Service -Name $serviceName -ErrorAction Stop
    $service.WaitForStatus("Stopped", [TimeSpan]::FromSeconds(15))
    Assert-Condition ($service.Status -eq "Stopped") `
        "The service did not reach the Stopped state."
    Assert-Condition (-not (Test-HostsMarker)) `
        "Managed hosts mappings remained after stopping the service."

    & $serviceTool start
    $service = Get-Service -Name $serviceName -ErrorAction Stop
    $service.WaitForStatus("Running", [TimeSpan]::FromSeconds(15))
    Assert-Condition ($service.Status -eq "Running") `
        "The service did not restart."
} catch {
    $testFailure = $_
    Write-CiFailure $_.Exception.ToString()
} finally {
    try {
        if (
            (Get-Service -Name $serviceName -ErrorAction SilentlyContinue) -or
            (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) -or
            (Test-Path -LiteralPath $serviceMarker -PathType Leaf)
        ) {
            & $serviceTool remove
        }
    } catch {
        $cleanupFailure = $_
    }
}

Wait-ServiceRemoval
$postconditionFailures = New-Object "Collections.Generic.List[string]"
if (Get-Service -Name $serviceName -ErrorAction SilentlyContinue) {
    $postconditionFailures.Add("The integration test left the service installed.")
}
if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
    $postconditionFailures.Add(
        "The integration test left the startup refresh task installed."
    )
}
if (Get-Process -Name "winws2" -ErrorAction SilentlyContinue) {
    $postconditionFailures.Add(
        "The integration test left a winws2 process running."
    )
}
if (Test-Path -LiteralPath $serviceRoot) {
    $postconditionFailures.Add(
        "The integration test left the protected deployment behind."
    )
}
if (Test-Path -LiteralPath $serviceState) {
    $postconditionFailures.Add(
        "The integration test left the service profile state behind."
    )
}
if (Test-HostsMarker) {
    $postconditionFailures.Add(
        "The integration test left managed hosts mappings behind."
    )
}
$finalHostsHash = Get-HostsHash
if ($finalHostsHash -ne $originalHostsHash) {
    $postconditionFailures.Add(
        "The original hosts file hash was $originalHostsHash; cleanup returned " +
        "$finalHostsHash."
    )
}
if ($cleanupFailure) {
    $postconditionFailures.Add(
        "Cleanup failed: $($cleanupFailure.Exception.ToString())"
    )
}
if ($postconditionFailures.Count -gt 0) {
    $postconditionMessage = $postconditionFailures -join " "
    Write-CiFailure $postconditionMessage
    throw $postconditionMessage
}
if ($testFailure) { throw $testFailure }

Write-Host "Service lifecycle integration test passed." -ForegroundColor Green
