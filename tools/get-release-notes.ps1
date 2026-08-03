[CmdletBinding()]
param(
    [string]$RootPath = "",
    [Parameter(Mandatory = $true)]
    [string]$OutputPath
)

$ErrorActionPreference = "Stop"
$projectRoot = if ($RootPath) {
    [IO.Path]::GetFullPath($RootPath)
} else {
    Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
}
$version = (Get-Content -Raw -LiteralPath (Join-Path $projectRoot "VERSION")).Trim()
$changelog = [IO.File]::ReadAllText((Join-Path $projectRoot "CHANGELOG.md"))
$pattern = "(?ms)^##\s+" + [regex]::Escape($version) +
    "\s+[^\r\n]*\r?\n(?<body>.*?)(?=^##\s+|\z)"
$match = [regex]::Match($changelog, $pattern)
if (-not $match.Success) {
    throw "CHANGELOG.md has no section for version $version."
}
$notes = "# Traffic Profile Manager $version`r`n`r`n" +
    $match.Groups["body"].Value.Trim() + "`r`n"
$destination = [IO.Path]::GetFullPath($OutputPath)
New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force |
    Out-Null
[IO.File]::WriteAllText(
    $destination,
    $notes,
    [Text.UTF8Encoding]::new($false)
)
