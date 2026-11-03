function Test-UserDataPath([string]$Path) {
    return $Path -match '^(config|lists|assets)/' -or $Path -eq 'tests/targets.txt' -or
        $Path -in @('state/user-settings.json','state/domain-packs.json','state/enabled-game-filters.txt','state/universal-game-transport.json','state/service-profile.txt')
}

function New-TpmUserBackup {
    param([string]$AppRoot, [string]$OutputPath = '')
    Invoke-MaintenanceLock $AppRoot {
        $destination = if ($OutputPath) { [IO.Path]::GetFullPath($OutputPath) } else {
            Resolve-MaintenancePath $AppRoot ('backups\settings-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0,8) + '.zip')
        }
        if (Test-Path -LiteralPath $destination) { throw 'The backup destination already exists.' }
        $files = @(
            foreach ($directory in @('config','lists','assets')) {
                $base = Resolve-MaintenancePath $AppRoot $directory
                if (Test-Path -LiteralPath $base) { Get-ChildItem -LiteralPath $base -File -Recurse }
            }
            foreach ($relative in @('tests/targets.txt','state/user-settings.json','state/domain-packs.json','state/enabled-game-filters.txt','state/universal-game-transport.json','state/service-profile.txt')) {
                $path = Resolve-MaintenancePath $AppRoot $relative
                if (Test-Path -LiteralPath $path -PathType Leaf) { Get-Item -LiteralPath $path }
            }
        )
        New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
        $temporary = "$destination.$([Guid]::NewGuid().ToString('N')).tmp"
        try {
            $zip = [IO.Compression.ZipFile]::Open($temporary, 'Create')
            try {
                $records = @(
                    foreach ($file in $files) {
                        $relative = $file.FullName.Substring([IO.Path]::GetFullPath($AppRoot).TrimEnd('\').Length + 1).Replace('\','/')
                        $path = Resolve-MaintenancePath $AppRoot $relative
                        $hash = Get-MaintenanceHash $path
                        [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $path, $relative)
                        [pscustomobject]@{ path=$relative; length=$file.Length; sha256=$hash }
                    }
                )
                $entry = $zip.CreateEntry('backup.json')
                $writer = [IO.StreamWriter]::new($entry.Open(), [Text.UTF8Encoding]::new($false))
                try {
                    $writer.Write((@{ schemaVersion=1; createdAt=[DateTime]::UtcNow.ToString('o'); files=$records } | ConvertTo-Json -Depth 10))
                } finally { $writer.Dispose() }
            } finally { $zip.Dispose() }
            [void](Get-TpmRestorePlan -AppRoot $AppRoot -ArchivePath $temporary)
            Move-Item -LiteralPath $temporary -Destination $destination
        } finally {
            if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
        }
        [pscustomobject]@{ archive=$destination; sha256=(Get-MaintenanceHash $destination); files=$records.Count }
    }
}

function Get-TpmRestorePlan([string]$AppRoot, [string]$ArchivePath) {
    $ArchivePath = Resolve-TpmArchivePath $ArchivePath
    $zip = (Open-MaintenanceArchive $ArchivePath)
    try {
        $index = Get-ZipIndex $zip
        $manifest = Read-ZipJson $index['backup.json']
        if ($manifest.schemaVersion -ne 1 -or $null -eq $manifest.files) { throw 'Unsupported backup format.' }
        $seen = @{}
        $plan = @(
            foreach ($record in $manifest.files) {
                $relative = ([string]$record.path).Replace('\','/')
                if (-not (Test-UserDataPath $relative) -or $seen.ContainsKey($relative)) { throw 'Unsafe or duplicate backup entry.' }
                $seen[$relative] = $true
                $target = Resolve-MaintenancePath $AppRoot $relative
                $entry = $index[$relative]
                if (-not $entry) { throw "Backup entry is missing: $relative" }
                $stream = $entry.Open()
                try { Assert-TpmRuntimeContent $stream $record.sha256 $record.length $relative } finally { $stream.Dispose() }
                [pscustomobject]@{ path=$relative; action=$(if (Test-Path -LiteralPath $target) { 'replace' } else { 'create' }); sha256=$record.sha256; length=$record.length }
            }
        )
        if ($index.Count -ne $seen.Count + 1) { throw 'Backup contains undeclared files.' }
        return $plan
    } finally { $zip.Dispose() }
}

function Restore-TpmUserBackup([string]$AppRoot, [string]$ArchivePath) {
    $ArchivePath = Resolve-TpmArchivePath $ArchivePath
    Invoke-MaintenanceLock $AppRoot {
        Assert-MaintenanceStopped $AppRoot
        $plan = @(Get-TpmRestorePlan $AppRoot $ArchivePath)
        $stage = Resolve-MaintenancePath $AppRoot ('state\restore-' + [Guid]::NewGuid().ToString('N'))
        $zip = (Open-MaintenanceArchive $ArchivePath)
        try {
            $index = Get-ZipIndex $zip
            $changes = @(
                foreach ($record in $plan) {
                    $destination = Resolve-MaintenancePath $stage $record.path
                    Expand-ZipEntry $index[$record.path] $destination
                    $stream = [IO.File]::OpenRead($destination)
                    try { Assert-TpmRuntimeContent $stream $record.sha256 $record.length $record.path } finally { $stream.Dispose() }
                    [pscustomobject]@{ path=$record.path; source=$destination }
                }
            )
            Invoke-FileTransaction $AppRoot $changes 'restore'
        } finally {
            $zip.Dispose()
            if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
        }
    }
}
