[CmdletBinding()]
param(
    [ValidateSet('overview','advice','language','backup','update','results')][string]$Action = 'overview',
    [string[]]$Arguments = @(),
    [string]$RootPath = '',
    [switch]$Json
)
$ErrorActionPreference = 'Stop'
$appRoot = if ($RootPath) { [IO.Path]::GetFullPath($RootPath) } else { Split-Path -Parent $PSScriptRoot }
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'modules\TrafficProfileManager.Maintenance\TrafficProfileManager.Maintenance.psd1') -ErrorAction Stop
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'modules\TrafficProfileManager.Console\TrafficProfileManager.Console.psd1') -ErrorAction Stop
Set-TpmUiRoot $appRoot
$values = @($Arguments | Where-Object { $_ -ne '--json' })
if ($Arguments -contains '--json') { $Json = $true }
$verb = if ($values.Count) { $values[0] } else { 'list' }
$result = switch ($Action) {
    'language' {
        if ($values.Count -gt 1) { throw 'Usage: language [en|ru]' }
        if ($values.Count) { Set-TpmLanguage -Language $values[0] -AppRoot $appRoot }
        [pscustomobject]@{ language=(Get-TpmLanguage $appRoot) }
    }
    'overview' { Get-TpmOverview $appRoot }
    'advice' { Get-TpmAdvice (Get-TpmOverview $appRoot) }
    'backup' {
        switch ($verb) {
            'create' { New-TpmUserBackup -AppRoot $appRoot -OutputPath $(if ($values.Count -gt 1) { $values[1] } else { '' }) }
            'preview' { if ($values.Count -ne 2) { throw 'Usage: backup preview <archive>' }; Get-TpmRestorePlan $appRoot $values[1] }
            'restore' {
                if ($values.Count -ne 3 -or $values[2] -ne '--apply') { throw 'Usage: backup restore <archive> --apply; preview the backup first.' }
                Restore-TpmUserBackup $appRoot $values[1]
            }
            default { throw 'Usage: backup create [archive] | preview <archive> | restore <archive> --apply' }
        }
    }
    'update' {
        switch ($verb) {
            'check' { Get-TpmLatestRelease }
            'download' { Save-TpmLatestRelease $appRoot }
            'preview' { if ($values.Count -ne 3) { throw 'Usage: update preview <archive> <sha256>' }; Get-TpmUpdatePlan $appRoot $values[1] $values[2] }
            'apply' { if ($values.Count -ne 3) { throw 'Usage: update apply <archive> <sha256>' }; Install-TpmUpdate $appRoot $values[1] $values[2] }
            'rollback' { if ($values.Count -ne 2) { throw 'Usage: update rollback <transaction-id>' }; Undo-TpmTransaction $appRoot $values[1] }
            default { throw 'Usage: update check | download | preview <archive> <sha256> | apply <archive> <sha256> | rollback <id>' }
        }
    }
    'results' {
        if ($verb -eq 'list') { Get-TpmComparisonResults $appRoot }
        elseif ($verb -eq 'use' -and $values.Count -eq 2) {
            $results = @(Get-TpmComparisonResults $appRoot)
            if ($values[1] -notin @($results | ForEach-Object { $_.ranking.profileId })) { throw 'This profile is not in the saved comparison results.' }
            Set-TpmComparisonProfile $appRoot $values[1]
            [pscustomobject]@{ selectedProfile=$values[1]; restartRequired=$true }
        } else { throw 'Usage: results list | use <profile-id>' }
    }
}
if ($Json) { ConvertTo-Json -InputObject @($result) -Depth 12; return }
if ($Action -eq 'overview') {
    Write-TpmStatus 'Configured profile' ([string]$result.configuredProfile) $(if ($result.profileValid) { 'Success' } else { 'Error' })
    Write-TpmStatus 'Service profile' $(if ($result.serviceProfile) { $result.serviceProfile } else { 'none' }) $(if ($result.serviceInstalled) { 'Info' } else { 'Muted' })
    Write-TpmStatus 'Mode' $result.mode $(if ($result.mode -eq 'stopped') { 'Muted' } else { 'Success' })
    $runtimeTone = if ($result.runtime -eq 'verified') { 'Success' } elseif ($result.runtime -eq 'external-unverified') { 'Warning' } else { 'Error' }
    Write-TpmStatus 'Runtime' $result.runtime $runtimeTone
    $mappingTone = if ($result.mappings -eq 'incomplete') { 'Error' } elseif ($result.mappings -eq 'unavailable' -or ($result.mappings -eq 'active' -and $result.mode -eq 'stopped')) { 'Warning' } else { 'Success' }
    Write-TpmStatus 'Temporary mappings' $result.mappings $mappingTone
    return
}
if ($Action -eq 'advice') {
    Write-TpmUi 'Local diagnostics' -Tone Title
    if (-not @($result).Count) { Write-TpmUi 'No local problems found.' -Tone Success }
    foreach ($item in $result) { Write-TpmUi ('[' + $item.code + '] ' + (Get-TpmText $item.action)) -Tone $(if ($item.code -in @('profile-invalid','runtime-invalid','hosts-incomplete')) { 'Error' } else { 'Warning' }) }
    return
}
$result
