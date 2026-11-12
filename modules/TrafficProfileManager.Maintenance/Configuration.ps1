function New-TpmConfigurationSnapshot {
    param([string]$AppRoot, [string]$ProfileId = '')
    $config = [IO.File]::ReadAllText((Resolve-MaintenancePath $AppRoot 'config/config.json')) | ConvertFrom-Json
    if (-not $ProfileId) { $ProfileId = [string]$config.activeProfile }
    if ($ProfileId -notmatch '^[A-Za-z0-9_-]{1,64}$') { throw 'Invalid profile in configuration.' }
    $values = [ordered]@{ profile=$ProfileId; autoHostlist=[bool]$config.autoHostlist; debug=[bool]$config.debug; allowAllWithoutTargets=[bool]$config.allowAllWithoutTargets }
    $paths = @("config/profiles/$ProfileId.json",'config/rule-groups.json','lists/domains.txt','lists/domains-exclude.txt','lists/ips.txt','lists/ips-exclude.txt',
        'lists/user-domains.txt','lists/user-domains-exclude.txt','lists/user-ips.txt','lists/user-ips-exclude.txt',
        'state/enabled-game-filters.txt','state/universal-game-transport.json','state/domain-packs.json')
    $profilePath = Resolve-MaintenancePath $AppRoot "config/profiles/$ProfileId.json"
    $profile = [IO.File]::ReadAllText($profilePath) | ConvertFrom-Json
    foreach ($blob in @($profile.blobs)) { if ($blob.path) { $paths += ([string]$blob.path).Replace('\','/') } }
    foreach($relative in @($profile.interception.rawParts)){if($relative){$paths+=$relative.Replace('\','/')}}
    $catalog=Get-TargetCatalog $AppRoot
    if($catalog){
        $packState=Get-DomainPackState $AppRoot $catalog
        foreach($pack in @($catalog.packs|Where-Object {$packState.Enabled.Contains([string]$_.id)})){$paths+=([string]$pack.path).Replace('\','/')}
    }
    $universal = Get-UniversalGameTransport $AppRoot
    if ($universal.UsesUdp) { $paths += $universal.UdpFake.Replace('\','/') }
    foreach ($id in @(Get-EnabledGameFilterIds $AppRoot)) {
        $directory = Resolve-MaintenancePath $AppRoot "config/game-filters/$id"
        if (Test-Path -LiteralPath $directory) {
            foreach ($file in Get-ChildItem -LiteralPath $directory -File -Recurse) {
                $paths += $file.FullName.Substring([IO.Path]::GetFullPath($AppRoot).TrimEnd('\').Length+1).Replace('\','/')
            }
        } else { $paths += "config/game-filters/$id/filter.json" }
    }
    foreach ($filter in @(Get-EnabledGameFilters $AppRoot)) {
        if ($filter.Transport.UsesUdp) { $paths += $filter.Transport.UdpFake.Replace('\','/') }
    }
    $mappingRoot = Resolve-MaintenancePath $AppRoot 'config/network-mappings'
    if (Test-Path -LiteralPath $mappingRoot) {
        foreach ($file in Get-ChildItem -LiteralPath $mappingRoot -File -Recurse) {
            $paths += $file.FullName.Substring([IO.Path]::GetFullPath($AppRoot).TrimEnd('\').Length+1).Replace('\','/')
        }
    }
    $files = @(
        foreach ($relative in @($paths | Sort-Object -Unique)) {
            [pscustomobject]@{path=$relative;sha256=(Get-MaintenanceHash (Resolve-MaintenancePath $AppRoot $relative))}
        }
    )
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(([ordered]@{options=$values;files=$files} | ConvertTo-Json -Depth 10 -Compress)))).Replace('-','') }
    finally { $sha.Dispose() }
    [pscustomobject]@{schemaVersion=1;profile=$ProfileId;configuredProfile=$config.activeProfile;options=[pscustomobject]$values;files=$files;contentSha256=$hash}
}

function Save-TpmAppliedConfiguration {
    param([string]$AppRoot, [string]$ProfileId, [Diagnostics.Process]$Process, [ValidateSet('process','service')][string]$Mode = 'process', [string]$ConfiguredProfile = '', [object]$Snapshot = $null)
    $snapshot = if ($Snapshot) { $Snapshot | ConvertTo-Json -Depth 20 | ConvertFrom-Json } else { New-TpmConfigurationSnapshot $AppRoot $ProfileId }
    if ($ConfiguredProfile) { $snapshot.configuredProfile=$ConfiguredProfile }
    $snapshot | Add-Member -NotePropertyName capturedAt -NotePropertyValue ([DateTimeOffset]::Now.ToString('o'))
    if ($Process) {
        $snapshot | Add-Member -NotePropertyName process -NotePropertyValue @{pid=$Process.Id;startTimeUtcTicks=$Process.StartTime.ToUniversalTime().Ticks;executable=$Process.Path}
    }
    Write-MaintenanceJson (Resolve-MaintenancePath $AppRoot "state/applied-$Mode.json") $snapshot
}

function Compare-TpmConfigurationSnapshots($Before, $After) {
    foreach ($name in @('profile','autoHostlist','debug','allowAllWithoutTargets')) {
        if ($Before.options.$name -cne $After.options.$name) { [pscustomobject]@{path="options.$name";action='changed'} }
    }
    $old = @{}; $new = @{}
    foreach ($file in $Before.files) { $old[$file.path] = $file.sha256 }
    foreach ($file in $After.files) { $new[$file.path] = $file.sha256 }
    foreach ($path in @(@($old.Keys) + @($new.Keys) | Sort-Object -Unique)) {
        if ($old[$path] -cne $new[$path]) { [pscustomobject]@{path=$path;action='changed'} }
    }
}

function Get-TpmConfigurationStatus([string]$AppRoot) {
    $current = New-TpmConfigurationSnapshot $AppRoot
    $configuredProfile = $current.profile
    $service = Get-Service -Name TrafficProfileService -ErrorAction SilentlyContinue
    $root = $AppRoot; $mode = 'process'; $running = $false
    if ($service) {
        $root = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'TrafficProfileManager/Service'
        $mode = 'service'; $running = $service.Status -eq 'Running'
    }
    $path = Resolve-MaintenancePath $root "state/applied-$mode.json"
    $before = $null
    if (Test-Path -LiteralPath $path) { $before = [IO.File]::ReadAllText($path) | ConvertFrom-Json }
    if ($before -and $before.schemaVersion -ne 1) { throw 'Unsupported applied configuration snapshot.' }
    if ($mode -eq 'process' -and $before.process) {
        $process = Get-Process -Id $before.process.pid -ErrorAction SilentlyContinue
        try { $running = $process -and $process.Path -ieq $before.process.executable -and $process.StartTime.ToUniversalTime().Ticks -eq $before.process.startTimeUtcTicks } catch { $running = $false }
    }
    if ($mode -eq 'process' -and -not $running) {
        $identityPath=Resolve-MaintenancePath $AppRoot 'state/winws2.identity.json'
        if(Test-Path -LiteralPath $identityPath){
            try{
                $identity=[IO.File]::ReadAllText($identityPath)|ConvertFrom-Json
                $owned=Get-Process -Id $identity.pid -ErrorAction SilentlyContinue
                if($owned -and $owned.ProcessName -eq 'winws2' -and $owned.Path -ieq $identity.executable -and $owned.StartTime.ToUniversalTime().Ticks -eq $identity.startTimeUtcTicks){
                    # An adopted process or a failed metadata write does not establish which settings it loaded.
                    $running=$true;$before=$null
                }
            }catch{ $running=$false }
        }
    }
    if ($before.configuredProfile -and $current.profile -eq $before.configuredProfile) { $current=New-TpmConfigurationSnapshot $AppRoot $before.profile }
    $changes = @(if ($before) { Compare-TpmConfigurationSnapshots $before $current })
    $status = if (-not $before) { 'unknown' } elseif ($changes.Count) { 'pending' } elseif ($running) { 'applied' } else { 'stopped' }
    [pscustomobject]@{status=$status;mode=$mode;running=[bool]$running;configuredProfile=$configuredProfile;effectiveProfile=$current.profile;appliedProfile=$(if ($before) {$before.profile} else {$null});changes=@($changes);snapshot=$path}
}
