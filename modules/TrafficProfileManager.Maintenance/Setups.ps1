function Assert-TpmSetupProfile([string]$AppRoot,[string]$ProfileId) {
    if ($ProfileId -notmatch '^[a-zA-Z0-9_-]{1,64}$') { throw 'Invalid profile ID.' }
    $path=Resolve-MaintenancePath $AppRoot "config/profiles/$ProfileId.json"
    try {
        $definition=[IO.File]::ReadAllText($path)|ConvertFrom-Json
        [void](Test-TrafficProfileDefinition $definition $path $AppRoot)
    } catch { throw "Setup references a missing or invalid profile: $ProfileId. $($_.Exception.Message)" }
}
# Named setups contain data only. Active files remain compatible with older BAT launchers.
. (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'tools/catalog-library.ps1')
. (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'tools/game-filter-library.ps1')

function Get-TpmSetupPath([string]$AppRoot, [string]$Id) {
    if ($Id -cnotmatch '^[a-z0-9][a-z0-9_-]{0,63}$') { throw 'Setup ID: use 1-64 lowercase letters, numbers, hyphens or underscores.' }
    return Resolve-MaintenancePath $AppRoot ("state/setups/$Id/setup.json")
}

function Get-TpmSetups([string]$AppRoot) {
    $directory = Resolve-MaintenancePath $AppRoot 'state/setups'
    if (-not (Test-Path -LiteralPath $directory)) { return }
    $selectedPath=Resolve-MaintenancePath $AppRoot 'state/selected-setup.json'
    $selectedId=''
    if(Test-Path -LiteralPath $selectedPath){try{$selectedId=([IO.File]::ReadAllText($selectedPath)|ConvertFrom-Json).id}catch{$selectedId=''}}
    foreach ($folder in Get-ChildItem -LiteralPath $directory -Directory | Sort-Object Name) {
        try {
            $path = Get-TpmSetupPath $AppRoot $folder.Name
            $value = [IO.File]::ReadAllText($path) | ConvertFrom-Json
            if ($value.schemaVersion -ne 1 -or $value.id -cne $folder.Name) { throw 'Invalid setup identity or schemaVersion.' }
            [pscustomobject]@{ id=$value.id; displayName=$value.displayName; profile=$value.profile; path=$path; valid=$true; error=$null; lastSelected=($value.id -eq $selectedId) }
        } catch {
            [pscustomobject]@{ id=$folder.Name; displayName=$folder.Name; profile=''; path=$null; valid=$false; error=$_.Exception.Message }
        }
    }
}

