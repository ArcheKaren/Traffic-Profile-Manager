. (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'tools/benchmark-library.ps1')
function Get-TpmOverview {
    param([string]$AppRoot, [string]$HostsPath = '')
    $configPath = Resolve-MaintenancePath $AppRoot 'config/config.json'
    $config = $null
    $profile = $null
    $configError = $null
    try { $config = [IO.File]::ReadAllText($configPath) | ConvertFrom-Json; $profile = $config.activeProfile } catch { $configError = $_.Exception.Message }
    $valid = $false
    try { $valid = [bool]@(Get-TrafficProfiles $AppRoot -IncludeInvalid | Where-Object { $_.Id -eq $profile -and $_.Valid }).Count } catch {}
    $service = Get-Service -Name 'TrafficProfileService' -ErrorAction SilentlyContinue
    $serviceRoot = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'TrafficProfileManager\Service'
    $serviceProfile = $null
    try { $serviceProfile = ([IO.File]::ReadAllText((Join-Path $serviceRoot 'config\config.json')) | ConvertFrom-Json).activeProfile } catch {}
    $processes = @(Get-Process -Name 'winws2' -ErrorAction SilentlyContinue)
    $mode = if ($service -and $service.Status -eq 'Running') { 'service' } elseif ($processes.Count) { 'process' } else { 'stopped' }
    try {
        $identity = [IO.File]::ReadAllText((Join-Path $AppRoot 'state\winws2.identity.json')) | ConvertFrom-Json
        $owned = Get-Process -Id $identity.pid -ErrorAction Stop
        if ($mode -ne 'service' -and $owned.Path -ieq $identity.executable -and $owned.StartTime.ToUniversalTime().Ticks -eq $identity.startTimeUtcTicks) {
            $mode = if (Test-Path -LiteralPath (Join-Path $AppRoot "state\mapping-ready-$($owned.Id).flag")) { 'foreground' } else { 'background' }
        }
    } catch {}
    $bundledExecutable = $null
    $runtimeState = 'missing'
    try {
        $portable = (Test-Path -LiteralPath (Join-Path $AppRoot 'metadata/release-manifest.json') -PathType Leaf) -or
            (Test-Path -LiteralPath (Join-Path $AppRoot '.tpm-release-manifest.json') -PathType Leaf)
        $layout = if ($portable) { 'Portable' } else { 'Source' }
        $runtimeRoot = Join-Path $AppRoot 'runtime'
        if ($portable) { $bundledExecutable = Resolve-TpmRuntimePath $runtimeRoot 'winws2.exe' }
        $manifest = Get-TpmRuntimeManifest (Join-Path $runtimeRoot 'SOURCE.json')
        $executablePath = if ($portable) { $manifest.runtimeFiles.winws2.releasePath } else { $manifest.runtimeFiles.winws2.path }
        $bundledExecutable = Resolve-TpmRuntimePath $runtimeRoot $executablePath
        foreach ($key in @('winws2','winDivertDll','winDivertDriver','cygwin','luaLib','luaAntidpi')) {
            [void](Get-TpmVerifiedRuntimeFile -RuntimeRoot (Join-Path $AppRoot 'runtime') -Entry $manifest.runtimeFiles.$key -Layout $layout)
        }
        $runtimeState = 'verified'
    } catch { $runtimeState = 'missing-or-invalid' }
    try {
        if ($config.runtimePath) {
            $external = if ([IO.Path]::IsPathRooted($config.runtimePath)) { $config.runtimePath } else { Join-Path $AppRoot $config.runtimePath }
            $external = [IO.Path]::GetFullPath($external)
            if (-not $bundledExecutable -or $external -ine $bundledExecutable) {
                $runtimeState = if (Test-Path -LiteralPath $external -PathType Leaf) { 'external-unverified' } else { 'missing-or-invalid' }
            }
        }
    } catch { $runtimeState = 'missing-or-invalid' }
    if (-not $HostsPath) { $HostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts' }
    $mappings = 'unavailable'
    try {
        $lines = [IO.File]::ReadAllLines($HostsPath)
        $begin = @($lines | Where-Object { $_ -eq '# TrafficProfileManager Mapping BEGIN' }).Count
        $end = @($lines | Where-Object { $_ -eq '# TrafficProfileManager Mapping END' }).Count
        $depth = 0
        $broken = $false
        foreach ($line in $lines) {
            if ($line -eq '# TrafficProfileManager Mapping BEGIN') { $depth++; if ($depth -ne 1) { $broken=$true } }
            if ($line -eq '# TrafficProfileManager Mapping END') { $depth--; if ($depth -ne 0) { $broken=$true } }
        }
        $mappings = if ($broken -or $depth -ne 0 -or $begin -ne $end) { 'incomplete' } elseif ($begin) { 'active' } else { 'clean' }
    } catch {}
    $build = Get-TpmBuildInfo $AppRoot
    $serviceBuild = if ($service) { Get-TpmBuildInfo $serviceRoot } else { $null }
    $staleService = $false
    if ($service -and $serviceBuild.version -ne 'unknown') {
        $staleService = $serviceBuild.version -ne $build.version -or ($serviceBuild.contentSha256 -and $build.contentSha256 -and $serviceBuild.contentSha256 -ne $build.contentSha256)
    }
    [pscustomobject]@{
        schemaVersion=1; configuredProfile=$profile; profileValid=$valid; configError=$configError
        mode=$mode; runtime=$runtimeState; runtimeProcesses=$processes.Count; mappings=$mappings
        serviceInstalled=[bool]$service; serviceState=$(if ($service) { [string]$service.Status } else { 'absent' })
        serviceProfile=$serviceProfile; serviceStale=$staleService; build=$build
    }
}

function Get-TpmAdvice($Overview) {
    if (-not $Overview.profileValid) {
        [pscustomobject]@{ code='profile-invalid'; action='Check profile files in Manager, then select a valid profile.' }
    }
    if ($Overview.runtime -notin @('verified','external-unverified')) {
        [pscustomobject]@{ code='runtime-invalid'; action='Restore the verified runtime or set an explicit runtime path.' }
    }
    if ($Overview.mappings -eq 'incomplete') {
        [pscustomobject]@{ code='hosts-incomplete'; action='Inspect the incomplete hosts block manually; automatic cleanup will not change it.' }
    } elseif ($Overview.mappings -eq 'active' -and $Overview.mode -eq 'stopped') {
        [pscustomobject]@{ code='hosts-stale'; action='Stop the profile, then clean temporary mappings in Background controls.' }
    }
    if ($Overview.serviceStale) {
        [pscustomobject]@{ code='service-stale'; action='Remove and reinstall the service to refresh its protected copy.' }
    }
}

function Get-TpmComparisonResults([string]$AppRoot) {
    $root = Resolve-MaintenancePath $AppRoot 'test-results'
    if (-not (Test-Path -LiteralPath $root)) { return }
    foreach ($file in Get-ChildItem -LiteralPath $root -Filter 'profile-comparison-*.csv' -File | Sort-Object LastWriteTimeUtc -Descending) {
        $rows = @(Import-Csv -LiteralPath $file.FullName)
        if (-not $rows.Count -or 'ProfileId' -notin $rows[0].PSObject.Properties.Name -or 'Success' -notin $rows[0].PSObject.Properties.Name) { continue }
        $ranking = @(
            foreach ($item in @(Get-TpmBenchmarkRanking $rows)) {
                if ($item.ProfileId -notmatch '^[a-z0-9][a-z0-9_-]{0,63}$') { continue }
                [pscustomobject]@{profileId=$item.ProfileId;profile=$item.Profile;passed=$item.Passed;total=$item.Total;score=$item.Score;stable=$item.Stable;repeatedTargets=$item.RepeatedTargets}
            }
        )
        $createdAt = $file.LastWriteTimeUtc.ToString('o')
        $metadataPath = [IO.Path]::ChangeExtension($file.FullName, '.json')
        try {
            if (Test-Path -LiteralPath $metadataPath) {
                $metadata = [IO.File]::ReadAllText($metadataPath) | ConvertFrom-Json
                if ($metadata.schemaVersion -in @(1,2)) { $createdAt = [DateTimeOffset]::Parse($metadata.generatedAt).ToString('o') }
            }
        } catch {}
        [pscustomobject]@{ file=$file.Name; createdAt=$createdAt; ranking=$ranking }
    }
}

function Set-TpmComparisonProfile([string]$AppRoot, [string]$ProfileId) {
    if (-not @(Get-TrafficProfiles $AppRoot | Where-Object Id -eq $ProfileId).Count) { throw 'The selected profile is missing or invalid.' }
    $configPath = Resolve-MaintenancePath $AppRoot 'config/config.json'
    $config = [IO.File]::ReadAllText($configPath) | ConvertFrom-Json
    $config.activeProfile = $ProfileId
    Write-MaintenanceJson $configPath $config
}
