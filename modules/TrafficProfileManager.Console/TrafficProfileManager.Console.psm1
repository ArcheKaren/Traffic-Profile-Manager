$script:UiRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$script:Russian = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'ru.json')) | ConvertFrom-Json

$script:LanguageState = $null
$script:Palette = @{ Info='Gray'; Success='Green'; Warning='DarkYellow'; Error='Red'; Muted='DarkGray'; Title='Cyan' }
$script:Translations = @(
    foreach ($item in $script:Russian.PSObject.Properties) {
        if ($item.Name -notmatch '\{\d+\}') { continue }
        $pattern = [regex]::Escape($item.Name)
        foreach ($placeholder in [regex]::Matches($item.Name, '\{(\d+)\}')) {
            $pattern = $pattern.Replace([regex]::Escape($placeholder.Value), '(?<p' + $placeholder.Groups[1].Value + '>.*?)')
        }
        [pscustomobject]@{
            Pattern = [regex]::new('^' + $pattern + '$', [Text.RegularExpressions.RegexOptions]::CultureInvariant)
            Text = [string]$item.Value
        }
    }
)
function Set-TpmUiRoot([string]$AppRoot) {
    $script:UiRoot = [IO.Path]::GetFullPath($AppRoot)
    $script:LanguageState = $null
}

function Get-TpmLanguage {
    param([string]$AppRoot = $script:UiRoot)
    $path = Join-Path $AppRoot 'state\user-settings.json'
    try {
        $file = [IO.FileInfo]::new($path)
        if (-not $file.Exists) { $script:LanguageState = $null; return 'en' }
        $cached = $script:LanguageState
        if ($cached -and $cached.Path -eq $file.FullName -and
            $cached.WriteTicks -eq $file.LastWriteTimeUtc.Ticks -and $cached.Length -eq $file.Length) {
            return $cached.Language
        }
        $settings = [IO.File]::ReadAllText($path) | ConvertFrom-Json -ErrorAction Stop
        $language = if ($settings.language -in @('en','ru')) { [string]$settings.language } else { 'en' }
        $script:LanguageState = [pscustomobject]@{
            Path=$file.FullName; WriteTicks=$file.LastWriteTimeUtc.Ticks; Length=$file.Length; Language=$language
        }
        return $language
    } catch {
        $script:LanguageState = $null
        return 'en'
    }
}

function Set-TpmLanguage {
    param([ValidateSet('en','ru')][string]$Language, [string]$AppRoot = $script:UiRoot)
    $path = Join-Path $AppRoot 'state\user-settings.json'
    $settings = if (Test-Path -LiteralPath $path -PathType Leaf) {
        [IO.File]::ReadAllText($path) | ConvertFrom-Json -ErrorAction Stop
    } else { [pscustomobject]@{ schemaVersion = 1 } }
    $settings | Add-Member -NotePropertyName language -NotePropertyValue $Language -Force
    New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
    $temporary = "$path.$([Guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($temporary, ($settings | ConvertTo-Json -Depth 10) + "`r`n", [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporary -Destination $path -Force
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
    Set-TpmUiRoot $AppRoot
}

function Get-TpmText {
    param([AllowEmptyString()][string]$Text, [object[]]$Values = @())
    $translated = $Text
    if ((Get-TpmLanguage) -eq 'ru' -and $Text) {
        $key = $Text.Trim()
        $property = $script:Russian.PSObject.Properties[$key]
        if ($property) {
            $translated = [string]$property.Value
        } else {
            foreach ($item in $script:Translations) {
                $translationMatch = $item.Pattern.Match($key)
                if (-not $translationMatch.Success) { continue }
                $translated = [regex]::Replace($item.Text, '\{(\d+)\}', {
                    param($placeholder)
                    $translationMatch.Groups['p' + $placeholder.Groups[1].Value].Value
                })
                break
            }
        }
        if ($translated -ne $Text -and $Text -match '^\s+') {
            $translated = [regex]::Match($Text, '^\s+').Value + $translated
        }
    }
    if ($Values.Count) { return $translated -f $Values }
    return $translated
}

function Write-TpmUi {
    [CmdletBinding()]
    param(
        [Parameter(Position=0,ValueFromRemainingArguments=$true)][object[]]$Object,
        [ConsoleColor]$ForegroundColor,
        [ConsoleColor]$BackgroundColor,
        [ValidateSet('Info','Success','Warning','Error','Muted','Title')][string]$Tone = 'Info',
        [switch]$NoNewline,
        [object]$Separator = ' '
    )
    $text = Get-TpmText ($Object -join $Separator)
    $parameters = @{ Object = $text; NoNewline = $NoNewline }
    if ($PSBoundParameters.ContainsKey('Tone')) { $parameters.ForegroundColor = [ConsoleColor]$script:Palette[$Tone] }
    if ($PSBoundParameters.ContainsKey('ForegroundColor')) { $parameters.ForegroundColor = $ForegroundColor }
    if ($PSBoundParameters.ContainsKey('BackgroundColor')) { $parameters.BackgroundColor = $BackgroundColor }
    $warning = $Tone -eq 'Warning' -or ($PSBoundParameters.ContainsKey('ForegroundColor') -and $ForegroundColor -in @('Yellow','DarkYellow'))
    if ($warning -and (Test-TpmTrueColor)) {
        $escape = [string][char]27
        $parameters.Object = "$escape[38;2;255;165;0m$text$escape[0m"
        $parameters.Remove('ForegroundColor')
    }
    Microsoft.PowerShell.Utility\Write-Host @parameters
}

