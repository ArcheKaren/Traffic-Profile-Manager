function Get-RunningPid {
    $pidPath = Get-AppPath "state\winws2.windows.pid"
    if (-not (Test-Path -LiteralPath $pidPath)) { return $null }
    $storedPid = 0
    if (-not [int]::TryParse(
        (Get-Content -Raw -LiteralPath $pidPath).Trim(),
        [ref]$storedPid
    )) { return $null }
    $process = Get-Process -Id $storedPid -ErrorAction SilentlyContinue
    if (-not $process -or $process.ProcessName -ne "winws2") { return $null }
    $identityPath = Get-AppPath "state\winws2.identity.json"
    if (Test-Path -LiteralPath $identityPath -PathType Leaf) {
        try {
            $identity = Read-JsonFile $identityPath
            $actualPath = [IO.Path]::GetFullPath($process.Path)
            $actualTicks = $process.StartTime.ToUniversalTime().Ticks
            if (
                [int]$identity.pid -eq $storedPid -and
                [int64]$identity.startTimeUtcTicks -eq $actualTicks -and
                $actualPath -ieq [IO.Path]::GetFullPath(
                    [string]$identity.executable
                )
            ) {
                return $storedPid
            }
        } catch {
            return $null
        }
        return $null
    }
    $expectedExecutable = Find-RuntimeExecutable
    if (
        $expectedExecutable -and
        [IO.Path]::GetFullPath($process.Path) -ieq
            [IO.Path]::GetFullPath($expectedExecutable)
    ) {
        return $storedPid
    }
    return $null
}

function Start-ZapretForeground([string]$ProfileName) {
    Ensure-Initialized
    if (-not (Test-TpmIsAdministrator)) {
        throw "Run the BAT file or terminal as administrator for WinDivert."
    }
    if (Get-RunningPid) {
        throw "Stop the background winws2 process first: zapretctl stop"
    }
    $executable = Find-RuntimeExecutable
    if (-not $executable) { throw "winws2.exe was not found in runtime." }
    if (
        -not (Find-RuntimeFile "zapret-lib.lua" $executable) -or
        -not (Find-RuntimeFile "zapret-antidpi.lua" $executable)
    ) {
        throw "The standard zapret2 Lua libraries were not found."
    }
    $arguments = @(
        Build-WinwsArguments $false $ProfileName |
            Where-Object {
                $_ -ne "--daemon" -and -not $_.StartsWith("--pidfile=")
            }
    )
    Write-Host ""
    Write-Host "Profile: $ProfileName" -ForegroundColor Cyan
    Write-Host `
        "The traffic profile remains active while this window is open." `
        -ForegroundColor Green
    Write-Host `
        "Press Ctrl+C or close the window to stop it." `
        -ForegroundColor Yellow
    Write-Host ""

    $startInfo = New-TpmProcessStartInfo `
        -FilePath $executable `
        -ArgumentList $arguments `
        -WorkingDirectory (Split-Path -Parent $executable)
    $process = [Diagnostics.Process]::Start($startInfo)
    $processStartTicks = $process.StartTime.ToUniversalTime().Ticks
    $windowsPidPath = Get-AppPath "state\winws2.windows.pid"
    Write-AtomicText $windowsPidPath ([string]$process.Id)
    Write-ProcessIdentity $process $executable
    $mappingReadyPath = Get-AppPath "state\mapping-ready-$($process.Id).flag"
    if (Test-Path -LiteralPath $mappingReadyPath) {
        Remove-Item -LiteralPath $mappingReadyPath -Force
    }

    $watcherStarted = $false
    try {
        $watcherPath = Get-AppPath "watch-foreground.ps1"
        $watcherArguments = New-Object "Collections.Generic.List[string]"
        foreach ($argument in @(
            "-NoLogo",
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            $watcherPath,
            "-ControllerPid",
            [string]$PID,
            "-ControllerStartTicks",
            [string]((Get-Process -Id $PID).StartTime.ToUniversalTime().Ticks),
            "-WinwsPid",
            [string]$process.Id,
            "-WinwsStartTicks",
            [string]$processStartTicks,
            "-WinwsPath",
            $executable,
            "-ReadyPath",
            $mappingReadyPath
        )) {
            $watcherArguments.Add($argument)
        }
        $watcherArguments.Add("-CleanupMappings")
        $watcherInfo = New-TpmProcessStartInfo `
            -FilePath "powershell.exe" `
            -ArgumentList $watcherArguments.ToArray() `
            -UseShellExecute `
            -WindowStyle Hidden
        [void][Diagnostics.Process]::Start($watcherInfo)
        $watcherStarted = $true

        try {
            & (Get-AppPath "manage-network-mappings.ps1") refresh | Out-Host
        } catch {
            Write-Warning (
                "Secure mappings could not be refreshed: " +
                $_.Exception.Message
            )
        } finally {
            Write-AtomicText $mappingReadyPath "ready"
        }

        $process.WaitForExit()
        if ($process.ExitCode -ne 0) {
            throw "winws2 exited with code $($process.ExitCode)."
        }
    } finally {
        if (-not $process.HasExited) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $mappingReadyPath) {
            Remove-Item `
                -LiteralPath $mappingReadyPath `
                -Force `
                -ErrorAction SilentlyContinue
        }
        if (-not $watcherStarted) {
            & (Get-AppPath "manage-network-mappings.ps1") cleanup *> $null
        }
        if (Test-Path -LiteralPath $windowsPidPath) {
            $storedPid = 0
            if (
                [int]::TryParse(
                    (Get-Content -Raw -LiteralPath $windowsPidPath).Trim(),
                    [ref]$storedPid
                ) -and
                $storedPid -eq $process.Id
            ) {
                Remove-Item -LiteralPath $windowsPidPath -Force
            }
        }
        Remove-ProcessIdentity $process.Id $processStartTicks
    }
}

