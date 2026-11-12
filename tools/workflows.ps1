[CmdletBinding()]
param(
    [ValidateSet('setup','configuration','build-profile')][string]$Command = 'setup',
    [string[]]$Arguments = @(),
    [string]$RootPath = '',
    [switch]$Interactive,
    [switch]$Json
)
$ErrorActionPreference = 'Stop'
$appRoot = if ($RootPath) { [IO.Path]::GetFullPath($RootPath) } else { Split-Path -Parent $PSScriptRoot }
$sourceRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $sourceRoot 'modules/TrafficProfileManager.Maintenance/TrafficProfileManager.Maintenance.psd1') -ErrorAction Stop
Import-Module (Join-Path $sourceRoot 'modules/TrafficProfileManager.Console/TrafficProfileManager.Console.psd1') -ErrorAction Stop
Import-Module (Join-Path $sourceRoot 'modules/TrafficProfileManager.Profile/TrafficProfileManager.Profile.psd1') -ErrorAction Stop
Set-TpmUiRoot $appRoot
$values = @($Arguments | Where-Object { $_ -ne '--json' })
if ($Arguments -contains '--json') { $Json = $true }

function Invoke-WorkflowServiceApply {
    if($appRoot.TrimEnd('\') -ine $sourceRoot.TrimEnd('\')){throw 'Apply service settings from the complete application folder; do not override ZAPRETCTL_HOME for this command.'}
    & (Join-Path $sourceRoot 'tools/service-control.ps1') apply
}
function Select-Setup {
    $setups = @(Get-TpmSetups $appRoot)
    for ($i=0; $i -lt $setups.Count; $i++) {
        $mark=if($setups[$i].lastSelected){' *'}else{''}
        Write-TpmUi ('[{0}] {1} ({2}){3}' -f ($i+1),(Get-TpmText $setups[$i].displayName),$setups[$i].id,$mark)
    }
    Write-TpmUi '[0] Back'
    $answer = Read-TpmUi 'Select a setup'; $number = 0
    if ([int]::TryParse($answer,[ref]$number) -and $number -ge 1 -and $number -le $setups.Count) { return $setups[$number-1] }
    return $null
}
function Show-ConfigurationChanges {
    $status = Get-TpmConfigurationStatus $appRoot
    Write-TpmStatus 'Configuration status' $status.status $(if ($status.status -eq 'applied') {'Success'} elseif ($status.status -eq 'stopped') {'Muted'} else {'Warning'})
    Write-TpmStatus 'Configured profile' $status.configuredProfile Info
    if ($status.appliedProfile) { Write-TpmStatus 'Applied profile' $status.appliedProfile Info }
    if($status.running -and $status.appliedProfile -and $status.configuredProfile -ne $status.appliedProfile){
        Write-TpmUi 'An explicitly selected profile is in use. Applying settings will select the configured profile.' -Tone Warning
    }
    foreach ($change in $status.changes) { Write-TpmUi ('  ' + $change.path) -Tone Warning }
    if ($status.status -eq 'unknown') { Write-TpmUi 'No trustworthy launch snapshot. Start the profile again to capture one.' -Tone Warning }
    return $status
}
function Select-BuilderProfile([object[]]$Profiles, [string]$Prompt, [switch]$AllowBase) {
    Write-TpmUi $Prompt -Tone Title
    for ($i=0; $i -lt $Profiles.Count; $i++) { Write-TpmUi ('[{0}] {1}' -f ($i+1),$Profiles[$i].DisplayName) }
    if ($AllowBase) { Write-TpmUi '[0] Keep the base strategy' } else { Write-TpmUi '[0] Cancel' }
    $answer = Read-TpmUi 'Select a profile'; $number=0
    if ([int]::TryParse($answer,[ref]$number) -and $number -ge 1 -and $number -le $Profiles.Count) { return $Profiles[$number-1].Id }
    return ''
}
function Show-ProfileBuilder {
    $profiles = @(Get-TrafficProfiles $appRoot)
    $base = Select-BuilderProfile $profiles 'Select a base profile'
    if (-not $base) { return }
    $recipe = [pscustomobject][ordered]@{schemaVersion=1;id=(Read-TpmUi 'New profile ID');displayName=(Read-TpmUi 'Display name');baseProfile=$base;httpProfile='';tlsProfile='';quicProfile=''}
    foreach ($kind in @('http','tls','quic')) {
        Show-TpmHeader -Title 'Profile constructor' -Clear
        $recipe.($kind+'Profile') = Select-BuilderProfile $profiles ('Choose ' + $kind.ToUpperInvariant() + ' strategy') -AllowBase
    }
    $profile = New-TpmBuiltProfile $appRoot $recipe
    Write-TpmUi 'Preview. Dedicated rules and matching stay with the base profile.' -Tone Info
    Write-TpmStatus 'Profile ID' $profile.name Info
    Write-TpmStatus 'Base profile' $recipe.baseProfile Info
    foreach($kind in @('http','tls','quic')){
        $id=$recipe.($kind+'Profile');if(-not $id){$id=$recipe.baseProfile}
        Write-TpmStatus ($kind.ToUpperInvariant()+' strategy') $id Info
    }
    Write-TpmUi 'Targets and exclusions are edited in lists or named setups.' -Tone Muted
    $answer=Read-TpmUi 'Type CREATE to validate and save, J to view JSON, or Enter to cancel'
    while($answer -ceq 'J'){
        Write-TpmUi ($profile|ConvertTo-Json -Depth 20)
        $answer=Read-TpmUi 'Type CREATE to validate and save, J to view JSON, or Enter to cancel'
    }
    if ($answer -ceq 'CREATE') {
        $result = Save-TpmBuiltProfile $appRoot $recipe
        Write-TpmUi ('Created: ' + $result.path) -Tone Success
    }
}
function Show-SetupMenu {
    Initialize-TpmSetups $appRoot
    while ($true) {
        Show-TpmHeader -Title 'Named setups and application' -Clear
        Write-TpmUi '[1] Save current settings as a new setup'
        Write-TpmUi '[2] Preview and select a setup'
        Write-TpmUi '[3] Save current settings to an existing setup'
        Write-TpmUi '[4] Edit setup JSON'
        Write-TpmUi '[5] Edit setup lists'
        Write-TpmUi '[6] Show pending changes'
        Write-TpmUi '[7] Apply configuration to the installed service'
        Write-TpmUi '[0] Back'
        $choice = Read-TpmUi 'Select an option'
        if ($choice -eq '0') { return }
        Show-TpmHeader -Title 'Named setups and application' -Clear
        try {
            if ($choice -eq '1') {
                $id=Read-TpmUi 'New setup ID'; $name=Read-TpmUi 'Display name'
                $result=Save-TpmSetup $appRoot $id $name
                Write-TpmUi ('Created: '+$result.path) -Tone Success
            } elseif ($choice -in @('2','3','4','5')) {
                $setup=Select-Setup
                if (-not $setup) { continue }
                if ($choice -eq '2') {
                    foreach ($row in @(Get-TpmSetupPlan $appRoot $setup.id)) { Write-TpmUi ($row.action+'  '+$row.path) }
                    Write-TpmUi 'Unsaved active edits stay in the current files until you apply this setup. Save them as a setup first.' -Tone Warning
                    if ((Read-TpmUi 'Type USE to apply the selected setup') -ceq 'USE') { $result=Use-TpmSetup $appRoot $setup.id; Write-TpmUi 'Setup selected. Start the profile or apply it to the service.' -Tone Success; Write-TpmUi ('Transaction: '+$result.transactionId) -Tone Muted }
                } elseif ($choice -eq '3') {
                    if ((Read-TpmUi 'Type SAVE to replace the saved setup with current settings') -ceq 'SAVE') { [void](Save-TpmSetup $appRoot $setup.id $setup.displayName -Overwrite); Write-TpmUi 'Setup saved.' -Tone Success }
                } elseif ($choice -eq '4') {
                    Start-Process -FilePath notepad.exe -ArgumentList @('"'+(Get-TpmSetupPath $appRoot $setup.id)+'"') -Wait
                } else {
                    $names=@('user-domains.txt','user-domains-exclude.txt','user-ips.txt','user-ips-exclude.txt')
                    for($i=0;$i -lt $names.Count;$i++){Write-TpmUi ('[{0}] {1}' -f ($i+1),$names[$i])}
                    $answer=Read-TpmUi 'Select a list'; $number=0
                    if([int]::TryParse($answer,[ref]$number) -and $number -ge 1 -and $number -le $names.Count){
                        $path=Join-Path (Split-Path -Parent (Get-TpmSetupPath $appRoot $setup.id)) $names[$number-1]
                        Start-Process -FilePath notepad.exe -ArgumentList @('"'+$path+'"') -Wait
                    }
                }
            } elseif ($choice -eq '6') { [void](Show-ConfigurationChanges) }
            elseif ($choice -eq '7') {
                [void](Show-ConfigurationChanges)
                if ((Read-TpmUi 'Type APPLY to update and restart the installed service') -ceq 'APPLY') { $applied=Invoke-WorkflowServiceApply; Write-TpmStatus 'Service profile' $applied.profile Success; Write-TpmUi ('Transaction: '+$applied.transactionId) -Tone Muted }
            }
        } catch { Write-TpmUi $_.Exception.Message -Tone Error }
        [void](Read-TpmUi 'Press Enter to continue')
    }
}
if ($Interactive) {
    if ($Command -eq 'build-profile') { Show-ProfileBuilder } else { Show-SetupMenu }
    return
}
$verb = if ($values.Count) {$values[0]} else {'list'}
$result = switch ($Command) {
    'setup' {
        if ($verb -in @('list','create','save','use','run')) { Initialize-TpmSetups $appRoot }
        switch ($verb) {
            'list' { Get-TpmSetups $appRoot }
            'create' { if ($values.Count -lt 2 -or $values.Count -gt 3) { throw 'Usage: setup create <id> [display-name]' }; Save-TpmSetup $appRoot $values[1] $(if($values.Count -eq 3){$values[2]}else{''}) }
            'save' { if ($values.Count -ne 2) { throw 'Usage: setup save <id>' }; Save-TpmSetup $appRoot $values[1] -Overwrite }
            'show' { if ($values.Count -ne 2) { throw 'Usage: setup show <id>' }; [IO.File]::ReadAllText((Get-TpmSetupPath $appRoot $values[1])) | ConvertFrom-Json }
            'preview' { if ($values.Count -ne 2) { throw 'Usage: setup preview <id>' }; Get-TpmSetupPlan $appRoot $values[1] }
            { $_ -in @('use','run') } {
                if ($values.Count -ne 2) { throw 'Usage: setup use|run <id>' }
                if ($verb -eq 'run' -and (Get-Service TrafficProfileService -ErrorAction SilentlyContinue)) { throw 'An automatic service is installed. Use setup use, then configuration apply, or remove the service before a visible launch.' }
                Use-TpmSetup $appRoot $values[1]
                if ($verb -eq 'run') {
                    $profile=([IO.File]::ReadAllText((Get-TpmSetupPath $appRoot $values[1]))|ConvertFrom-Json).profile
                    Import-Module (Join-Path $sourceRoot 'modules/TrafficProfileManager.Controller/TrafficProfileManager.Controller.psd1') -ErrorAction Stop
                    Invoke-TpmControllerCommand -AppRoot $appRoot -Command foreground -CommandArgs @($profile)
                }
            }
            default { throw 'Usage: setup list|create|save|show|preview|use|run [id]' }
        }
    }
    'configuration' {
        if ($verb -in @('list','status')) { if ($Json) { Get-TpmConfigurationStatus $appRoot } else { [void](Show-ConfigurationChanges) } }
        elseif ($verb -eq 'apply' -and $values.Count -eq 1) { $applied=Invoke-WorkflowServiceApply; Write-TpmStatus 'Service profile' $applied.profile Success; Write-TpmUi ('Transaction: '+$applied.transactionId) -Tone Muted }
        else { throw 'Usage: configuration status|apply' }
    }
    'build-profile' {
        if ($values.Count -ne 2 -or $verb -notin @('preview','create')) { throw 'Usage: build-profile preview|create <recipe.json>' }
        $recipe=[IO.File]::ReadAllText([IO.Path]::GetFullPath($values[1]))|ConvertFrom-Json
        if ($verb -eq 'preview') { New-TpmBuiltProfile $appRoot $recipe } else { Save-TpmBuiltProfile $appRoot $recipe }
    }
}
if ($Json) { ConvertTo-Json -InputObject @($result) -Depth 25 } else { $result }
