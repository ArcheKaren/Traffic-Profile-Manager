[CmdletBinding()]
param(
    [string]$TargetFile = "",
    [string[]]$Profiles = @(),
    [ValidateRange(1,120)][int]$TimeoutSeconds = 8,
    [ValidateRange(0,30)][int]$StartupSeconds = 2,
    [ValidateSet('quick','full')][string]$Mode = 'quick',
    [ValidateRange(0,10)][int]$Rounds = 0,
    [switch]$SkipBaseline,
    [switch]$NonInteractive
)

$ErrorActionPreference = "Stop"
$appRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path $PSScriptRoot 'benchmark-library.ps1')
$settings = Get-TpmBenchmarkSettings (Join-Path $appRoot 'config/benchmark.json') $Mode
if (-not $PSBoundParameters.ContainsKey('TimeoutSeconds')) { $TimeoutSeconds = $settings.timeoutSeconds }
if (-not $PSBoundParameters.ContainsKey('StartupSeconds')) { $StartupSeconds = $settings.startupSeconds }
if (-not $Rounds) { $Rounds = $settings.rounds }
$originalBenchmarkEnvironment = $env:TRAFFIC_PROFILE_BENCHMARK_LIST
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) "modules\TrafficProfileManager.Console\TrafficProfileManager.Console.psd1") -ErrorAction Stop
Set-TpmUiRoot $appRoot

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

Import-Module (
    Join-Path $appRoot `
        "modules\TrafficProfileManager.Profile\TrafficProfileManager.Profile.psd1"
) -ErrorAction Stop
Import-Module (
    Join-Path $appRoot `
        "modules\TrafficProfileManager.Core\TrafficProfileManager.Core.psd1"
) -ErrorAction Stop

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
    if (-not $script:controller) { return }
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
    $startInfo = New-TpmProcessStartInfo `
        -FilePath "powershell.exe" `
        -ArgumentList @(
            "-NoLogo",
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            (Join-Path $appRoot "zapretctl.ps1"),
            "foreground",
            $ProfileId
        ) `
        -WorkingDirectory $appRoot `
        -CreateNoWindow
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
                $mappingReadyPath = Join-Path $stateRoot "mapping-ready-$runtimePid.flag"
                do {
                    $mappingReady = Test-Path -LiteralPath $mappingReadyPath -PathType Leaf
                    if ($mappingReady) { break }
                    if ($script:controller.HasExited) {
                        throw "Profile $ProfileId stopped while preparing mappings."
                    }
                    Start-Sleep -Milliseconds 250
                } while ([DateTime]::UtcNow -lt $mappingDeadline)
                if (-not $mappingReady) {
                    try {
                        & (Join-Path $appRoot "tools\manage-network-mappings.ps1") refresh `
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

function Get-CurlArgumentList($Target) {
    return @(
        "--location",
        "--silent",
        "--show-error",
        "--output",
        "NUL",
        "--write-out",
        "%{http_code}",
        "--connect-timeout",
        "4",
        "--max-time",
        [string]$TimeoutSeconds,
        "--user-agent",
        "TrafficProfileManager/1.0",
        [string]$Target.Url
    )
}

function New-CurlStartInfo($Target) {
    $startInfo = New-TpmProcessStartInfo `
        -FilePath "curl.exe" `
        -ArgumentList (Get-CurlArgumentList $Target) `
        -CreateNoWindow `
        -RedirectStandardOutput `
        -RedirectStandardError
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
    try {
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
    } finally {
        foreach ($entry in $pending) {
            if (-not $entry.Process.HasExited) { Stop-Process -InputObject $entry.Process -Force -ErrorAction SilentlyContinue }
            $entry.Process.Dispose()
        }
    }
}

. (Join-Path $PSScriptRoot 'benchmark-run.ps1')