function Test-TpmTrueColor {
    try { return -not [Console]::IsOutputRedirected -and [bool]$Host.UI.SupportsVirtualTerminal -and -not $env:NO_COLOR }
    catch { return $false }
}

function Clear-TpmScreen {
    try {
        if ([Console]::IsOutputRedirected) { return }
        [Console]::Clear()
    } catch { Clear-Host }
}

function Show-TpmHeader {
    param([string]$Title = 'Traffic Profile Manager', [string]$Subtitle = '', [switch]$Clear, [switch]$Compact)
    if ($Clear) { Clear-TpmScreen }
    $width = 72
    try { if (-not [Console]::IsOutputRedirected) { $width = [Math]::Max(40,[Math]::Min(76,[Console]::WindowWidth-2)) } } catch {}
    if ($Compact) {
        Write-TpmUi '  TRAFFIC PROFILE MANAGER' -Tone Title
        if ($Subtitle) { Write-TpmUi ('  ' + $Subtitle) -Tone Muted }
        Write-TpmUi ('  ' + ('-' * ($width-2))) -Tone Muted
        return
    }
    Write-TpmUi ''
    Write-TpmUi ('  ' + ('=' * ($width-2))) -Tone Muted
    Write-TpmUi '  TRAFFIC PROFILE MANAGER' -Tone Title
    if ($Title -ne 'Traffic Profile Manager') { Write-TpmUi ('  ' + (Get-TpmText $Title)) -Tone Info }
    if ($Subtitle) { Write-TpmUi ('  ' + $Subtitle) -Tone Muted }
    Write-TpmUi ('  ' + ('-' * ($width-2))) -Tone Muted
    Write-TpmUi ''
}

function Write-TpmStatus {
    param([string]$Label, [string]$Value, [ValidateSet('Info','Success','Warning','Error','Muted')][string]$Tone = 'Info')
    $mark = switch ($Tone) { 'Success' {'+'}; 'Warning' {'!'}; 'Error' {'x'}; default {'-'} }
    Write-TpmUi ('  [' + $mark + '] ' + (Get-TpmText $Label) + ': ' + (Get-TpmText $Value)) -Tone $Tone
}

function Show-TpmProfileSession {
    param([string]$ProfileId, [string]$LogPath, [string]$ErrorPath,
        [ValidateSet('Starting','Running','Stopped','Failed')][string]$State = 'Starting',
        [string]$MappingNotice = '', [switch]$MappingFailed)
    Show-TpmHeader -Title 'Profile session' -Clear
    $display = $ProfileId
    try {
        if ($ProfileId -match '^[A-Za-z0-9_-]{1,64}$') {
            $profile = [IO.File]::ReadAllText((Join-Path $script:UiRoot "config\profiles\$ProfileId.json")) | ConvertFrom-Json
            if ($profile.displayName) { $display = [string]$profile.displayName }
        }
    } catch {}
    Write-TpmStatus 'Profile' $display Info
    if ($display -ne $ProfileId) { Write-TpmStatus 'Profile ID' $ProfileId Muted }
    $tone = switch ($State) { 'Running' {'Success'}; 'Failed' {'Error'}; 'Starting' {'Warning'}; default {'Muted'} }
    Write-TpmStatus 'State' $State $tone
    if ($MappingNotice) {
        Write-TpmUi ('  ' + (Get-TpmText $MappingNotice)) -Tone $(if ($MappingFailed) { 'Warning' } else { 'Success' })
    }
    Write-TpmUi ''
    if ($State -in @('Starting','Running')) {
        Write-TpmUi '  Press Ctrl+C or close the window to stop it.' -Tone Warning
    } else {
        Write-TpmUi '  Profile stopped. Review the logs if needed.' -Tone Muted
    }
    Write-TpmUi '  Runtime output is saved to the log files below.' -Tone Muted
    foreach ($item in @(@('Output log',$LogPath),@('Error log',$ErrorPath))) {
        if (-not $item[1]) { continue }
        $path = [string]$item[1]
        $root = [IO.Path]::GetFullPath($script:UiRoot).TrimEnd('\') + '\'
        if ($path.StartsWith($root,[StringComparison]::OrdinalIgnoreCase)) { $path = $path.Substring($root.Length) }
        Write-TpmUi ('  ' + (Get-TpmText $item[0]) + ': ' + $path) -Tone Muted
    }
    Write-TpmUi ''
}

function Read-TpmUi {
    param([string]$Prompt)
    Microsoft.PowerShell.Utility\Read-Host (Get-TpmText $Prompt)
}

function Write-TpmProfileLogTail([string[]]$Paths) {
    foreach ($path in $Paths) {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            foreach ($line in @(Get-Content -LiteralPath $path -Tail 12 -ErrorAction SilentlyContinue)) {
                Write-TpmUi $line -Tone Error
            }
        }
    }
}

Export-ModuleMember -Function @('Set-TpmUiRoot','Get-TpmLanguage','Set-TpmLanguage','Get-TpmText','Write-TpmUi','Read-TpmUi','Clear-TpmScreen','Show-TpmHeader','Write-TpmStatus','Show-TpmProfileSession','Write-TpmProfileLogTail')
