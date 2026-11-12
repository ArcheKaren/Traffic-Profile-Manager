[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$projectRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $projectRoot 'modules/TrafficProfileManager.Maintenance/TrafficProfileManager.Maintenance.psd1') -Force
& (Get-Module TrafficProfileManager.Maintenance) {
    param($SourceRoot)
    $stage=New-TpmDataStage $SourceRoot
    try {
        $recipe=[pscustomobject]@{schemaVersion=1;id='validation-composite';displayName='Validation composite';baseProfile='strategy-wa-pc-pos1';httpProfile='strategy-full-autottl';tlsProfile='strategy-variant-split1';quicProfile='strategy-variant-quic'}
        $profile=New-TpmBuiltProfile $SourceRoot $recipe
        Write-MaintenanceJson (Join-Path $stage 'config/profiles/validation-composite.json') $profile
        Invoke-TpmCandidateCheck $SourceRoot $stage $profile.name
        Write-Host 'Native constructor dry-run: PASS'
    } finally {
        $resolved=[IO.Path]::GetFullPath($stage)
        $allowed=[IO.Path]::GetFullPath((Join-Path $SourceRoot 'state')).TrimEnd('\')+'\'
        if(-not $resolved.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)){throw 'Unexpected candidate path.'}
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
} $projectRoot