function Start-Zapret([bool]$DryRun, [string]$ProfileName = "") {
    Ensure-Initialized
    if (-not $DryRun -and -not (Test-TpmIsAdministrator)) {
        throw "Run the terminal as administrator to start WinDivert."
    }
    if (Get-RunningPid) { throw "winws2 is already running." }
    $executable = Find-RuntimeExecutable
    if (-not $executable) {
        throw (
            "winws2.exe was not found. Extract the official " +
            "zapret-win-bundle into runtime."
        )
    }
    $luaLib = Find-RuntimeFile "zapret-lib.lua" $executable
    $luaAntidpi = Find-RuntimeFile "zapret-antidpi.lua" $executable
    if (-not $luaLib -or -not $luaAntidpi) {
        throw (
            "zapret-lib.lua and zapret-antidpi.lua were not found with " +
            "the Windows bundle."
        )
    }
    $arguments = Build-WinwsArguments $DryRun $ProfileName
    $startInfoParameters = @{
        FilePath = $executable
        ArgumentList = $arguments
        WorkingDirectory = (Split-Path -Parent $executable)
        CreateNoWindow = $true
    }
    if ($DryRun) {
        $startInfoParameters.RedirectStandardOutput = $true
        $startInfoParameters.RedirectStandardError = $true
    }
    $startInfo = New-TpmProcessStartInfo @startInfoParameters
    if ($DryRun) {
        $startInfo.EnvironmentVariables["__COMPAT_LAYER"] = "RunAsInvoker"
    }
    $process = [Diagnostics.Process]::Start($startInfo)
    $processStartTicks = $process.StartTime.ToUniversalTime().Ticks
    if ($DryRun) {
        $standardOutput = $process.StandardOutput.ReadToEnd()
        $standardError = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        if ($standardOutput) { Write-Host $standardOutput.TrimEnd() }
        if ($standardError) {
            Write-Host $standardError.TrimEnd() -ForegroundColor Red
        }
        if ($process.ExitCode -ne 0) {
            throw "Parameter validation exited with code $($process.ExitCode)."
        }
        Write-Host "winws2 accepted the parameters."
        return
    }
    $windowsPidPath = Get-AppPath "state\winws2.windows.pid"
    Write-AtomicText $windowsPidPath ([string]$process.Id)
    Write-ProcessIdentity $process $executable
    Start-Sleep -Milliseconds 500
    if (-not $process.HasExited) {
        Write-Host "winws2 started, Windows PID $($process.Id)"
        return
    }
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        Start-Sleep -Milliseconds 100
        if ($process.HasExited -and $process.ExitCode -ne 0) {
            if (Test-Path -LiteralPath $windowsPidPath) {
                Remove-Item -LiteralPath $windowsPidPath -Force
            }
            Remove-ProcessIdentity $process.Id $processStartTicks
            throw (
                "winws2 exited with code $($process.ExitCode). " +
                "Check logs\winws2.log."
            )
        }
        if (-not $process.HasExited) {
            Write-Host "winws2 started, Windows PID $($process.Id)"
            return
        }
    }
    if (Test-Path -LiteralPath $windowsPidPath) {
        Remove-Item -LiteralPath $windowsPidPath -Force
    }
    Remove-ProcessIdentity $process.Id $processStartTicks
    throw "winws2 exited immediately after startup. Check logs\winws2.log."
}

