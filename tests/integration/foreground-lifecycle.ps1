[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $projectRoot 'tests/fixtures/acl-signature.ps1')
$testRoot = Join-Path $projectRoot ("tests\.tmp-foreground-" + [Guid]::NewGuid().ToString("N"))
$resolvedTest = [IO.Path]::GetFullPath($testRoot)
$allowedRoot = [IO.Path]::GetFullPath((Join-Path $projectRoot "tests")).TrimEnd("\") + "\"
if (-not $resolvedTest.StartsWith($allowedRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Unsafe foreground test directory."
}
Import-Module (Join-Path $projectRoot (
    "modules\TrafficProfileManager.Core\TrafficProfileManager.Core.psd1"
)) -Force
$nativeSource = Join-Path $projectRoot "tests\fixtures\ForegroundConsole.cs"
Add-Type -Path $nativeSource
$shell = (Get-Command powershell.exe).Source
$ownedProcesses = New-Object Collections.Generic.List[object]
$testPassed = $false

function Register-TestProcess([int]$ProcessId) {
    $process = Get-Process -Id $ProcessId -ErrorAction Stop
    $identity = [pscustomobject]@{
        Pid = $process.Id
        Ticks = $process.StartTime.ToUniversalTime().Ticks
    }
    $ownedProcesses.Add($identity)
    return $identity
}

function Get-TestProcess($Identity) {
    if (-not $Identity) { return $null }
    try {
        $process = Get-Process -Id $Identity.Pid -ErrorAction SilentlyContinue
        if ($process -and $process.StartTime -and $process.StartTime.ToUniversalTime().Ticks -eq $Identity.Ticks) {
            return $process
        }
    } catch { return $null }
}

function Wait-TestCondition([scriptblock]$Condition, [string]$Message) {
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    do {
        if (& $Condition) { return }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    throw $Message
}

try {
    foreach ($scenario in @("normal", "runtime-crash", "controller-crash", "ctrl-c", "close-window")) {
        $fixture = Join-Path $resolvedTest ($scenario + " user's path")
        foreach ($directory in @("state", "tools", "modules", "config\network-mappings")) {
            New-Item -ItemType Directory -Path (Join-Path $fixture $directory) -Force | Out-Null
        }
        Copy-Item -LiteralPath (Join-Path $projectRoot "modules\TrafficProfileManager.Core") `
            -Destination (Join-Path $fixture "modules") -Recurse
        foreach ($name in @("game-filter-library.ps1", "network-mapping-library.ps1")) {
            Copy-Item -LiteralPath (Join-Path $projectRoot "tools\$name") `
                -Destination (Join-Path $fixture "tools\$name")
        }
        Copy-Item -LiteralPath (Join-Path $projectRoot "tools\watch-foreground.ps1") -Destination (Join-Path $fixture "tools")
        Copy-Item -LiteralPath (Join-Path $projectRoot "tools\manage-network-mappings.ps1") `
            -Destination (Join-Path $fixture "tools\actual-mappings.ps1")
        Set-Content -LiteralPath (Join-Path $fixture "worker.ps1") -Value @'
[Console]::Out.WriteLine('runtime-output-marker')
[Console]::Error.WriteLine('runtime-error-marker')
while (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot "exit.flag"))) {
    Start-Sleep -Milliseconds 100
}
'@
        Set-Content -LiteralPath (Join-Path $fixture "tools\manage-network-mappings.ps1") -Value @'
param([string]$Action)
$ErrorActionPreference = "Stop"
function Clear-DnsClientCache {}
$fixtureRoot = Split-Path -Parent $PSScriptRoot
$process = Get-Process -Id $PID
@{ Pid = $PID; Ticks = $process.StartTime.ToUniversalTime().Ticks } |
    ConvertTo-Json | Set-Content -LiteralPath (Join-Path $fixtureRoot "state\mapping-process-$PID.json")
& (Join-Path $PSScriptRoot "actual-mappings.ps1") $Action `
    -AppRoot $fixtureRoot -HostsPath (Join-Path $fixtureRoot "hosts")
'@
        @{
            schemaVersion = 1; id = "fixture"; mode = "fixed"
            actions = @("install", "refresh"); address = "198.51.100.42"
            hosts = @("managed.example"); discoverSuffixes = @()
        } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $fixture "config\network-mappings\fixture.json")
        $hostsPath = Join-Path $fixture "hosts"
        Set-Content -LiteralPath $hostsPath "203.0.113.10 unrelated.example"
        $originalAcl = Get-TpmTestAclSignature $hostsPath

        $unrelatedInfo = New-TpmProcessStartInfo -FilePath $shell -CreateNoWindow `
            -ArgumentList @("-NoProfile", "-Command", "Start-Sleep -Seconds 300")
        $unrelatedProcess = [Diagnostics.Process]::Start($unrelatedInfo)
        $unrelated = Register-TestProcess $unrelatedProcess.Id
        $command = @($shell, "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
            (Join-Path $projectRoot "tests\fixtures\foreground-controller.ps1"),
            "-ProjectRoot", $projectRoot, "-FixtureRoot", $fixture) |
            ForEach-Object { ConvertTo-TpmWindowsArgument $_ }
        $controller = Register-TestProcess ([TpmForegroundConsole]::Start(($command -join " "), $fixture))
        $identityPath = Join-Path $fixture "state\winws2.identity.json"
        Wait-TestCondition {
            (Test-Path -LiteralPath $identityPath) -and
            ([IO.File]::ReadAllText($hostsPath).Contains("managed.example")) -and
            @(Get-ChildItem -LiteralPath (Join-Path $fixture "state") -Filter "mapping-process-*.json").Count -ge 2
        } "Foreground startup failed in $scenario. See $fixture."
        Wait-TestCondition {
            $stdout = @(Get-ChildItem -LiteralPath (Join-Path $fixture 'logs') -Filter '*.stdout.log' -File)
            $stderr = @(Get-ChildItem -LiteralPath (Join-Path $fixture 'logs') -Filter '*.stderr.log' -File)
            $stdout.Count -eq 1 -and $stderr.Count -eq 1 -and
                ([string](Get-Content -LiteralPath $stdout[0].FullName -Raw)).Contains('runtime-output-marker') -and
                ([string](Get-Content -LiteralPath $stderr[0].FullName -Raw)).Contains('runtime-error-marker')
        } "Runtime output was not captured to the session logs in $scenario."
        $workerIdentity = Get-Content -Raw -LiteralPath $identityPath | ConvertFrom-Json
        $worker = Register-TestProcess $workerIdentity.pid
        foreach ($record in Get-ChildItem -LiteralPath (Join-Path $fixture "state") -Filter "mapping-process-*.json") {
            $ownedProcesses.Add((Get-Content -Raw -LiteralPath $record.FullName | ConvertFrom-Json))
        }
        switch ($scenario) {
            "normal" { Set-Content -LiteralPath (Join-Path $fixture "exit.flag") "exit" }
            "runtime-crash" { (Get-TestProcess $worker).Kill() }
            "controller-crash" { (Get-TestProcess $controller).Kill() }
            default {
                $signalArguments = @("-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
                    (Join-Path $projectRoot "tests\fixtures\foreground-signal.ps1"),
                    "-TargetPid", [string]$controller.Pid, "-NativeSource", $nativeSource)
                if ($scenario -eq "close-window") { $signalArguments += "-CloseWindow" }
                $signal = [Diagnostics.Process]::Start((New-TpmProcessStartInfo `
                    -FilePath $shell -ArgumentList $signalArguments -CreateNoWindow))
                [void](Register-TestProcess $signal.Id)
                if (-not $signal.WaitForExit(10000)) { throw "Console signal timed out." }
                # Closing the console can also terminate its attached signal helper.
                if ($scenario -eq "ctrl-c" -and $signal.ExitCode -ne 0) {
                    throw "Ctrl+C delivery failed."
                }
                $signal.Dispose()
            }
        }
        Wait-TestCondition {
            -not (Get-TestProcess $controller) -and -not (Get-TestProcess $worker) -and
            -not (Test-Path -LiteralPath $identityPath) -and
            -not (Test-Path -LiteralPath (Join-Path $fixture "state\winws2.windows.pid")) -and
            -not ([IO.File]::ReadAllText($hostsPath).Contains("Mapping BEGIN")) -and
            -not @(Get-ChildItem -LiteralPath (Join-Path $fixture "state") -Filter "mapping-ready-*.flag").Count
        } "Foreground cleanup failed in $scenario. See $fixture."
        if (-not ([IO.File]::ReadAllText($hostsPath).Contains("203.0.113.10 unrelated.example"))) {
            throw "Unrelated hosts entry was changed in $scenario."
        }
        if ((Get-TpmTestAclSignature $hostsPath) -ne $originalAcl) {
            throw "Hosts ACL was changed in $scenario."
        }
        if (-not (Get-TestProcess $unrelated)) { throw "Unrelated process was stopped in $scenario." }
        (Get-TestProcess $unrelated).Kill()
        Wait-TestCondition {
            -not @($ownedProcesses | Where-Object { Get-TestProcess $_ }).Count
        } "A test process or cleanup watcher remains after $scenario."
        $unrelatedProcess.Dispose()
        Write-Host "[OK] Foreground lifecycle: $scenario"
    }
    $testPassed = $true
} finally {
    if (Test-Path -LiteralPath $resolvedTest) {
        foreach ($record in Get-ChildItem -LiteralPath $resolvedTest -Filter "*.json" -Recurse) {
            if ($record.Name -like "mapping-process-*.json") {
                try {
                    $ownedProcesses.Add((Get-Content -Raw -LiteralPath $record.FullName | ConvertFrom-Json))
                } catch {}
            } elseif ($record.Name -eq "winws2.identity.json") {
                try {
                    $identity = Get-Content -Raw -LiteralPath $record.FullName | ConvertFrom-Json
                    $ownedProcesses.Add([pscustomobject]@{
                        Pid = $identity.pid; Ticks = $identity.startTimeUtcTicks
                    })
                } catch {}
            }
        }
    }
    # Only stop processes created by this test, checking identity against PID reuse.
    foreach ($identity in $ownedProcesses) {
        $process = Get-TestProcess $identity
        if ($process) { $process.Kill(); [void]$process.WaitForExit(5000) }
    }
    if ($testPassed -and (Test-Path -LiteralPath $resolvedTest)) {
        Remove-Item -LiteralPath $resolvedTest -Recurse -Force
    }
}
