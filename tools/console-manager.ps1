[CmdletBinding()]
param([string]$RootPath = '')
$ErrorActionPreference = 'Stop'
$appRoot = if ($RootPath) { [IO.Path]::GetFullPath($RootPath) } else { Split-Path -Parent $PSScriptRoot }
Import-Module (Join-Path $appRoot 'modules\TrafficProfileManager.Core\TrafficProfileManager.Core.psd1') -ErrorAction Stop
Import-Module (Join-Path $appRoot 'modules\TrafficProfileManager.Console\TrafficProfileManager.Console.psd1') -ErrorAction Stop
Import-Module (Join-Path $appRoot 'modules\TrafficProfileManager.Maintenance\TrafficProfileManager.Maintenance.psd1') -ErrorAction Stop
Set-TpmUiRoot $appRoot
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

$script:CurrentTitle = 'Traffic Profile Manager'
$script:SkipPause = $false
function Read-MenuChoice([string]$Prompt) {
    $answer = Read-TpmUi $Prompt
    Show-TpmHeader -Title $script:CurrentTitle -Clear
    return $answer
}
function Show-Options([string[]]$Items, [switch]$RootMenu) {
    $sections = @{
        0 = 'Launch and service'
        4 = 'Lists, checks and background tasks'
        9 = 'Profiles, filters and applications'
        15 = 'Settings and maintenance'
    }
    for ($index=0; $index -lt $Items.Count; $index++) {
        if ($RootMenu -and $sections.ContainsKey($index)) {
            Write-TpmUi ('  --- ' + (Get-TpmText $sections[$index]) + ' ---') -Tone Title
        }
        Write-TpmUi ('[{0,2}] ' -f ($index+1)) -Tone Title -NoNewline
        Write-TpmUi $Items[$index] -Tone Info
    }
    if ($RootMenu) {
        Write-TpmUi ''
        Write-TpmUi '[0] Exit' -Tone Muted
    } else { Write-TpmUi '[0] Back' }
}
function Invoke-ManagerTool([string]$Name, [object[]]$Parameters = @()) {
    & (Join-Path (Join-Path $appRoot 'tools') $Name) @Parameters
}
function Show-FilePlan($Plan) {
    foreach ($row in $Plan) {
        $tone = switch ($row.action) { 'preserve' {'Success'}; 'create' {'Success'}; 'delete' {'Error'}; default {'Warning'} }
        Write-TpmUi ('  {0,-14} {1}' -f (Get-TpmText $row.action),$row.path) -Tone $tone
    }
}
function Show-Operation($Result) {
    if ($Result.archive) { Write-TpmUi ('Saved: ' + $Result.archive) -Tone Success }
    if ($Result.sha256) { Write-TpmUi ('SHA-256: ' + $Result.sha256) }
    if ($Result.transactionId) { Write-TpmUi ('Transaction: ' + $Result.transactionId) -Tone Success }
    if ($Result.settingsBackup) { Write-TpmUi ('Settings backup: ' + $Result.settingsBackup) -Tone Success }
}
function Select-BackupArchive {
    Write-TpmUi 'Choose an existing backup ZIP to restore.' -Tone Info
    Write-TpmUi 'Select a saved backup below, or paste the path to another backup.' -Tone Muted
    $files = @(Get-ChildItem -LiteralPath (Join-Path $appRoot 'backups') -Filter '*.zip' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending)
    if (-not $files.Count) { Write-TpmUi 'No saved backups. Create a backup first, or enter the path to an existing one.' -Tone Warning }
    for ($index=0; $index -lt $files.Count; $index++) {
        Write-TpmUi ('[{0}] {1}  ({2})' -f ($index+1),$files[$index].Name,$files[$index].LastWriteTime.ToString('yyyy-MM-dd HH:mm'))
    }
    while ($true) {
        $answer = Read-TpmUi 'Backup number or archive path (Enter/0 to cancel)'
        if ([string]::IsNullOrWhiteSpace($answer) -or $answer.Trim() -eq '0') { return $null }
        $number=0
        if ([int]::TryParse($answer.Trim(),[ref]$number)) {
            if ($number -lt 1 -or $number -gt $files.Count) { Write-TpmUi 'Unknown backup number.' -Tone Warning; continue }
            $answer=$files[$number-1].FullName
        }
        try { return Resolve-TpmArchivePath $answer }
        catch { Write-TpmUi $_.Exception.Message -Tone Error }
    }
}
function Show-BackupMenu {
    Show-Options @('Create a backup','Preview or restore a backup')
    $choice = Read-MenuChoice 'Select an option'
    if ($choice -eq '0') { $script:SkipPause = $true; return }
    if ($choice -eq '1') { Show-Operation (New-TpmUserBackup $appRoot) }
    elseif ($choice -eq '2') {
        $archive = Select-BackupArchive
        if (-not $archive) { $script:SkipPause = $true; return }
        Show-FilePlan @(Get-TpmRestorePlan $appRoot $archive)
        if ((Read-TpmUi 'Type RESTORE to replace the listed files') -ceq 'RESTORE') {
            Show-Operation (Restore-TpmUserBackup $appRoot $archive)
        }
    }
}
function Show-UpdateMenu {
    Show-Options @('Check for updates','Download the latest release','Preview and apply a local update','Roll back a transaction')
    $choice = Read-MenuChoice 'Select an option'
    if ($choice -eq '0') { $script:SkipPause = $true; return $false }
    switch ($choice) {
        '1' {
            $release = Get-TpmLatestRelease
            $current = (Get-TpmBuildInfo $appRoot).version
            Write-TpmUi ((Get-TpmText 'Current version') + ': ' + $current)
            Write-TpmUi ((Get-TpmText 'Latest version') + ': ' + $release.version)
            if ($current -match '^\d+\.\d+\.\d+$' -and $release.version -match '^\d+\.\d+\.\d+$' -and [version]$release.version -le [version]$current) {
                Write-TpmUi 'No newer release is available.'
            }
            $release | Format-List | Out-Host
        }
        '2' { Show-Operation (Save-TpmLatestRelease $appRoot) }
        '3' {
            $archive = Read-TpmUi 'Archive path'
            $hash = Read-TpmUi 'SHA-256'
            Show-FilePlan @(Get-TpmUpdatePlan $appRoot $archive $hash)
            if ((Read-TpmUi 'Type UPDATE to apply this update') -ceq 'UPDATE') {
                Show-Operation (Install-TpmUpdate $appRoot $archive $hash)
                Write-TpmUi 'Restart Manager.bat to load the updated files.'
                return $true
            }
        }
        '4' {
            $id = Read-TpmUi 'Transaction ID'
            if ((Read-TpmUi 'Type ROLLBACK to revert this transaction') -ceq 'ROLLBACK') {
                Show-Operation (Undo-TpmTransaction $appRoot $id)
                Write-TpmUi 'Restart Manager.bat to load the updated files.'
                return $true
            }
        }
    }
    return $false
}
function Show-ResultsMenu {
    $reports = @(Get-TpmComparisonResults $appRoot)
    if (-not $reports.Count) { Write-TpmUi 'No saved comparison results.'; return }
    for ($index=0; $index -lt $reports.Count; $index++) { Write-TpmUi ('[' + ($index+1) + '] ' + $reports[$index].createdAt + '  ' + $reports[$index].file) }
    $number = 0
    if (-not [int]::TryParse((Read-MenuChoice 'Select a result number to view it'), [ref]$number) -or $number -lt 1 -or $number -gt $reports.Count) { return }
    $report = $reports[$number-1]
    $report.ranking | Format-Table -AutoSize | Out-Host
    $id = Read-TpmUi 'Profile ID'
    if ($id -notin $report.ranking.profileId) { return }
    if ((Read-TpmUi 'Type APPLY to select this profile') -ceq 'APPLY') {
        Set-TpmComparisonProfile $appRoot $id
        Write-TpmUi 'Profile selected. Restart the active profile to apply it.' -Tone Success
    }
}
function Show-BackgroundMenu {
    $actions = @('start','stop','task-on','task-off','refresh','cleanup')
    Show-Options @('Start the installed service now','Stop the service for this Windows session','Turn startup mapping refresh ON','Turn startup mapping refresh OFF and remove its task','Refresh temporary mappings now','Clean temporary mappings while stopped')
    $choice = 0
    $answer = Read-MenuChoice 'Select an option'
    if ($answer -eq '0') { $script:SkipPause = $true; return }
    if ([int]::TryParse($answer, [ref]$choice) -and $choice -ge 1 -and $choice -le $actions.Count) {
        Invoke-ManagerTool 'service-control.ps1' @($actions[$choice-1])
    }
}
function Show-ListMenu([bool]$Exclude) {
    $labels = if ($Exclude) { @('Custom domain exclusions','Custom IP/CIDR exclusions') } else { @('Custom domains','Custom IP addresses and CIDR ranges') }
    Show-Options $labels
    $choice = Read-MenuChoice 'Select a list'
    if ($choice -eq '0') { $script:SkipPause = $true; return }
    $suffix = if ($Exclude) { '-exclude' } else { '' }
    $file = if ($choice -eq '1') { "user-domains$suffix.txt" } elseif ($choice -eq '2') { "user-ips$suffix.txt" } else { return }
    Start-Process -FilePath notepad.exe -ArgumentList @('"' + (Join-Path $appRoot "lists\$file") + '"')
}

