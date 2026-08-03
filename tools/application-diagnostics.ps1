[CmdletBinding()]
param(
    [string]$TargetId = "",
    [string]$RootPath = "",
    [string]$OutputDirectory = "",
    [switch]$NoNetwork,
    [switch]$Interactive
)

$ErrorActionPreference = "Stop"
$appRoot = if ($RootPath) {
    [IO.Path]::GetFullPath($RootPath)
} else {
    Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
}
$targetPath = Join-Path $appRoot "config\diagnostic-targets.json"
if (-not (Test-Path -LiteralPath $targetPath -PathType Leaf)) {
    throw "Diagnostic target catalog was not found: $targetPath"
}
$catalog = Get-Content -Raw -LiteralPath $targetPath | ConvertFrom-Json
if ([int]$catalog.schemaVersion -ne 1 -or $catalog.targets -isnot [Array]) {
    throw "Diagnostic target catalog has an unsupported structure."
}
$targets = @($catalog.targets)
$ids = New-Object "Collections.Generic.HashSet[string]" (
    [StringComparer]::OrdinalIgnoreCase
)
foreach ($target in $targets) {
    if (
        [string]$target.id -notmatch "^[a-z0-9][a-z0-9-]{0,63}$" -or
        -not $ids.Add([string]$target.id) -or
        $target.domains -isnot [Array] -or
        @($target.domains).Count -eq 0
    ) {
        throw "Diagnostic target catalog contains an invalid target."
    }
}

if ($Interactive -and -not $TargetId) {
    Write-Host ""
    Write-Host "Application diagnostics" -ForegroundColor Cyan
    for ($index = 0; $index -lt $targets.Count; $index++) {
        Write-Host "[$($index + 1)] $($targets[$index].displayName)"
    }
    Write-Host "[0] Cancel"
    $choice = Read-Host "Select a target"
    $number = 0
    if (-not [int]::TryParse($choice, [ref]$number) -or $number -lt 0 -or $number -gt $targets.Count) {
        throw "Invalid diagnostic target selection."
    }
    if ($number -eq 0) { return }
    $TargetId = [string]$targets[$number - 1].id
}
if (-not $TargetId) { $TargetId = "overview" }
$selected = @($targets | Where-Object { [string]$_.id -ieq $TargetId }) |
    Select-Object -First 1
if (-not $selected) { throw "Unknown diagnostic target: $TargetId" }

function Test-TcpEndpoint([string]$Name, [int]$Port, [int]$TimeoutMs) {
    $client = New-Object Net.Sockets.TcpClient
    $watch = [Diagnostics.Stopwatch]::StartNew()
    try {
        $async = $client.BeginConnect($Name, $Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMs)) {
            return [pscustomobject]@{ Status = "timeout"; Milliseconds = $watch.ElapsedMilliseconds }
        }
        $client.EndConnect($async)
        return [pscustomobject]@{ Status = "connected"; Milliseconds = $watch.ElapsedMilliseconds }
    } catch {
        return [pscustomobject]@{ Status = "failed"; Milliseconds = $watch.ElapsedMilliseconds }
    } finally {
        $watch.Stop()
        $client.Dispose()
    }
}

$versionPath = Join-Path $appRoot "VERSION"
$version = if (Test-Path -LiteralPath $versionPath) {
    (Get-Content -Raw -LiteralPath $versionPath).Trim()
} else { "unknown" }
$mainConfigPath = Join-Path $appRoot "config\config.json"
$activeProfile = "unknown"
if (Test-Path -LiteralPath $mainConfigPath) {
    try {
        $activeProfile = [string](
            Get-Content -Raw -LiteralPath $mainConfigPath | ConvertFrom-Json
        ).activeProfile
    } catch {}
}
$catalogRevision = "none"
$enabledPacks = @()
$catalogLibrary = Join-Path $appRoot "tools\catalog-library.ps1"
if (Test-Path -LiteralPath $catalogLibrary) {
    . $catalogLibrary
    try {
        $domainCatalog = Get-TargetCatalog $appRoot
        if ($domainCatalog) {
            $catalogRevision = [string]$domainCatalog.revision
            $state = Get-DomainPackState $appRoot $domainCatalog
            $enabledPacks = @(
                $domainCatalog.packs |
                    Where-Object { $state.Enabled.Contains([string]$_.id) } |
                    ForEach-Object { [string]$_.id }
            )
        }
    } catch {}
}
$isAdmin = $false
try {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    $isAdmin = $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
} catch {}
$dnsServers = @()
try {
    $dnsServers = @(
        Get-DnsClientServer -AddressFamily IPv4 -ErrorAction Stop |
            ForEach-Object ServerAddresses |
            Where-Object { $_ } |
            Sort-Object -Unique
    )
} catch {}

