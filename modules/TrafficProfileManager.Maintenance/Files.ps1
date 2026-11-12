function Resolve-TpmArchivePath {
    param([AllowEmptyString()][string]$ArchivePath)
    if ([string]::IsNullOrWhiteSpace($ArchivePath)) { throw 'Specify the path to an existing archive file.' }
    $value = $ArchivePath.Trim()
    if ($value.Length -ge 2 -and (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'")))) {
        $value = $value.Substring(1,$value.Length-2).Trim()
    }
    if ([string]::IsNullOrWhiteSpace($value)) { throw 'Specify the path to an existing archive file.' }
    try { $path = [IO.Path]::GetFullPath($value) }
    catch { throw 'The archive path is invalid. Select an existing archive file.' }
    if (Test-Path -LiteralPath $path -PathType Container) { throw 'Select an archive file, not a folder.' }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Archive file was not found: $path" }
    return $path
}

function Open-MaintenanceArchive([string]$ArchivePath) {
    try { return [IO.Compression.ZipFile]::OpenRead($ArchivePath) }
    catch { throw 'Cannot open the archive. Choose a valid backup or update ZIP.' }
}

function Resolve-MaintenancePath([string]$Root, [string]$Relative) {
    if ([string]::IsNullOrWhiteSpace($Relative) -or [IO.Path]::IsPathRooted($Relative)) {
        throw "Unsafe relative path: $Relative"
    }
    foreach ($part in $Relative.Replace('\','/').Split('/')) {
        if ($part -in @('','.','..') -or $part -match '[:<>"|?*]' -or
            $part -match '[. ]$' -or $part -match '^(?i:con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)') {
            throw "Unsafe relative path: $Relative"
        }
    }
    $base = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $path = [IO.Path]::GetFullPath((Join-Path $base $Relative))
    if (-not $path.StartsWith($base + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Path leaves the application directory.' }
    $current = $path
    while ($current.Length -ge $base.Length) {
        if (Test-Path -LiteralPath $current) {
            if ((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "Reparse points are not allowed: $current"
            }
        }
        if ($current -eq $base) { break }
        $current = Split-Path -Parent $current
    }
    return $path
}

function Write-MaintenanceJson([string]$Path, $Value) {
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    $temporary = "$Path.$([Guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 20) + "`r`n", [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporary -Destination $Path -Force
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
}

function Get-MaintenanceHash([string]$Path) {
    if (Test-Path -LiteralPath $Path -PathType Leaf) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
    return $null
}

function Copy-MaintenanceFile([string]$Source, [string]$Destination) {
    New-Item -ItemType Directory -Path (Split-Path -Parent $Destination) -Force | Out-Null
    $temporary = "$Destination.$([Guid]::NewGuid().ToString('N')).tmp"
    try {
        Copy-Item -LiteralPath $Source -Destination $temporary -Force
        Move-Item -LiteralPath $temporary -Destination $Destination -Force
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
}

function Assert-MaintenanceStopped([string]$AppRoot) {
    if (Get-Service -Name 'TrafficProfileService' -ErrorAction SilentlyContinue) {
        throw 'A service is installed. Export settings, remove the service, update, then reinstall its profile.'
    }
    if (@(Get-Process -Name 'winws2' -ErrorAction SilentlyContinue).Count) {
        throw 'Stop all running profiles before changing files.'
    }
    $pidPath = Join-Path $AppRoot 'state\winws2.windows.pid'
    if (Test-Path -LiteralPath $pidPath) {
        $processId = 0
        if ([int]::TryParse([IO.File]::ReadAllText($pidPath).Trim(), [ref]$processId) -and
            (Get-Process -Id $processId -ErrorAction SilentlyContinue)) {
            throw 'Stop all running profiles before changing files.'
        }
    }
}

function Invoke-MaintenanceLock([string]$Root, [scriptblock]$Operation) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $key = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes([IO.Path]::GetFullPath($Root).ToLowerInvariant()))).Replace('-','') }
    finally { $sha.Dispose() }
    $mutex = New-Object Threading.Mutex($false, ('Local\TrafficProfileManagerFiles-' + $key))
    $held = $false
    try {
        try { $held = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $held = $true }
        if (-not $held) { throw 'Another file operation is in progress.' }
        & $Operation
    } finally {
        if ($held) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Invoke-FileTransaction([string]$AppRoot, [object[]]$Changes, [string]$Purpose) {
    $changesByPath = @{}
    foreach ($change in $Changes) {
        if ($changesByPath.ContainsKey($change.path)) { throw "Duplicate transaction path: $($change.path)" }
        $changesByPath[$change.path] = $change
    }
    $id = [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0,8)
    $directory = Resolve-MaintenancePath $AppRoot ("backups\transactions\$id")
    $records = @(
        foreach ($change in $Changes) {
            $target = Resolve-MaintenancePath $AppRoot $change.path
            $oldHash = Get-MaintenanceHash $target
            $newHash = if ($change.source) { Get-MaintenanceHash $change.source } else { $null }
            if ($oldHash -eq $newHash) { continue }
            if ($oldHash) {
                Copy-MaintenanceFile $target (Resolve-MaintenancePath $directory ('before\' + $change.path))
            }
            [pscustomobject]@{ path = $change.path; before = $oldHash; after = $newHash }
        }
    )
    $journal = [pscustomobject]@{ schemaVersion=1; root=[IO.Path]::GetFullPath($AppRoot); purpose=$Purpose; status='applying'; files=$records }
    $journalPath = Join-Path $directory 'transaction.json'
    Write-MaintenanceJson $journalPath $journal
    try {
        foreach ($record in $records) {
            $change = $changesByPath[$record.path]
            $target = Resolve-MaintenancePath $AppRoot $record.path
            if ($change.source) { Copy-MaintenanceFile $change.source $target }
            elseif (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Force }
        }
        $journal.status = 'committed'
        Write-MaintenanceJson $journalPath $journal
    } catch {
        $failure = $_
        Undo-TransactionFiles $AppRoot $directory $journal
        throw $failure
    }
    return [pscustomobject]@{ transactionId=$id; files=$records.Count; purpose=$Purpose }
}

function Undo-TransactionFiles([string]$AppRoot, [string]$Directory, $Journal) {
    if ($Journal.schemaVersion -ne 1 -or [IO.Path]::GetFullPath($AppRoot) -ine $Journal.root) { throw 'Transaction belongs to another installation.' }
    if ($Journal.status -eq 'rolled-back') { throw 'Transaction has already been rolled back.' }
    foreach ($record in $Journal.files) {
        $target = Resolve-MaintenancePath $AppRoot $record.path
        $hash = Get-MaintenanceHash $target
        if ($hash -ne $record.before -and $hash -ne $record.after) { throw "File changed after the transaction; rollback stopped: $($record.path)" }
        if ($record.before -and (Get-MaintenanceHash (Resolve-MaintenancePath $Directory ('before\' + $record.path))) -ne $record.before) {
            throw "Rollback snapshot is damaged: $($record.path)"
        }
    }
    foreach ($record in $Journal.files) {
        $target = Resolve-MaintenancePath $AppRoot $record.path
        if ((Get-MaintenanceHash $target) -eq $record.before) { continue }
        if ($record.before) { Copy-MaintenanceFile (Resolve-MaintenancePath $Directory ('before\' + $record.path)) $target }
        elseif (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Force }
    }
    $Journal.status = 'rolled-back'
    Write-MaintenanceJson (Join-Path $Directory 'transaction.json') $Journal
}

function Undo-TpmTransaction([string]$AppRoot, [string]$TransactionId) {
    if ($TransactionId -notmatch '^\d{8}-\d{6}-[a-f0-9]{8}$') { throw 'Invalid transaction ID.' }
    Invoke-MaintenanceLock $AppRoot {
        $directory = Resolve-MaintenancePath $AppRoot ("backups\transactions\$TransactionId")
        $journal = [IO.File]::ReadAllText((Join-Path $directory 'transaction.json')) | ConvertFrom-Json
        $safeSetupUndo=$journal.purpose -in @('use-setup','save-setup','build-profile')
        if($safeSetupUndo){
            foreach($record in $journal.files){
                $relative=$record.path.Replace('\','/')
                if($relative -notmatch '^(config/(config\.json|profiles/[a-z0-9_-]+\.json)|lists/(domains\.txt|user-(domains|ips)(-exclude)?\.txt)|state/(setups/[a-z0-9_-]+/(setup\.json|user-(domains|ips)(-exclude)?\.txt)|profile-recipes/[a-z0-9_-]+\.json|domain-packs\.json|enabled-game-filters\.txt|universal-game-transport\.json|selected-setup\.json))$'){
                    throw 'Unexpected path in a setup transaction.'
                }
            }
            Assert-TpmConfigurationStopped $AppRoot
        }else{Assert-MaintenanceStopped $AppRoot}
        Undo-TransactionFiles $AppRoot $directory $journal
        [pscustomobject]@{ transactionId=$TransactionId; status='rolled-back' }
    }
}

function Get-ZipIndex($Zip, [string]$Prefix = '') {
    $index = @{}
    $total = [int64]0
    foreach ($entry in $Zip.Entries) {
        if (-not $entry.Name) { continue }
        if (-not $entry.FullName.StartsWith($Prefix, [StringComparison]::Ordinal)) { throw 'Unexpected archive layout.' }
        $relative = $entry.FullName.Substring($Prefix.Length).Replace('\','/')
        [void](Resolve-MaintenancePath ([IO.Path]::GetTempPath()) $relative)
        if ($index.ContainsKey($relative)) { throw "Duplicate archive path: $relative" }
        $index[$relative] = $entry
        $total += $entry.Length
        if ($index.Count -gt 20000 -or $total -gt 536870912) { throw 'Archive exceeds the supported size.' }
    }
    return $index
}

function Read-ZipJson($Entry) {
    if (-not $Entry -or $Entry.Length -gt 4194304) { throw 'Archive metadata is missing or too large.' }
    $reader = [IO.StreamReader]::new($Entry.Open())
    try { return $reader.ReadToEnd() | ConvertFrom-Json -ErrorAction Stop } finally { $reader.Dispose() }
}

function Expand-ZipEntry($Entry, [string]$Path) {
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    $inputStream = $Entry.Open()
    try {
        $outputStream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew)
        try { $inputStream.CopyTo($outputStream) } finally { $outputStream.Dispose() }
    } finally { $inputStream.Dispose() }
}