function Stop-Zapret {
    Ensure-Initialized
    $running = Get-RunningPid
    if (-not $running) {
        foreach ($pidPath in @(
            (Get-AppPath "state\winws2.pid"),
            (Get-AppPath "state\winws2.windows.pid"),
            (Get-AppPath "state\winws2.identity.json")
        )) {
            if (Test-Path -LiteralPath $pidPath) {
                Remove-Item -LiteralPath $pidPath -Force
            }
        }
        Write-Host "winws2 is not running."
        return
    }
    Stop-Process -Id $running -Force
    Start-Sleep -Milliseconds 300
    foreach ($pidPath in @(
        (Get-AppPath "state\winws2.pid"),
        (Get-AppPath "state\winws2.windows.pid"),
        (Get-AppPath "state\winws2.identity.json")
    )) {
        if (Test-Path -LiteralPath $pidPath) {
            Remove-Item -LiteralPath $pidPath -Force
        }
    }
    Write-Host "winws2 stopped."
}

function Show-Status {
    Ensure-Initialized
    $running = Get-RunningPid
    if ($running) {
        Write-Host "Status: running (PID $running)"
    } else {
        Write-Host "Status: stopped"
    }
    $config = Get-Config
    Write-Host "Profile: $($config.activeProfile)"
    $baseDomains = @(
        Get-TpmMeaningfulLines (Get-AppPath "lists\domains.txt")
    ).Count
    $userDomains = @(
        Get-TpmMeaningfulLines (Get-AppPath "lists\user-domains.txt")
    ).Count
    $baseIps = @(
        Get-TpmMeaningfulLines (Get-AppPath "lists\ips.txt")
    ).Count
    $userIps = @(
        Get-TpmMeaningfulLines (Get-AppPath "lists\user-ips.txt")
    ).Count
    Write-Host (
        "Domains: $($baseDomains + $userDomains) " +
        "(built-in: $baseDomains, custom: $userDomains)"
    )
    Write-Host (
        "IP/CIDR: $($baseIps + $userIps) " +
        "(built-in: $baseIps, custom: $userIps)"
    )
    $catalog = Get-TargetCatalog $script:AppRoot
    if ($null -ne $catalog) {
        $packState = Get-DomainPackState $script:AppRoot $catalog
        $enabledPacks = @($catalog.packs | Where-Object {
            $packState.Enabled.Contains([string]$_.id)
        })
        Write-Host (
            "Domain catalog: $($catalog.revision) " +
            "($($enabledPacks.Count)/$(@($catalog.packs).Count) packs enabled)"
        )
    }
}

function Adopt-ZapretProcess {
    Ensure-Initialized
    $running = Get-RunningPid
    if ($running) {
        Write-Host "winws2 is already registered, Windows PID $running"
        return
    }
    $candidates = @(Get-Process -Name "winws2" -ErrorAction SilentlyContinue)
    if ($candidates.Count -eq 0) {
        throw "No running winws2.exe process was found."
    }
    if ($candidates.Count -gt 1) {
        throw "Multiple winws2 processes were found and cannot be selected safely."
    }
    Write-AtomicText `
        (Get-AppPath "state\winws2.windows.pid") `
        ([string]$candidates[0].Id)
    Write-ProcessIdentity $candidates[0] $candidates[0].Path
    Write-Host "Process registered, Windows PID $($candidates[0].Id)"
}

