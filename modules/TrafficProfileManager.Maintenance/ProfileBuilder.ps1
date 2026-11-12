function New-TpmDataStage([string]$AppRoot) {
    $stage = Resolve-MaintenancePath $AppRoot ('state/c-' + [Guid]::NewGuid().ToString('N').Substring(0,8))
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
        foreach ($name in @('enabled-game-filters.txt','universal-game-transport.json','domain-packs.json')) {
            $path = Resolve-MaintenancePath $AppRoot "state/$name"
            if (Test-Path -LiteralPath $path) { Copy-MaintenanceFile $path (Join-Path $stage "state/$name") }
        }
        New-Item -ItemType Directory -Path (Join-Path $stage 'state') -Force | Out-Null
        return $stage
    } catch { if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }; throw }
}

function Invoke-TpmCandidateCheck([string]$AppRoot, [string]$Stage, [string]$ProfileId) {
    $configPath = Join-Path $Stage 'config/config.json'
    $config = [IO.File]::ReadAllText($configPath) | ConvertFrom-Json
    $config.activeProfile = $ProfileId
    $runtime = [string]$config.runtimePath
    if ($runtime) {
        if (-not [IO.Path]::IsPathRooted($runtime)) { $runtime = Resolve-MaintenancePath $AppRoot $runtime }
    } else {
        $runtimeRoot = Resolve-MaintenancePath $AppRoot 'runtime'
        $manifest = Get-TpmRuntimeManifest (Join-Path $runtimeRoot 'SOURCE.json')
        $portable = (Test-Path -LiteralPath (Join-Path $AppRoot 'metadata/release-manifest.json')) -or (Test-Path -LiteralPath (Join-Path $AppRoot '.tpm-release-manifest.json'))
        $layout=if($portable){'Portable'}else{'Source'}
        foreach($key in @('winws2','winDivertDll','winDivertDriver','cygwin','luaLib','luaAntidpi')){
            $record=$manifest.runtimeFiles.$key
            $source=Get-TpmVerifiedRuntimeFile $runtimeRoot $record $layout
            Copy-MaintenanceFile $source (Resolve-MaintenancePath $Stage ('runtime/'+$record.releasePath.Replace('\','/')))
        }
        $runtime=Join-Path $Stage 'runtime/winws2.exe'
    }
    # An explicitly configured engine may keep its Lua files elsewhere in the source runtime tree.
    foreach ($name in @('zapret-lib.lua','zapret-antidpi.lua')) {
        $near=Split-Path -Parent $runtime
        if ((Test-Path -LiteralPath (Join-Path $near $name)) -or (Test-Path -LiteralPath (Join-Path $near "lua/$name"))) { continue }
        $found=Get-ChildItem -LiteralPath (Join-Path $AppRoot 'runtime') -Filter $name -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) { Copy-MaintenanceFile $found.FullName (Resolve-MaintenancePath $Stage "runtime/lua/$name") }
    }
    $config.runtimePath = $runtime
    Write-MaintenanceJson $configPath $config
    $entry = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'zapretctl.ps1'
    $info = New-TpmProcessStartInfo -FilePath powershell.exe -ArgumentList @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$entry,'check',$ProfileId) -CreateNoWindow -RedirectStandardOutput -RedirectStandardError
    $info.EnvironmentVariables['ZAPRETCTL_HOME'] = $Stage
    $process = [Diagnostics.Process]::Start($info)
    try {
        $output = $process.StandardOutput.ReadToEndAsync(); $errors = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(30000)) { $process.Kill(); throw 'Profile validation timed out.' }
        if ($process.ExitCode -ne 0) { throw ('Profile validation failed: ' + $output.GetAwaiter().GetResult() + $errors.GetAwaiter().GetResult()) }
    } finally { $process.Dispose() }
}

