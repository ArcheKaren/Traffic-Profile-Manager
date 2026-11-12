param([string]$ProjectRoot,[string]$FixtureRoot,[ValidateSet('start','pid','identity','watcher')][string]$FailurePoint)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $ProjectRoot 'modules/TrafficProfileManager.Core/TrafficProfileManager.Core.psd1') -Force
. (Join-Path $ProjectRoot 'modules/TrafficProfileManager.Controller/Private/AppState.ps1')
. (Join-Path $ProjectRoot 'modules/TrafficProfileManager.Controller/Private/RuntimeProcess.ps1')
$script:AppRoot=$FixtureRoot
$script:runtime=$null
$script:originalWriteAtomic=(Get-Command Write-AtomicText).ScriptBlock
$script:originalWriteIdentity=(Get-Command Write-ProcessIdentity).ScriptBlock
$script:originalStartInfo=(Get-Command New-TpmProcessStartInfo).ScriptBlock
$script:readyAtPidWrite=$false
New-Item -ItemType Directory -Path (Join-Path $FixtureRoot 'state'),(Join-Path $FixtureRoot 'tools') -Force|Out-Null
[IO.File]::WriteAllText((Join-Path $FixtureRoot 'tools/manage-network-mappings.ps1'), 'param([string]$Action) Add-Content -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) "mapping-calls.txt") -Value $Action')
function Ensure-Initialized {}
function Test-TpmIsAdministrator { return $true }
function Get-RunningPid { return $null }
function Find-RuntimeExecutable { return (Get-Command powershell.exe).Source }
function Find-RuntimeFile { return 'fixture' }
function Build-WinwsArguments { return @('-NoLogo','-NoProfile','-NonInteractive','-Command','Start-Sleep -Seconds 60') }
function Show-TpmProfileSession {}
function Start-Process {
    [CmdletBinding()]
    param([string]$FilePath,[string]$ArgumentList,[string]$WorkingDirectory,[switch]$NoNewWindow,[switch]$PassThru,[string]$RedirectStandardOutput,[string]$RedirectStandardError)
    if($FailurePoint -eq 'start'){throw 'Injected startup failure: start'}
    [void]$PSBoundParameters.Remove('NoNewWindow')
    $PSBoundParameters['WindowStyle']='Hidden'
    $script:runtime=Microsoft.PowerShell.Management\Start-Process @PSBoundParameters
    @{pid=$script:runtime.Id;ticks=$script:runtime.StartTime.ToUniversalTime().Ticks}|ConvertTo-Json|Set-Content (Join-Path $FixtureRoot 'runtime-owner.json')
    [IO.File]::WriteAllText((Get-AppPath ("state/mapping-ready-$($script:runtime.Id).flag")),'stale')
    return $script:runtime
}
function Write-AtomicText([string]$Path,[string]$Text) {
    if($Path -eq (Get-AppPath 'state/winws2.windows.pid')){
        $script:readyAtPidWrite=Test-Path -LiteralPath (Get-AppPath ("state/mapping-ready-$($script:runtime.Id).flag"))
        if($FailurePoint -eq 'pid'){throw 'Injected startup failure: pid'}
    }
    & $script:originalWriteAtomic $Path $Text
}
function Write-ProcessIdentity([Diagnostics.Process]$Process,[string]$Executable) {
    & $script:originalWriteIdentity $Process $Executable
    if($FailurePoint -eq 'identity'){throw 'Injected startup failure: identity'}
}
function New-TpmProcessStartInfo {
    [CmdletBinding()]
    param([string]$FilePath,[string[]]$ArgumentList,[switch]$CreateNoWindow)
    if($FailurePoint -eq 'watcher'){throw 'Injected startup failure: watcher'}
    & $script:originalStartInfo @PSBoundParameters
}
$unrelated=[Diagnostics.Process]::Start((& $script:originalStartInfo -FilePath powershell.exe -CreateNoWindow -RedirectStandardOutput -RedirectStandardError -ArgumentList @('-NoProfile','-Command','Start-Sleep -Seconds 60')))
@{pid=$unrelated.Id;ticks=$unrelated.StartTime.ToUniversalTime().Ticks}|ConvertTo-Json|Set-Content (Join-Path $FixtureRoot 'unrelated-owner.json')
$unrelatedFlag=Get-AppPath ("state/mapping-ready-$($unrelated.Id).flag")
[IO.File]::WriteAllText($unrelatedFlag,'unrelated')
try {
    $message=''
    try { Start-ZapretForeground 'fixture' } catch { $message=$_.Exception.Message }
    $result=[pscustomobject]@{
        Error=$message
        RuntimeStoppedByController=($null -eq $script:runtime -or $script:runtime.HasExited)
        UnrelatedAlive=(-not $unrelated.HasExited)
        UnrelatedFlagPreserved=(Test-Path -LiteralPath $unrelatedFlag)
        ReadyFlagPresentWhenPidPublished=$script:readyAtPidWrite
        PidFilePresent=(Test-Path -LiteralPath (Get-AppPath 'state/winws2.windows.pid'))
        IdentityFilePresent=(Test-Path -LiteralPath (Get-AppPath 'state/winws2.identity.json'))
        MappingCalls=@(Get-Content -LiteralPath (Join-Path $FixtureRoot 'mapping-calls.txt') -ErrorAction SilentlyContinue)
    }
} finally {
    foreach($process in @($script:runtime,$unrelated)){
        if($process){if(-not $process.HasExited){$process.Kill();[void]$process.WaitForExit(5000)};$process.Dispose()}
    }
}
$result|ConvertTo-Json -Depth 3