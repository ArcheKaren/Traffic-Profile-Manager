function Test-ProductPath([string]$Path) {
    return $Path -match '^(modules|tools|runtime|config|lists|assets|docs|tests|metadata)/' -or
        $Path -in @('VERSION','LICENSE','README.md','CHANGELOG.md','CONTRIBUTING.md','SECURITY.md','THIRD-PARTY-LICENSES.txt','BUILD-INFO.json','.tpm-release-manifest.json') -or
        ($Path -notmatch '/' -and $Path -match '\.(bat|cmd|ps1)$')
}

function Get-TpmUpdatePlan([string]$AppRoot, [string]$ArchivePath, [string]$Sha256) {
    $ArchivePath = Resolve-TpmArchivePath $ArchivePath
    if ($Sha256 -notmatch '^[A-Fa-f0-9]{64}$' -or (Get-MaintenanceHash $ArchivePath) -ine $Sha256) {
        throw 'Update archive SHA-256 mismatch.'
    }
    $zip = (Open-MaintenanceArchive $ArchivePath)
    try {
        $index = Get-ZipIndex $zip 'TrafficProfileManager/'
        $compact = $index.ContainsKey('metadata/release-manifest.json')
        $manifestName = if ($compact) { 'metadata/release-manifest.json' } else { '.tpm-release-manifest.json' }
        $metadataName = if ($compact) { 'metadata/BUILD-INFO.json' } else { 'BUILD-INFO.json' }
        $versionName = if ($compact) { 'metadata/VERSION' } else { 'VERSION' }
        foreach ($required in @($manifestName,$metadataName,$versionName)) {
            if (-not $index.ContainsKey($required)) { throw "Update metadata is missing: $required" }
        }
        $manifest = Read-ZipJson $index[$manifestName]
        $metadata = Read-ZipJson $index[$metadataName]
        $runtime = Read-ZipJson $index['runtime/SOURCE.json']
        if ($manifest.schemaVersion -ne 1 -or $metadata.schemaVersion -ne 1 -or
            [string]$metadata.version -notmatch '^\d+\.\d+\.\d+$') { throw 'Unsupported update metadata.' }
        $reader = [IO.StreamReader]::new($index[$versionName].Open())
        try { $version = $reader.ReadToEnd().Trim() } finally { $reader.Dispose() }
        if ($version -cne $metadata.version) { throw 'Update version metadata is inconsistent.' }
        $installedVersion = (Get-TpmBuildInfo -AppRoot $AppRoot).version
        if ($installedVersion -match '^\d+\.\d+\.\d+$' -and [version]$version -lt [version]$installedVersion) {
            throw 'Installing an older release is not supported; use rollback instead.'
        }
        $seen = @{}
        $plan = @(
            foreach ($value in @($manifest.managedFiles) + @($manifestName)) {
                $relative = ([string]$value).Replace('\','/')
                if (-not (Test-ProductPath $relative) -or $seen.ContainsKey($relative)) { throw 'Unsafe or duplicate managed update file.' }
                $seen[$relative] = $true
                $target = Resolve-MaintenancePath $AppRoot $relative
                if (-not $index.ContainsKey($relative)) { throw "Update file is missing: $relative" }
                $action = if ((Test-UserDataPath $relative) -and (Test-Path -LiteralPath $target)) { 'preserve' } else { 'replace' }
                [pscustomobject]@{ path=$relative; action=$action; version=$version }
            }
        )
        if ($index.Count -ne $seen.Count) { throw 'Update archive contains undeclared files.' }
        foreach ($key in @('winws2','winDivertDll','winDivertDriver','cygwin','luaLib','luaAntidpi')) {
            $record = $runtime.runtimeFiles.$key
            if (-not $record -or [int64]$record.length -le 0) { throw "Missing runtime metadata: $key" }
            $relative = 'runtime/' + ([string]$record.releasePath).Replace('\','/')
            [void](Resolve-MaintenancePath $AppRoot $relative)
            $entry = $index[$relative]
            if (-not $entry) { throw "Update runtime entry is missing: $relative" }
            $stream = $entry.Open()
            try { Assert-TpmRuntimeContent $stream $record.sha256 $record.length $relative } finally { $stream.Dispose() }
        }
        foreach ($required in @('Manager.bat','zapretctl.ps1','config/config.json')) {
            if (-not $seen.ContainsKey($required)) { throw "Required update file is missing: $required" }
        }
        $previousName = 'metadata/release-manifest.json'
        $previousPath = Resolve-MaintenancePath $AppRoot $previousName
        if (-not (Test-Path -LiteralPath $previousPath -PathType Leaf)) {
            $previousName = '.tpm-release-manifest.json'
            $previousPath = Resolve-MaintenancePath $AppRoot $previousName
        }
        if (Test-Path -LiteralPath $previousPath) {
            $previous = [IO.File]::ReadAllText($previousPath) | ConvertFrom-Json
            if ($previous.schemaVersion -ne 1) { throw 'Unsupported installed release manifest.' }
            foreach ($value in @($previous.managedFiles) + @($previousName)) {
                $relative = ([string]$value).Replace('\','/')
                [void](Resolve-MaintenancePath $AppRoot $relative)
                if (-not (Test-ProductPath $relative)) { throw 'Unsafe installed release manifest.' }
                if ($relative -notin $plan.path -and -not (Test-UserDataPath $relative)) {
                    $plan += [pscustomobject]@{ path=$relative; action='delete'; version=$version }
                }
            }
        }
        return $plan
    } finally { $zip.Dispose() }
}

function Install-TpmUpdate([string]$AppRoot, [string]$ArchivePath, [string]$Sha256) {
    $ArchivePath = Resolve-TpmArchivePath $ArchivePath
    Invoke-MaintenanceLock $AppRoot {
        Assert-MaintenanceStopped $AppRoot
        $stage = Resolve-MaintenancePath $AppRoot ('state\update-' + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $stage -Force | Out-Null
        try {
            $snapshot = Join-Path $stage 'package.zip'
            Copy-Item -LiteralPath $ArchivePath -Destination $snapshot
            $plan = @(Get-TpmUpdatePlan $AppRoot $snapshot $Sha256)
            $zip = [IO.Compression.ZipFile]::OpenRead($snapshot)
            try {
                $index = Get-ZipIndex $zip 'TrafficProfileManager/'
                $changes = @(
                    foreach ($record in $plan | Where-Object action -ne 'preserve') {
                        if ($record.action -eq 'delete') {
                            [pscustomobject]@{ path=$record.path; source=$null }
                            continue
                        }
                        $destination = Resolve-MaintenancePath (Join-Path $stage 'files') $record.path
                        Expand-ZipEntry $index[$record.path] $destination
                        [pscustomobject]@{ path=$record.path; source=$destination }
                    }
                )
            } finally { $zip.Dispose() }
            $backup = New-TpmUserBackup $AppRoot
            $transaction = Invoke-FileTransaction $AppRoot $changes 'update'
            $transaction | Add-Member -NotePropertyName settingsBackup -NotePropertyValue $backup.archive
            $transaction
        } finally {
            if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
        }
    }
}

function Get-TpmLatestRelease {
    $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/ArcheKaren/Traffic-Profile-Manager/releases/latest' -TimeoutSec 30
    $asset = @($release.assets | Where-Object name -eq 'TrafficProfileManager.zip')
    if ($asset.Count -ne 1) { throw 'The release does not contain a unique program archive.' }
    $uri = [Uri]$asset[0].browser_download_url
    if ($uri.Scheme -ne 'https' -or $uri.Host -ne 'github.com' -or
        $uri.AbsolutePath -notlike '/ArcheKaren/Traffic-Profile-Manager/releases/download/*') { throw 'Unexpected update URL.' }
    $hash = ([string]$asset[0].digest) -replace '^sha256:', ''
    if ($hash -notmatch '^[a-fA-F0-9]{64}$') {
        $hashAsset = @($release.assets | Where-Object name -eq 'SHA256SUMS.txt')
        if ($hashAsset.Count -ne 1) { throw 'The release has no SHA-256 checksum.' }
        $checksumUri = [Uri]$hashAsset[0].browser_download_url
        if ($checksumUri.Scheme -ne 'https' -or $checksumUri.Host -ne 'github.com' -or
            $checksumUri.AbsolutePath -notlike '/ArcheKaren/Traffic-Profile-Manager/releases/download/*') { throw 'Unexpected checksum URL.' }
        $content = (Invoke-WebRequest -UseBasicParsing -Uri $checksumUri -TimeoutSec 30).Content
        $match = [regex]::Match($content, '(?m)^([A-Fa-f0-9]{64})\s+\*?TrafficProfileManager\.zip\s*$')
        if (-not $match.Success) { throw 'The release checksum is invalid.' }
        $hash = $match.Groups[1].Value
    }
    [pscustomobject]@{ version=([string]$release.tag_name -replace '^v',''); url=$uri.AbsoluteUri; sha256=$hash; publishedAt=$release.published_at }
}

function Save-TpmLatestRelease([string]$AppRoot) {
    $release = Get-TpmLatestRelease
    $current = Get-TpmBuildInfo $AppRoot
    if ($release.version -match '^\d+\.\d+\.\d+$' -and $current.version -match '^\d+\.\d+\.\d+$' -and [version]$release.version -le [version]$current.version) {
        throw 'No newer release is available.'
    }
    $path = Resolve-MaintenancePath $AppRoot ('state\downloads\' + [Guid]::NewGuid().ToString('N') + '.zip')
    New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
    try {
        Invoke-WebRequest -UseBasicParsing -Uri $release.url -OutFile $path -TimeoutSec 120
        [void](Get-TpmUpdatePlan $AppRoot $path $release.sha256)
        [pscustomobject]@{ archive=$path; sha256=$release.sha256; version=$release.version }
    } catch {
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
        throw
    }
}