function Show-Render([string]$ProfileName = "") {
    Ensure-Initialized
    $executable = Find-RuntimeExecutable
    if (-not $executable) { $executable = "<runtime>\winws2.exe" }
    Write-Output (ConvertTo-TpmWindowsArgument $executable)
    Build-WinwsArguments $false $ProfileName |
        ForEach-Object {
            Write-Output "  $(ConvertTo-TpmWindowsArgument $_)"
        }
}

function Show-Doctor {
    Ensure-Initialized
    function Report([bool]$Ok, [string]$Text) {
        if ($Ok) {
            Write-Host "[OK]   $Text" -ForegroundColor Green
        } else {
            Write-Host "[FAIL] $Text" -ForegroundColor Red
            $script:doctorFailures++
        }
    }
    $script:doctorFailures = 0
    Report (Test-TpmIsAdministrator) "Administrator privileges"
    $executable = Find-RuntimeExecutable
    Report ([bool]$executable) $(if ($executable) {
        "winws2.exe: $executable"
    } else { "winws2.exe in runtime" })
    Report `
        ([bool](Find-RuntimeFile "zapret-lib.lua" $executable)) `
        "zapret-lib.lua"
    Report `
        ([bool](Find-RuntimeFile "zapret-antidpi.lua" $executable)) `
        "zapret-antidpi.lua"
    Report `
        (Test-Path -LiteralPath (Get-AppPath (
            "config\profiles\$((Get-Config).activeProfile).json"
        ))) `
        "Active profile"
    $targets = @(
        Get-TpmMeaningfulLines (Get-AppPath "lists\domains.txt")
    ).Count + @(
        Get-TpmMeaningfulLines (Get-AppPath "lists\user-domains.txt")
    ).Count + @(
        Get-TpmMeaningfulLines (Get-AppPath "lists\ips.txt")
    ).Count + @(
        Get-TpmMeaningfulLines (Get-AppPath "lists\user-ips.txt")
    ).Count
    Report `
        ($targets -gt 0 -or (Get-Config).allowAllWithoutTargets) `
        "At least one target is configured"
    if ($executable) {
        Report `
            ([bool](Find-RuntimeFile "WinDivert64.sys" $executable)) `
            "WinDivert64.sys"
        Report `
            ([bool](Find-RuntimeFile "WinDivert.dll" $executable)) `
            "WinDivert.dll"
    }
    if ($script:doctorFailures -eq 0) {
        Write-Host "Diagnostics passed."
    } else {
        Write-Host "Problems found: $script:doctorFailures"
    }
}

function Show-Logs([string[]]$InputArgs) {
    Ensure-Initialized
    $path = Get-AppPath "logs\winws2.log"
    if (-not (Test-Path -LiteralPath $path)) {
        Write-Host "The log has not been created yet."
        return
    }
    $tail = 80
    if ($InputArgs.Count -ge 2 -and $InputArgs[0] -eq "--tail") {
        if (-not [int]::TryParse($InputArgs[1], [ref]$tail) -or $tail -lt 1) {
            throw "Invalid line count."
        }
    }
    Get-Content -LiteralPath $path -Tail $tail
}

function Invoke-RuntimeCommand([string[]]$InputArgs) {
    Ensure-Initialized
    if (
        -not $InputArgs -or
        $InputArgs.Count -lt 2 -or
        $InputArgs[0].ToLowerInvariant() -ne "path"
    ) {
        throw "Usage: zapretctl runtime path <path-to-winws2.exe>"
    }
    $path = [IO.Path]::GetFullPath($InputArgs[1])
    if (
        -not (Test-Path -LiteralPath $path -PathType Leaf) -or
        [IO.Path]::GetFileName($path) -ne "winws2.exe"
    ) {
        throw "The specified winws2.exe was not found: $path"
    }
    $config = Get-Config
    $config.runtimePath = $path
    Save-Config $config
    Write-Host "Runtime: $path"
}