$checks = @()
foreach ($domainValue in @($selected.domains)) {
    $domain = ([string]$domainValue).Trim().ToLowerInvariant()
    if ($domain -notmatch "^[a-z0-9.-]+$") {
        throw "Invalid domain in diagnostic target '$TargetId': $domain"
    }
    if ($NoNetwork) {
        $checks += [pscustomobject]@{
            Domain = $domain
            Addresses = @()
            DnsStatus = "skipped"
            DnsMilliseconds = 0
            Tcp443Status = "skipped"
            Tcp443Milliseconds = 0
        }
        continue
    }
    $addresses = @()
    $dnsWatch = [Diagnostics.Stopwatch]::StartNew()
    $dnsStatus = "resolved"
    try {
        $addresses = @(
            [Net.Dns]::GetHostAddresses($domain) |
                ForEach-Object ToString |
                Sort-Object -Unique
        )
        if (-not $addresses.Count) { $dnsStatus = "empty" }
    } catch {
        $dnsStatus = "failed"
    } finally {
        $dnsWatch.Stop()
    }
    $tcp = Test-TcpEndpoint $domain 443 4000
    $checks += [pscustomobject]@{
        Domain = $domain
        Addresses = $addresses
        DnsStatus = $dnsStatus
        DnsMilliseconds = $dnsWatch.ElapsedMilliseconds
        Tcp443Status = $tcp.Status
        Tcp443Milliseconds = $tcp.Milliseconds
    }
}

$observedHosts = @()
$logPath = Join-Path $appRoot "logs\winws2.log"
if (Test-Path -LiteralPath $logPath -PathType Leaf) {
    $seenHosts = New-Object "Collections.Generic.HashSet[string]" (
        [StringComparer]::OrdinalIgnoreCase
    )
    foreach ($line in Get-Content -LiteralPath $logPath -Tail 400 -ErrorAction SilentlyContinue) {
        foreach ($match in [regex]::Matches(
            [string]$line,
            "(?i)(?<![a-z0-9-])(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}(?![a-z0-9-])"
        )) {
            [void]$seenHosts.Add($match.Value.ToLowerInvariant())
        }
    }
    $observedHosts = @($seenHosts | Sort-Object)
}

$report = [ordered]@{
    schemaVersion = 1
    generatedAt = [DateTimeOffset]::Now.ToString("o")
    application = [ordered]@{
        version = $version
        catalogRevision = $catalogRevision
        enabledPacks = $enabledPacks
        activeProfile = $activeProfile
    }
    system = [ordered]@{
        os = [Environment]::OSVersion.VersionString
        powershell = $PSVersionTable.PSVersion.ToString()
        administrator = $isAdmin
        dnsServers = $dnsServers
    }
    target = [ordered]@{
        id = [string]$selected.id
        displayName = [string]$selected.displayName
        networkChecksSkipped = [bool]$NoNetwork
    }
    checks = $checks
    observedHostNames = $observedHosts
}

$outputRoot = if ($OutputDirectory) {
    [IO.Path]::GetFullPath($OutputDirectory)
} else {
    Join-Path $appRoot "test-results"
}
New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$baseName = "application-diagnostics-$($selected.id)-$stamp"
$jsonPath = Join-Path $outputRoot "$baseName.json"
$textPath = Join-Path $outputRoot "$baseName.txt"
$utf8 = [Text.UTF8Encoding]::new($false)
[IO.File]::WriteAllText(
    $jsonPath,
    ($report | ConvertTo-Json -Depth 12) + [Environment]::NewLine,
    $utf8
)
$lines = New-Object "Collections.Generic.List[string]"
$lines.Add("Traffic Profile Manager application diagnostics")
$lines.Add("Version: $version")
$lines.Add("Catalog: $catalogRevision")
$lines.Add("Profile: $activeProfile")
$lines.Add("Target: $($selected.displayName) [$($selected.id)]")
$lines.Add("Administrator: $isAdmin")
$lines.Add("DNS servers: $(if ($dnsServers.Count) { $dnsServers -join ', ' } else { 'not detected' })")
$lines.Add("")
$lines.Add("Domain checks:")
foreach ($check in $checks) {
    $addressText = if ($check.Addresses.Count) { $check.Addresses -join ", " } else { "-" }
    $lines.Add(
        "- $($check.Domain): DNS=$($check.DnsStatus) ($($check.DnsMilliseconds) ms), " +
        "TCP/443=$($check.Tcp443Status) ($($check.Tcp443Milliseconds) ms), addresses=$addressText"
    )
}
$lines.Add("")
$lines.Add("Observed host names in the recent local log: $($observedHosts.Count)")
foreach ($name in $observedHosts) { $lines.Add("- $name") }
[IO.File]::WriteAllLines($textPath, $lines, $utf8)

Write-Host ""
Write-Host "Diagnostic reports created." -ForegroundColor Green
Write-Host "Text: $textPath"
Write-Host "JSON: $jsonPath"