function Save-TpmSetup {
    param([string]$AppRoot, [string]$Id, [string]$DisplayName = '', [switch]$Overwrite)
    Invoke-MaintenanceLock $AppRoot {
        $path = Get-TpmSetupPath $AppRoot $Id
        if ((Test-Path -LiteralPath $path) -and -not $Overwrite) { throw 'Setup already exists. Use save to replace it explicitly.' }
        if ($Overwrite -and -not $DisplayName -and (Test-Path -LiteralPath $path)) { $DisplayName=([IO.File]::ReadAllText($path)|ConvertFrom-Json).displayName }
        $config = [IO.File]::ReadAllText((Resolve-MaintenancePath $AppRoot 'config/config.json')) | ConvertFrom-Json
        Assert-TpmSetupProfile $AppRoot $config.activeProfile
        $catalog = Get-TargetCatalog $AppRoot
        $packs = if ($catalog) { @((Get-DomainPackState $AppRoot $catalog).Enabled | Sort-Object) } else { @() }
        $transportPath = Resolve-MaintenancePath $AppRoot 'state/universal-game-transport.json'
        $transport = if (Test-Path -LiteralPath $transportPath) { [IO.File]::ReadAllText($transportPath) | ConvertFrom-Json } else { Get-DefaultUniversalGameTransportState }
        [void](Get-UniversalGameTransport $AppRoot)
        [void](Get-EnabledGameFilters $AppRoot)
        $value = [ordered]@{ schemaVersion=1; id=$Id; displayName=$(if ($DisplayName) { $DisplayName } else { $Id }); profile=$config.activeProfile
            domainPacks=@($packs); gameFilters=@(Get-EnabledGameFilterIds $AppRoot); universalTransport=$transport
            options=[ordered]@{ autoHostlist=[bool]$config.autoHostlist; debug=[bool]$config.debug; allowAllWithoutTargets=[bool]$config.allowAllWithoutTargets } }
        $stage = Resolve-MaintenancePath $AppRoot ('state/setup-save-' + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $stage -Force | Out-Null
        try {
            Write-MaintenanceJson (Join-Path $stage 'setup.json') $value
            $changes = @([pscustomobject]@{path="state/setups/$Id/setup.json";source=(Join-Path $stage 'setup.json')})
            foreach ($name in @('user-domains.txt','user-domains-exclude.txt','user-ips.txt','user-ips-exclude.txt')) {
                $source = Resolve-MaintenancePath $AppRoot "lists/$name"
                $copy = Join-Path $stage $name
                if (Test-Path -LiteralPath $source) { Copy-MaintenanceFile $source $copy } else { [IO.File]::WriteAllText($copy, '', [Text.UTF8Encoding]::new($false)) }
                $changes += [pscustomobject]@{path="state/setups/$Id/$name";source=$copy}
            }
            $result = Invoke-FileTransaction $AppRoot $changes 'save-setup'
            [pscustomobject]@{ id=$Id; path=$path; transactionId=$result.transactionId }
        } finally { Remove-Item -LiteralPath $stage -Recurse -Force }
    }
}

function Initialize-TpmSetups([string]$AppRoot) {
    if (-not @(Get-TpmSetups $AppRoot).Count) { [void](Save-TpmSetup $AppRoot 'main' 'Main'); Write-MaintenanceJson (Resolve-MaintenancePath $AppRoot 'state/selected-setup.json') @{schemaVersion=1;id='main'} }
}

function New-TpmSetupStage([string]$AppRoot, [string]$Id) {
    $path = Get-TpmSetupPath $AppRoot $Id
    try { $setup = [IO.File]::ReadAllText($path) | ConvertFrom-Json } catch { throw "Cannot read setup: $path. $($_.Exception.Message)" }
    $required = @('schemaVersion','id','displayName','profile','domainPacks','gameFilters','universalTransport','options')
    if ($setup -isnot [pscustomobject] -or @($required | Where-Object { $_ -notin $setup.PSObject.Properties.Name }).Count -or
        @($setup.PSObject.Properties.Name | Where-Object { $_ -notin $required }).Count -or $setup.schemaVersion -ne 1 -or $setup.id -cne $Id) { throw "Invalid fields in $path" }
    if ($setup.domainPacks -isnot [Array] -or $setup.gameFilters -isnot [Array] -or [string]::IsNullOrWhiteSpace($setup.displayName)) { throw "Invalid lists or displayName in $path" }
    Assert-TpmSetupProfile $AppRoot $setup.profile
    foreach ($field in @('autoHostlist','debug','allowAllWithoutTargets')) {
        if ($setup.options.$field -isnot [bool]) { throw "options.$field must be boolean in $path" }
    }
    $stage = Resolve-MaintenancePath $AppRoot ('state/setup-stage-' + [Guid]::NewGuid().ToString('N'))
    try {
        foreach ($directory in @('config','lists','assets')) {
            $base = Resolve-MaintenancePath $AppRoot $directory
            if (Test-Path -LiteralPath $base) {
                foreach ($file in Get-ChildItem -LiteralPath $base -File -Recurse) {
                    $relative = $file.FullName.Substring([IO.Path]::GetFullPath($AppRoot).TrimEnd('\').Length+1)
                    Copy-MaintenanceFile (Resolve-MaintenancePath $AppRoot $relative) (Resolve-MaintenancePath $stage $relative)
                }
            }
        }

        $config = [IO.File]::ReadAllText((Join-Path $stage 'config/config.json')) | ConvertFrom-Json
        $config.activeProfile = $setup.profile
        foreach ($field in @('autoHostlist','debug','allowAllWithoutTargets')) { $config | Add-Member -NotePropertyName $field -NotePropertyValue $setup.options.$field -Force }
        Write-MaintenanceJson (Join-Path $stage 'config/config.json') $config
        $catalog = Get-TargetCatalog $stage
        $known = if ($catalog) { @($catalog.packs.id) } else { @() }
        if (@($setup.domainPacks | Where-Object { $_ -notin $known }).Count) { throw 'Setup references missing domain packs.' }
        Write-MaintenanceJson (Join-Path $stage 'state/domain-packs.json') @{schemaVersion=1;knownPacks=$known;enabledPacks=@($setup.domainPacks)}
        [void](Sync-DomainCatalog $stage)
        Write-MaintenanceJson (Join-Path $stage 'state/universal-game-transport.json') $setup.universalTransport
        [void](Get-UniversalGameTransport $stage)
        $games = @(Get-GameFilters $stage)
        if (@($setup.gameFilters | Where-Object { $_ -notin $games.Id }).Count) { throw 'Setup references missing or invalid game filters.' }
        [IO.File]::WriteAllLines((Join-Path $stage 'state/enabled-game-filters.txt'), [string[]]$setup.gameFilters, [Text.UTF8Encoding]::new($false))
        [void](Get-EnabledGameFilters $stage)
        $changes = @()
        foreach ($name in @('user-domains.txt','user-domains-exclude.txt','user-ips.txt','user-ips-exclude.txt')) {
            $source = Resolve-MaintenancePath $AppRoot ("state/setups/$Id/$name")
            foreach ($line in @(Get-TpmMeaningfulLines $source)) {
                if ($name -like '*domains*') { [void](ConvertTo-TpmDomain $line) } else { [void](ConvertTo-TpmIpNetwork $line) }
            }
            if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Setup list is missing: $source" }
            Copy-MaintenanceFile $source (Join-Path $stage "lists/$name")
            $changes += [pscustomobject]@{path="lists/$name";source=(Join-Path $stage "lists/$name")}
        }
        foreach ($relative in @('config/config.json','lists/domains.txt','state/domain-packs.json','state/enabled-game-filters.txt','state/universal-game-transport.json')) {
            $source = Join-Path $stage $relative
            if (Test-Path -LiteralPath $source) { $changes += [pscustomobject]@{path=$relative;source=$source} }
        }
        return [pscustomobject]@{ root=$stage; setup=$setup; changes=$changes }
    } catch { if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }; throw }
}

function Get-TpmSetupPlan([string]$AppRoot, [string]$Id) {
    $stage = New-TpmSetupStage $AppRoot $Id
    try {
        foreach ($change in $stage.changes) {
            $before = Get-MaintenanceHash (Resolve-MaintenancePath $AppRoot $change.path)
            $after = Get-MaintenanceHash $change.source
            [pscustomobject]@{path=$change.path;action=$(if ($before -eq $after) {'unchanged'} elseif ($before) {'replace'} else {'create'});before=$before;after=$after}
        }
    } finally { Remove-Item -LiteralPath $stage.root -Recurse -Force }
}

function Assert-TpmConfigurationStopped([string]$AppRoot) {
    $service=Get-Service -Name TrafficProfileService -ErrorAction SilentlyContinue
    if (($service -and $service.Status -ne 'Stopped') -or @(Get-Process -Name winws2 -ErrorAction SilentlyContinue).Count) {
        throw 'Stop running profiles or the service before switching setups.'
    }
}

function Use-TpmSetup([string]$AppRoot, [string]$Id) {
    Initialize-TpmSetups $AppRoot
    Invoke-MaintenanceLock $AppRoot {
        # Saving active files is allowed with a stopped installed service; its protected copy is applied separately.
        Assert-TpmConfigurationStopped $AppRoot
        $stage = New-TpmSetupStage $AppRoot $Id
        try {
            Write-MaintenanceJson (Join-Path $stage.root 'selected-setup.json') @{schemaVersion=1;id=$Id}
            $changes = @($stage.changes) + @([pscustomobject]@{path='state/selected-setup.json';source=(Join-Path $stage.root 'selected-setup.json')})
            $result = Invoke-FileTransaction $AppRoot $changes 'use-setup'
            [pscustomobject]@{id=$Id;transactionId=$result.transactionId;restartRequired=$true}
        } finally { Remove-Item -LiteralPath $stage.root -Recurse -Force }
    }
}