$items = @('Run a profile in a visible window','Install a profile as an automatic service','Remove the automatic service','Show status','Edit custom target lists','Edit custom exclusion lists','Test and compare profiles','Validate profile files','Background component controls','Edit a traffic profile','Create a custom profile','Open the profile folder','Game filters','Domain packs','Application diagnostics','Language','Backup and restore','Update and rollback','Saved comparison results','Named setups and application')
:manager while ($true) {
    $script:CurrentTitle = 'Traffic Profile Manager'
    Show-TpmHeader -Compact -Subtitle (Get-TpmText ('Language: ' + (Get-TpmLanguage $appRoot))) -Clear
    Show-Options $items -RootMenu
    $choice = Read-TpmUi 'Select an option'
    if ($choice -eq '0') { Clear-TpmScreen; break }
    $number = 0
    if (-not [int]::TryParse($choice,[ref]$number) -or $number -lt 1 -or $number -gt $items.Count) { continue }
    $choice = [string]$number
    $script:CurrentTitle = $items[$number-1]
    $script:SkipPause = $false
    Show-TpmHeader -Title $script:CurrentTitle -Clear
    try {
        switch ($choice) {
            '1' { Invoke-ManagerTool 'profile-manager.ps1' @('run') }
            '2' { Invoke-ManagerTool 'profile-manager.ps1' @('install') }
            '3' { Invoke-ManagerTool 'service-control.ps1' @('remove') }
            '4' { Invoke-ManagerTool 'maintenance.ps1' @('overview'); Invoke-ManagerTool 'service-control.ps1' @('status'); & (Join-Path $appRoot 'tools/workflows.ps1') -Command configuration }
            '5' { Show-ListMenu $false }
            '6' { Show-ListMenu $true }
            '7' { Invoke-ManagerTool 'profile-benchmark.ps1' }
            '8' { & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $appRoot 'tools\validate-profiles.ps1') }
            '9' { Show-BackgroundMenu }
            '10' { Invoke-ManagerTool 'profile-manager.ps1' @('edit') }
            '11' { Show-Options @('Build a profile step by step','Copy a profile and edit JSON'); $createChoice=Read-MenuChoice 'Select an option'; if($createChoice -eq '1'){& (Join-Path $appRoot 'tools/workflows.ps1') -Command build-profile -Interactive} elseif($createChoice -eq '2'){Invoke-ManagerTool 'profile-manager.ps1' @('create')} else{$script:SkipPause=$true} }
            '12' { Start-Process -FilePath explorer.exe -ArgumentList @('"' + (Join-Path $appRoot 'config\profiles') + '"') }
            '13' { Invoke-ManagerTool 'game-filter-manager.ps1' @('manage'); $script:SkipPause = $true }
            '14' { Invoke-ManagerTool 'domain-pack-manager.ps1' @('manage'); $script:SkipPause = $true }
            '15' { Invoke-ManagerTool 'maintenance.ps1' @('advice'); & (Join-Path $appRoot 'tools\application-diagnostics.ps1') -Interactive }
            '16' {
                Write-TpmUi '[1] English (default)'
                Write-TpmUi '[2] Russian'
                Write-TpmUi '[0] Back'
                $language = Read-MenuChoice 'Select an option'
                if ($language -eq '1') { Set-TpmLanguage -Language en -AppRoot $appRoot }
                elseif ($language -eq '2') { Set-TpmLanguage -Language ru -AppRoot $appRoot }
                if ($language -in @('1','2')) { Write-TpmUi 'Language saved.' -Tone Success } else { $script:SkipPause = $true }
            }
            '17' { Show-BackupMenu }
            '18' { if (Show-UpdateMenu) { break manager } }
            '19' { Show-ResultsMenu }
            '20' { & (Join-Path $appRoot 'tools/workflows.ps1') -Command setup -Interactive; $script:SkipPause=$true }
        }
    } catch { Write-TpmUi (Get-TpmText $_.Exception.Message) -ForegroundColor Red }
    if (-not $script:SkipPause) { [void](Read-TpmUi 'Press Enter to continue') }
}