function New-TpmBuiltProfile {
    param([string]$AppRoot, [object]$Recipe)
    $fields = @('schemaVersion','id','displayName','baseProfile','httpProfile','tlsProfile','quicProfile')
    if ($Recipe -isnot [pscustomobject] -or $Recipe.schemaVersion -ne 1 -or @($Recipe.PSObject.Properties.Name | Where-Object { $_ -notin $fields }).Count) { throw 'Invalid profile recipe fields or schemaVersion.' }
    if ($Recipe.id -cnotmatch '^[a-z0-9][a-z0-9_-]{0,63}$') { throw 'Invalid new profile ID.' }
    if ([string]::IsNullOrWhiteSpace($Recipe.displayName)) { throw 'displayName is required.' }
    $catalog = @(Get-TrafficProfiles $AppRoot)
    $base = @($catalog | Where-Object Id -eq $Recipe.baseProfile) | Select-Object -First 1
    if (-not $base) { throw 'The base profile is missing or invalid.' }
    $profile = [IO.File]::ReadAllText($base.Path) | ConvertFrom-Json
    $profile.name = $Recipe.id
    $profile | Add-Member -NotePropertyName displayName -NotePropertyValue $Recipe.displayName -Force
    $profile | Add-Member -NotePropertyName description -NotePropertyValue ("Built from $($Recipe.baseProfile); HTTP=$($Recipe.httpProfile); TLS=$($Recipe.tlsProfile); QUIC=$($Recipe.quicProfile).") -Force
    $profile | Add-Member -NotePropertyName order -NotePropertyValue 10000 -Force
    foreach ($kind in @('http','tls','quic')) {
        $sourceId = $Recipe.($kind + 'Profile')
        if (-not $sourceId -or $sourceId -eq $base.Id) { continue }
        $donor = @($catalog | Where-Object Id -eq $sourceId) | Select-Object -First 1
        if (-not $donor) { throw "Invalid source profile for ${kind}: $sourceId" }
        $definition = [IO.File]::ReadAllText($donor.Path) | ConvertFrom-Json
        $sourceRule = @($definition.rules | Where-Object name -eq $kind)
        $targetRule = @($profile.rules | Where-Object name -eq $kind)
        if ($sourceRule.Count -ne 1 -or $targetRule.Count -ne 1) { throw "Both profiles must contain exactly one '$kind' rule." }
        # Copy actions only: matching, scopes, special rules and intercepted ports stay with the base profile.
        $targetRule[0].actions = @($sourceRule[0].actions)
        foreach ($blob in @($definition.blobs)) {
            $existing = @($profile.blobs | Where-Object name -eq $blob.name)
            if ($existing.Count -and $existing[0].path -ine $blob.path) { throw "Conflicting blob '$($blob.name)'. Choose another source profile." }
            if (-not $existing.Count) { $profile | Add-Member -NotePropertyName blobs -NotePropertyValue (@($profile.blobs) + @($blob)) -Force }
        }
    }
    [void](Test-TrafficProfileDefinition $profile (Join-Path $AppRoot "config/profiles/$($Recipe.id).json") $AppRoot)
    return $profile
}

function Save-TpmBuiltProfile {
    param([string]$AppRoot, [object]$Recipe)
    Invoke-MaintenanceLock $AppRoot {
        $profile = New-TpmBuiltProfile $AppRoot $Recipe
        $relative = "config/profiles/$($profile.name).json"
        if (Test-Path -LiteralPath (Resolve-MaintenancePath $AppRoot $relative)) { throw 'Profile already exists. Existing and manually edited profiles are never overwritten by the constructor.' }
        $stage = New-TpmDataStage $AppRoot
        try {
            Write-MaintenanceJson (Join-Path $stage $relative) $profile
            Invoke-TpmCandidateCheck $AppRoot $stage $profile.name
            Write-MaintenanceJson (Join-Path $stage 'recipe.json') $Recipe
            $changes = @([pscustomobject]@{path=$relative;source=(Join-Path $stage $relative)},[pscustomobject]@{path="state/profile-recipes/$($profile.name).json";source=(Join-Path $stage 'recipe.json')})
            $result = Invoke-FileTransaction $AppRoot $changes 'build-profile'
            [pscustomobject]@{profile=$profile.name;path=(Join-Path $AppRoot $relative);transactionId=$result.transactionId;validated=$true}
        } finally { Remove-Item -LiteralPath $stage -Recurse -Force }
    }
}
