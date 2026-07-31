[CmdletBinding()]
param(
    [string]$TargetFile = "",
    [string[]]$Profiles = @(),
    [int]$TimeoutSeconds = 8,
    [int]$StartupSeconds = 2,
    [switch]$NonInteractive
)

$ErrorActionPreference = "Stop"
$appRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$targetPath = if ($TargetFile) {
    [IO.Path]::GetFullPath($TargetFile)
} else {
    Join-Path $appRoot "tests\targets.txt"
}
$resultRoot = Join-Path $appRoot "test-results"
$stateRoot = Join-Path $appRoot "state"
$benchmarkHostList = Join-Path $stateRoot "benchmark-domains.txt"
$script:controller = $null
$script:managedMappingsInstalled = $false

. (Join-Path $appRoot "tools\profile-library.ps1")

$discoveredProfiles = @(Get-TrafficProfiles $appRoot -IncludeInvalid)
$invalidProfiles = @($discoveredProfiles | Where-Object { -not $_.Valid })
$profileCatalog = @(
    $discoveredProfiles |
        Where-Object Valid |
        ForEach-Object {
            [pscustomobject]@{
                Number = $_.Number
                Id = $_.Id
                Label = $_.DisplayName
            }
        }
)

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Read-Targets {
    if (-not (Test-Path -LiteralPath $targetPath -PathType Leaf)) {
        throw "Target pool was not found: $targetPath"
    }
    $items = New-Object "Collections.Generic.List[object]"
    $names = New-Object "Collections.Generic.HashSet[string]" ([StringComparer]::OrdinalIgnoreCase)
    foreach ($rawLine in Get-Content -LiteralPath $targetPath) {
        $line = $rawLine.Trim()
        if (-not $line -or $line.StartsWith("#")) { continue }
        if ($line -notmatch '^(?<name>[A-Za-z0-9_-]+)\s*=\s*"(?<url>https://[^"]+)"\s*$') {
            throw "Invalid target line: $rawLine"
        }
        $uri = $null
        if (-not [Uri]::TryCreate($Matches.url, [UriKind]::Absolute, [ref]$uri)) {
            throw "Invalid URL: $($Matches.url)"
        }
        if (-not $names.Add($Matches.name)) {
            throw "Duplicate target name: $($Matches.name)"
        }
        $items.Add([pscustomobject]@{
            Name = $Matches.name
            Url = $uri.AbsoluteUri
            Host = $uri.DnsSafeHost.ToLowerInvariant()
        })
    }
    if ($items.Count -eq 0) { throw "The target pool is empty." }
    return $items.ToArray()
}

