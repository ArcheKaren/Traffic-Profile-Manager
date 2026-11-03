[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$AppRoot
)

$ErrorActionPreference = "Stop"
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) (
    "modules\TrafficProfileManager.Runtime\TrafficProfileManager.Runtime.psd1"
)) -ErrorAction Stop
$runtimeRoot = Join-Path $AppRoot "runtime"
$manifest = Get-TpmRuntimeManifest (Join-Path $runtimeRoot "SOURCE.json")
$portable = (Test-Path -LiteralPath (Join-Path $AppRoot "metadata/release-manifest.json") -PathType Leaf) -or
    (Test-Path -LiteralPath (Join-Path $AppRoot ".tpm-release-manifest.json") -PathType Leaf)
$layout = if ($portable) { "Portable" } else { "Source" }
foreach ($key in @(
    "winws2", "winDivertDll", "winDivertDriver", "cygwin", "luaLib", "luaAntidpi"
)) {
    [void](Get-TpmVerifiedRuntimeFile -RuntimeRoot $runtimeRoot `
        -Entry $manifest.runtimeFiles.$key -Layout $layout)
}
