#Requires -Version 5.1
[CmdletBinding()]
param([string]$OutputPath = '', [string]$PreviewPath = '')

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
if ($PSVersionTable.PSEdition -ne 'Desktop') { throw 'Use Windows PowerShell 5.1 to render the documentation GIF.' }
Add-Type -AssemblyName System.Drawing, PresentationCore
Import-Module (Join-Path $projectRoot 'modules/TrafficProfileManager.Core/TrafficProfileManager.Core.psd1') -Force
Import-Module (Join-Path $projectRoot 'modules/TrafficProfileManager.Runtime/TrafficProfileManager.Runtime.psd1') -Force
if (-not $OutputPath) { $OutputPath = Join-Path $projectRoot 'docs/media/manager-demo.gif' }
$OutputPath = [IO.Path]::GetFullPath($OutputPath)
$fixture = Join-Path $projectRoot ('tests/.tmp-demo-' + [Guid]::NewGuid().ToString('N'))
$allowedRoot = [IO.Path]::GetFullPath((Join-Path $projectRoot 'tests')).TrimEnd('\') + '\'
if (-not [IO.Path]::GetFullPath($fixture).StartsWith($allowedRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe demo fixture path.' }

function Invoke-DemoConsole([string]$File, [string[]]$Arguments, [string[]]$Answers = @()) {
    $info = New-TpmProcessStartInfo -FilePath 'powershell.exe' -CreateNoWindow -RedirectStandardOutput -RedirectStandardError -ArgumentList (@('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$File) + $Arguments)
    $info.RedirectStandardInput = $true
    $info.StandardOutputEncoding = [Text.Encoding]::UTF8
    $info.EnvironmentVariables['ZAPRETCTL_HOME'] = $fixture
    $encoding = [Console]::InputEncoding
    try {
        [Console]::InputEncoding = [Text.UTF8Encoding]::new($false)
        $process = [Diagnostics.Process]::Start($info)
    } finally { [Console]::InputEncoding = $encoding }
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        foreach ($answer in $Answers) { $process.StandardInput.WriteLine($answer) }
        $process.StandardInput.Close()
        if (-not $process.WaitForExit(45000)) { $process.Kill(); throw 'Demo capture timed out.' }
        $output = $stdout.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { throw ("Demo capture failed: " + $output + $stderr.GetAwaiter().GetResult()) }
        return $output
    } finally { $process.Dispose() }
}

function Get-DemoLines([string]$Text) {
    $cygwinPath = '/cygdrive/' + $fixture.Substring(0,1).ToLowerInvariant() + $fixture.Substring(2).Replace('\','/')
    foreach ($privatePath in @($fixture,$cygwinPath)) {
        $Text = [regex]::Replace($Text, [regex]::Escape($privatePath), '<demo>', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    }
    return @($Text.Trim() -split '\r?\n' | Where-Object { $_ -notmatch '^\s*(0|1|19)\s*$' } | ForEach-Object { $_.TrimEnd() })
}

try {
    New-Item -ItemType Directory -Path $fixture | Out-Null
    foreach ($directory in @('modules','tools','config','lists','assets')) {
        Copy-Item -LiteralPath (Join-Path $projectRoot $directory) -Destination $fixture -Recurse
    }
    foreach ($directory in @('state','test-results','metadata','runtime')) { New-Item -ItemType Directory -Path (Join-Path $fixture $directory) -Force | Out-Null }
    Copy-Item -LiteralPath (Join-Path $projectRoot 'metadata/VERSION') -Destination (Join-Path $fixture 'metadata/VERSION')
    [IO.File]::WriteAllText((Join-Path $fixture 'state/user-settings.json'), '{"language":"en"}')
    $sample = 'profile-comparison-20260728-125142.csv'
    Copy-Item -LiteralPath (Join-Path $projectRoot ('docs/media/' + $sample)) -Destination (Join-Path $fixture ('test-results/' + $sample))
    $manifestPath = Join-Path $projectRoot 'runtime/SOURCE.json'
    Copy-Item -LiteralPath $manifestPath -Destination (Join-Path $fixture 'runtime/SOURCE.json')
    $manifest = [IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json
    foreach ($entry in $manifest.runtimeFiles.PSObject.Properties.Value) {
        $target = Join-Path (Join-Path $fixture 'runtime') $entry.path
        New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
        $source = Get-TpmVerifiedRuntimeFile -RuntimeRoot (Join-Path $projectRoot 'runtime') -Entry $entry -Layout Source
        Copy-Item -LiteralPath $source -Destination $target
    }
    # Keep the runtime DLL next to the executable in this isolated fixture.
    $executableDirectory = Split-Path -Parent (Join-Path (Join-Path $fixture 'runtime') $manifest.runtimeFiles.winws2.path)
    Copy-Item -LiteralPath (Join-Path (Join-Path $fixture 'runtime') $manifest.runtimeFiles.cygwin.path) -Destination (Join-Path $executableDirectory 'cygwin1.dll')
    # Capture the real UI while replacing only the terminal-clear boundary in a test copy.
    $modulePath = Join-Path $fixture 'modules/TrafficProfileManager.Console/TrafficProfileManager.Console.psm1'
    $text = [IO.File]::ReadAllText($modulePath)
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$errors)
    $clear = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Clear-TpmScreen' }, $true)
    if (-not $clear) { throw 'Console clear boundary was not found.' }
    $text = $text.Remove($clear.Body.Extent.StartOffset, $clear.Body.Extent.EndOffset - $clear.Body.Extent.StartOffset).Insert($clear.Body.Extent.StartOffset, '{ Write-Host "__TPM_DEMO_SCREEN__" }')
    [IO.File]::WriteAllText($modulePath, $text, [Text.UTF8Encoding]::new($false))
    $recording = Invoke-DemoConsole (Join-Path $fixture 'tools/console-manager.ps1') @() @('1','0','','19','1','','','0')
    $screens = @($recording -split '__TPM_DEMO_SCREEN__')
    $menu = @($screens | Where-Object { $_ -match '\[19\] Saved comparison results' }) | Select-Object -First 1
    $picker = @($screens | Where-Object { $_ -match '\[1\] Base' -and $_ -match 'Run a traffic profile' }) | Select-Object -First 1
    $ranking = @($screens | Where-Object { $_ -match 'profileId\s+profile\s+passed\s+total\s+score' }) | Select-Object -First 1
    $check = Invoke-DemoConsole (Join-Path $projectRoot 'zapretctl.ps1') @('check','strategy-wa-pc-pos1')
    if (-not $menu -or -not $picker -or -not $ranking -or $check -notmatch 'command line parameters verified') { throw 'Required real console output was not captured.' }
    $scenes = @(
        @{Title='01 / Explore the manager'; Note='Actual console output | English and Russian interfaces'; Text=$menu; Delay=600}
        @{Title='02 / Choose a profile'; Note='14 bundled profiles | Custom JSON profiles are discovered automatically'; Text=$picker; Delay=600}
        @{Title='03 / Validate profile arguments'; Note='Real winws2 --dry-run | No active traffic profile is started'; Text=$check; Delay=500}
        @{Title='04 / Review a saved comparison'; Note='Local run: 28 July 2026 | Results depend on the connection and target pool'; Text=$ranking; Delay=800}
    )
    $encoder = [Windows.Media.Imaging.GifBitmapEncoder]::new()
    $width = 1080; $height = 920
    $font = [Drawing.Font]::new('Consolas',16,[Drawing.FontStyle]::Regular,[Drawing.GraphicsUnit]::Pixel)
    $titleFont = [Drawing.Font]::new('Segoe UI',23,[Drawing.FontStyle]::Bold,[Drawing.GraphicsUnit]::Pixel)
    $noteFont = [Drawing.Font]::new('Segoe UI',15,[Drawing.FontStyle]::Regular,[Drawing.GraphicsUnit]::Pixel)
    $brushes = @{Text=[Drawing.SolidBrush]::new([Drawing.ColorTranslator]::FromHtml('#d4d8de'));Title=[Drawing.SolidBrush]::new([Drawing.ColorTranslator]::FromHtml('#70d6ec'));Muted=[Drawing.SolidBrush]::new([Drawing.ColorTranslator]::FromHtml('#a3adba'));Success=[Drawing.SolidBrush]::new([Drawing.ColorTranslator]::FromHtml('#56d38b'));Line=[Drawing.SolidBrush]::new([Drawing.ColorTranslator]::FromHtml('#283341'))}
    try {
        for ($sceneIndex=0; $sceneIndex -lt $scenes.Count; $sceneIndex++) {
            $scene = $scenes[$sceneIndex]
            $lines = @(Get-DemoLines $scene.Text)
            if ($lines.Count -gt 40) { throw ('Demo scene exceeds the viewport: ' + $scene.Title) }
            $bitmap = [Drawing.Bitmap]::new($width,$height)
            $graphics = [Drawing.Graphics]::FromImage($bitmap)
            $memory = [IO.MemoryStream]::new()
            try {
                $graphics.Clear([Drawing.ColorTranslator]::FromHtml('#10151d'))
                $graphics.TextRenderingHint = [Drawing.Text.TextRenderingHint]::AntiAliasGridFit
                $graphics.DrawString('TRAFFIC PROFILE MANAGER', $noteFont, $brushes.Muted, [Drawing.PointF]::new(24,16))
                $graphics.DrawString($scene.Title, $titleFont, $brushes.Title, [Drawing.PointF]::new(24,42))
                $graphics.FillRectangle($brushes.Line,24,88,$width-48,1)
                for ($index=0; $index -lt $lines.Count; $index++) {
                    $line = $lines[$index]
                    $brush = if ($line -match 'TRAFFIC PROFILE MANAGER|--- .+ ---|^profileId\s') { $brushes.Title } elseif ($line -match 'parameters verified|confirmed the parameters') { $brushes.Success } elseif ($line -match '^\s*[-=]{4,}|^\s*strategy-|^Loading |^loading ') { $brushes.Muted } else { $brushes.Text }
                    $graphics.DrawString($line,$font,$brush,[Drawing.PointF]::new(24,(104+$index*19)))
                }
                $graphics.DrawString($scene.Note, $noteFont, $brushes.Muted, [Drawing.PointF]::new(24,$height-47))
                $graphics.FillRectangle($brushes.Title,24,$height-17,[int](($width-48)*($sceneIndex+1)/$scenes.Count),3)
                if ($PreviewPath -and $sceneIndex -eq 0) { $bitmap.Save([IO.Path]::GetFullPath($PreviewPath),[Drawing.Imaging.ImageFormat]::Png) }
                $bitmap.Save($memory,[Drawing.Imaging.ImageFormat]::Png)
                $memory.Position=0
                $decoded = [Windows.Media.Imaging.BitmapFrame]::Create($memory,[Windows.Media.Imaging.BitmapCreateOptions]::PreservePixelFormat,[Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
                $metadata = [Windows.Media.Imaging.BitmapMetadata]::new('gif')
                $metadata.SetQuery('/grctlext/Delay',[uint16]$scene.Delay)
                $metadata.SetQuery('/grctlext/Disposal',[byte]1)
                $frame = [Windows.Media.Imaging.BitmapFrame]::Create($decoded,$null,$metadata,$null)
                $encoder.Frames.Add($frame)
            } finally { $memory.Dispose(); $graphics.Dispose(); $bitmap.Dispose() }
        }
        $encoded = [IO.MemoryStream]::new()
        try { $encoder.Save($encoded); $bytes=$encoded.ToArray() } finally { $encoded.Dispose() }
        # WIC may omit frame timing. Write graphic-control blocks explicitly and add looping.
        $offset = 13
        if ($bytes[10] -band 0x80) { $offset += 3 * [int][Math]::Pow(2,($bytes[10] -band 7)+1) }
        $loop = [byte[]](@(0x21,0xff,0x0b) + [Text.Encoding]::ASCII.GetBytes('NETSCAPE2.0') + @(3,1,0,0,0))
        $result = [IO.MemoryStream]::new()
        try {
            $result.Write($bytes,0,$offset)
            $result.Write($loop,0,$loop.Length)
            $frameIndex = 0
            while ($offset -lt $bytes.Length) {
                $start = $offset
                $kind = $bytes[$offset]
                if ($kind -eq 0x3b) { $result.WriteByte(0x3b); break }
                if ($kind -eq 0x21) {
                    $label = $bytes[$offset+1]
                    $offset += 2
                } elseif ($kind -eq 0x2c) {
                    $delay = [int]$scenes[$frameIndex].Delay
                    $control = [byte[]]@(0x21,0xf9,4,4,($delay -band 255),($delay -shr 8),0,0)
                    $result.Write($control,0,$control.Length)
                    $packed = $bytes[$offset+9]
                    $offset += 10
                    if ($packed -band 0x80) { $offset += 3 * [int][Math]::Pow(2,($packed -band 7)+1) }
                    $offset++ # LZW minimum code size.
                    $frameIndex++
                } else { throw 'Unexpected GIF block.' }
                do {
                    if ($offset -ge $bytes.Length) { throw 'Truncated GIF data.' }
                    $size = [int]$bytes[$offset]
                    $offset += 1 + $size
                } while ($size -gt 0)
                if ($kind -ne 0x21 -or $label -ne 0xf9) { $result.Write($bytes,$start,$offset-$start) }
            }
            if ($frameIndex -ne $scenes.Count) { throw 'Unexpected encoded scene count.' }
            New-Item -ItemType Directory -Path (Split-Path -Parent $OutputPath) -Force | Out-Null
            [IO.File]::WriteAllBytes($OutputPath,$result.ToArray())
        } finally { $result.Dispose() }
    } finally { $font.Dispose(); $titleFont.Dispose(); $noteFont.Dispose(); foreach ($brush in $brushes.Values) { $brush.Dispose() } }
    $image = [Drawing.Image]::FromFile($OutputPath)
    try {
        $frameCount = $image.GetFrameCount([Drawing.Imaging.FrameDimension]::Time)
        $delays = $image.GetPropertyItem(0x5100).Value
        $duration = 0
        for ($index=0; $index -lt $frameCount; $index++) { $duration += [BitConverter]::ToUInt32($delays,$index*4) }
        if ($frameCount -ne 4 -or $duration -ne 2500) { throw 'Unexpected GIF frame count or duration.' }
        [pscustomobject]@{Path=$OutputPath;Frames=$frameCount;Seconds=$duration/100;Width=$image.Width;Height=$image.Height;Bytes=(Get-Item $OutputPath).Length}
    } finally { $image.Dispose() }
} finally {
    $resolved = [IO.Path]::GetFullPath($fixture)
    if ($resolved.StartsWith($allowedRoot,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $resolved) -like '.tmp-demo-*' -and (Test-Path -LiteralPath $resolved)) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}