function Stop-ActiveProfile {
    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File `
        (Join-Path $appRoot "zapretctl.ps1") stop *> $null
    if ($script:controller -and -not $script:controller.HasExited) {
        [void]$script:controller.WaitForExit(3000)
        if (-not $script:controller.HasExited) {
            Stop-Process -Id $script:controller.Id -Force -ErrorAction SilentlyContinue
        }
    }
    $script:controller = $null
    Start-Sleep -Milliseconds 400
}

function Start-Profile([string]$ProfileId) {
    Stop-ActiveProfile
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = "powershell.exe"
    $startInfo.Arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "{0}" foreground "{1}"' -f `
        (Join-Path $appRoot "zapretctl.ps1"), $ProfileId
    $startInfo.WorkingDirectory = $appRoot
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $script:controller = [Diagnostics.Process]::Start($startInfo)

    $pidPath = Join-Path $stateRoot "winws2.windows.pid"
    $deadline = [DateTime]::UtcNow.AddSeconds(
        [Math]::Max(15, $StartupSeconds + 10)
    )
    do {
        if ($script:controller.HasExited) {
            throw "Profile $ProfileId stopped during startup."
        }
        if (Test-Path -LiteralPath $pidPath) {
            $runtimePid = 0
            if (
                [int]::TryParse(
                    (Get-Content -Raw -LiteralPath $pidPath).Trim(),
                    [ref]$runtimePid
            ) -and
                (Get-Process -Id $runtimePid -ErrorAction SilentlyContinue)
            ) {
                $mappingDeadline = [DateTime]::UtcNow.AddSeconds(45)
                $hostsPath = Join-Path $env:SystemRoot `
                    "System32\drivers\etc\hosts"
                do {
                    $mappingReady = Select-String `
                        -LiteralPath $hostsPath `
                        -Pattern "`twww.instagram.com" `
                        -SimpleMatch `
                        -Quiet `
                        -ErrorAction SilentlyContinue
                    if ($mappingReady) { break }
                    if ($script:controller.HasExited) {
                        throw "Profile $ProfileId stopped while preparing mappings."
                    }
                    Start-Sleep -Milliseconds 250
                } while ([DateTime]::UtcNow -lt $mappingDeadline)
                if (-not $mappingReady) {
                    try {
                        & (Join-Path $appRoot "manage-network-mappings.ps1") refresh `
                            *>$null
                    } catch {
                        # Endpoint checks must still run when an optional mapping
                        # refresh cannot reach one of its probe addresses.
                    }
                }
                Start-Sleep -Seconds $StartupSeconds
                return
            }
        }
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Profile $ProfileId did not become ready."
}

function Get-CurlArguments($Target) {
    return (
        '--location --silent --show-error --output NUL ' +
        '--write-out "%{{http_code}}" --connect-timeout 4 ' +
        '--max-time {0} --user-agent "TrafficProfileManager/1.0" "{1}"'
    ) -f $TimeoutSeconds, $Target.Url.Replace('"', '%22')
}

function New-CurlStartInfo($Target) {
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = "curl.exe"
    $startInfo.Arguments = Get-CurlArguments $Target
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    try {
        $oemEncoding = [Text.Encoding]::GetEncoding(
            [Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage
        )
        $startInfo.StandardOutputEncoding = $oemEncoding
        $startInfo.StandardErrorEncoding = $oemEncoding
    } catch {
        # The numeric HTTP output remains readable with the default encoding.
    }
    return $startInfo
}

function Invoke-CurlRetry($Target) {
    $startInfo = New-CurlStartInfo $Target
    $process = [Diagnostics.Process]::Start($startInfo)
    [void]$process.WaitForExit(($TimeoutSeconds + 3) * 1000)
    if (-not $process.HasExited) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        return [pscustomobject]@{
            HttpCode = "000"
            ExitCode = 28
            Detail = "timeout"
        }
    }
    return [pscustomobject]@{
        HttpCode = $process.StandardOutput.ReadToEnd().Trim()
        ExitCode = $process.ExitCode
        Detail = $process.StandardError.ReadToEnd().Trim()
    }
}

function Update-CertificateChainCache([string]$HostName) {
    $tcp = [Net.Sockets.TcpClient]::new()
    try {
        $tcp.ReceiveTimeout = 5000
        $tcp.SendTimeout = 5000
        $tcp.Connect($HostName, 443)
        $callback = [Net.Security.RemoteCertificateValidationCallback]{
            return $true
        }
        $ssl = [Net.Security.SslStream]::new(
            $tcp.GetStream(),
            $false,
            $callback
        )
        try {
            $ssl.ReadTimeout = 5000
            $ssl.WriteTimeout = 5000
            $ssl.AuthenticateAsClient($HostName)
            $certificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new(
                $ssl.RemoteCertificate
            )
            $chain = [Security.Cryptography.X509Certificates.X509Chain]::new()
            try {
                $chain.ChainPolicy.RevocationMode = [Security.Cryptography.X509Certificates.X509RevocationMode]::NoCheck
                $trusted = $chain.Build($certificate)
                $chainStatus = @(
                    $chain.ChainStatus |
                        ForEach-Object { $_.Status.ToString() }
                ) -join ","
                if (-not $chainStatus) { $chainStatus = "None" }
                return [pscustomobject]@{
                    Trusted = $trusted
                    Summary = (
                        "TLS leaf: subject=[{0}]; issuer=[{1}]; valid={2}..{3}; " +
                        "chainTrusted={4}; chainStatus={5}; remote={6}"
                    ) -f
                        $certificate.Subject,
                        $certificate.Issuer,
                        $certificate.NotBefore.ToString("yyyy-MM-dd HH:mm:ss"),
                        $certificate.NotAfter.ToString("yyyy-MM-dd HH:mm:ss"),
                        $trusted,
                        $chainStatus,
                        $tcp.Client.RemoteEndPoint.Address
                }
            } finally {
                $chain.Dispose()
                $certificate.Dispose()
            }
        } finally {
            $ssl.Dispose()
        }
    } catch {
        return [pscustomobject]@{
            Trusted = $false
            Summary = "TLS diagnostic failed: $($_.Exception.Message)"
        }
    } finally {
        $tcp.Dispose()
    }
}

function Invoke-TargetChecks($Targets) {
    $pending = New-Object "Collections.Generic.List[object]"
    foreach ($target in $Targets) {
        $startInfo = New-CurlStartInfo $target
        $process = [Diagnostics.Process]::Start($startInfo)
        $pending.Add([pscustomobject]@{
            Target = $target
            Process = $process
            Started = [DateTime]::UtcNow
        })
    }

    foreach ($item in $pending) {
        $remaining = [Math]::Max(
            0,
            [int](
                $item.Started.AddSeconds($TimeoutSeconds + 3) -
                [DateTime]::UtcNow
            ).TotalMilliseconds
        )
        [void]$item.Process.WaitForExit($remaining)
        if (-not $item.Process.HasExited) {
            Stop-Process -Id $item.Process.Id -Force -ErrorAction SilentlyContinue
            $code = "000"
            $exitCode = 28
            $detail = "timeout"
        } else {
            $code = $item.Process.StandardOutput.ReadToEnd().Trim()
            $exitCode = $item.Process.ExitCode
            $detail = $item.Process.StandardError.ReadToEnd().Trim()
        }
        $healthy = $exitCode -eq 0 -and $code -match '^[234]\d\d$'
        $success = $exitCode -eq 0 -and $code -match '^[2345]\d\d$'
        if (
            -not $success -and
            $exitCode -eq 35 -and
            $detail -match 'SEC_E_CERT_EXPIRED'
        ) {
            $chainResult = Update-CertificateChainCache $item.Target.Host
            if ($chainResult.Trusted) {
                $retry = Invoke-CurlRetry $item.Target
                $code = $retry.HttpCode
                $exitCode = $retry.ExitCode
                $detail = $retry.Detail
                $healthy = $exitCode -eq 0 -and $code -match '^[234]\d\d$'
                $success = $exitCode -eq 0 -and $code -match '^[2345]\d\d$'
            }
            if (-not $success) {
                $detail = "$detail | $($chainResult.Summary)"
            }
        }
        [pscustomobject]@{
            Target = $item.Target.Name
            Url = $item.Target.Url
            Success = $success
            Healthy = $healthy
            HttpCode = if ($code) { $code } else { "000" }
            ExitCode = $exitCode
            Detail = $detail
        }
    }
}

try {
    if (-not (Test-IsAdministrator)) {
        throw "Run Test Profiles.bat and approve the administrator prompt."
    }
    if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) {
        throw "curl.exe is required and was not found."
    }
    if (
        Get-Service -Name "TrafficProfileService" -ErrorAction SilentlyContinue |
            Where-Object Status -eq "Running"
    ) {
        throw "Remove or stop the automatic service before running the comparison."
    }
    if ($invalidProfiles.Count -gt 0) {
        Write-Host "Invalid profile files will be skipped:" -ForegroundColor Red
        foreach ($profile in $invalidProfiles) {
            Write-Host "  $($profile.Id): $($profile.Error)" -ForegroundColor Red
        }
        Write-Host ""
    }
    if ($profileCatalog.Count -eq 0) {
        throw "No valid profile files were found."
    }

    $targets = @(Read-Targets)
    if ($Profiles.Count -gt 0) {
        $selected = @($profileCatalog | Where-Object { $_.Id -in $Profiles })
        if ($selected.Count -ne $Profiles.Count) {
            throw "One or more profile IDs are unknown."
        }
    } else {
        $selected = $profileCatalog
    }

    New-Item -ItemType Directory -Path $resultRoot, $stateRoot -Force | Out-Null
    [IO.File]::WriteAllLines(
        $benchmarkHostList,
        @("# Temporary comparison list. Generated automatically.") +
            @($targets.Host | Sort-Object -Unique),
        [Text.UTF8Encoding]::new($false)
    )
    $env:TRAFFIC_PROFILE_BENCHMARK_LIST = $benchmarkHostList

    & (Join-Path $appRoot "manage-network-mappings.ps1") install | Out-Host
    $script:managedMappingsInstalled = $true
    $watcherPath = Join-Path $appRoot "tools\watch-benchmark.ps1"
    $watcherInfo = [Diagnostics.ProcessStartInfo]::new()
    $watcherInfo.FileName = "powershell.exe"
    $watcherInfo.Arguments = (
        (
            '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "{0}" ' +
            '-ControllerPid {1} -ControllerStartTicks {2}'
        ) -f
        $watcherPath,
        $PID,
        (Get-Process -Id $PID).StartTime.ToUniversalTime().Ticks
    )
    $watcherInfo.UseShellExecute = $true
    $watcherInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    [void][Diagnostics.Process]::Start($watcherInfo)

    Write-Host ""
    Write-Host "Traffic Profile Comparison" -ForegroundColor Cyan
    Write-Host "Profiles: $($selected.Count)   Endpoints: $($targets.Count)"
    Write-Host "Results reflect the connection and routing active during this run."
    Write-Host "OK = normal HTTP response; UP = endpoint reached with HTTP 5xx."
    Write-Host ""
    if (-not $NonInteractive) {
        $answer = Read-Host "Press Enter to start, or type Q to cancel"
        if ($answer -match '^(q|quit)$') { return }
    }

    $allResults = New-Object "Collections.Generic.List[object]"
    $profileIndex = 0
    foreach ($profile in $selected) {
        $profileIndex++
        Write-Host (
            "[{0}/{1}] {2} - {3}" -f
            $profileIndex, $selected.Count, $profile.Number, $profile.Label
        ) -ForegroundColor Yellow
        try {
            Start-Profile $profile.Id
            $checks = @(Invoke-TargetChecks $targets)
        } catch {
            $profileError = $_.Exception.Message
            Write-Host "  Test error: $profileError" -ForegroundColor Red
            $checks = @(
                foreach ($target in $targets) {
                    [pscustomobject]@{
                        Target = $target.Name
                        Url = $target.Url
                        Success = $false
                        Healthy = $false
                        HttpCode = "000"
                        ExitCode = -1
                        Detail = $profileError
                    }
                }
            )
        } finally {
            Stop-ActiveProfile
        }
        foreach ($check in $checks) {
            $allResults.Add([pscustomobject]@{
                ProfileNumber = $profile.Number
                ProfileId = $profile.Id
                Profile = $profile.Label
                Target = $check.Target
                Url = $check.Url
                Success = $check.Success
                Healthy = $check.Healthy
                HttpCode = $check.HttpCode
                ExitCode = $check.ExitCode
                Detail = $check.Detail
            })
            $mark = if (-not $check.Success) {
                "--"
            } elseif ($check.Healthy) {
                "OK"
            } else {
                "UP"
            }
            Write-Host (
                "  {0,-18} {1,3}  HTTP {2}" -f
                $check.Target, $mark, $check.HttpCode
            )
        }
        Write-Host ""
    }

    $ranking = @(
        foreach ($profile in $selected) {
            $rows = @($allResults | Where-Object ProfileId -eq $profile.Id)
            $passed = @($rows | Where-Object Success).Count
            [pscustomobject]@{
                Number = $profile.Number
                Profile = $profile.Label
                Passed = $passed
                Total = $rows.Count
                Score = if ($rows.Count) {
                    [Math]::Round(100 * $passed / $rows.Count)
                } else {
                    0
                }
            }
        }
    ) | Sort-Object `
        @{ Expression = "Score"; Descending = $true },
        @{ Expression = "Passed"; Descending = $true },
        @{ Expression = "Number"; Descending = $false }

    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $csvPath = Join-Path $resultRoot "profile-comparison-$stamp.csv"
    $textPath = Join-Path $resultRoot "profile-comparison-$stamp.txt"
    $allResults | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8
    $summary = @(
        "Traffic Profile Comparison"
        "Created: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        "Target pool: $targetPath"
        "Scoring: HTTP 2xx-4xx = OK; HTTP 5xx = reachable (UP); no HTTP response = failed."
        ""
        ($ranking | Format-Table -AutoSize | Out-String).TrimEnd()
        ""
        (
            "Best result: profile {0} - {1} ({2}/{3})" -f
            $ranking[0].Number,
            $ranking[0].Profile,
            $ranking[0].Passed,
            $ranking[0].Total
        )
    )
    [IO.File]::WriteAllLines($textPath, $summary, [Text.UTF8Encoding]::new($false))

    Write-Host "Ranking" -ForegroundColor Cyan
    $ranking | Format-Table -AutoSize
    Write-Host (
        "Best result: profile {0} - {1}" -f
        $ranking[0].Number, $ranking[0].Profile
    ) -ForegroundColor Green
    Write-Host "Reports:"
    Write-Host "  $textPath"
    Write-Host "  $csvPath"
} finally {
    Stop-ActiveProfile
    if ($script:managedMappingsInstalled) {
        & (Join-Path $appRoot "manage-network-mappings.ps1") cleanup *> $null
    }
    Remove-Item Env:\TRAFFIC_PROFILE_BENCHMARK_LIST -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $benchmarkHostList) {
        Remove-Item -LiteralPath $benchmarkHostList -Force -ErrorAction SilentlyContinue
    }
}
