$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$testRoot = Join-Path $projectRoot "tests\.tmp-smoke"
$cli = Join-Path $projectRoot "zapretctl.ps1"

function Invoke-Cli([string[]]$CliArgs) {
    $output = & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $cli @CliArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed: $($CliArgs -join ' ')`n$($output -join [Environment]::NewLine)"
    }
    return @($output)
}

$resolvedProject = [IO.Path]::GetFullPath($projectRoot)
$resolvedTest = [IO.Path]::GetFullPath($testRoot)
if (-not $resolvedTest.StartsWith($resolvedProject + [IO.Path]::DirectorySeparatorChar)) {
    throw "Unsafe test directory."
}

try {
    if (Test-Path -LiteralPath $resolvedTest) {
        Remove-Item -LiteralPath $resolvedTest -Recurse -Force
    }
    $env:ZAPRETCTL_HOME = $resolvedTest

    Invoke-Cli @("init") | Out-Null
    $idn = -join ([char[]](0x043F, 0x0440, 0x0438, 0x043C, 0x0435, 0x0440, 0x002E, 0x0440, 0x0444))
    Invoke-Cli @("domain", "add", $idn) | Out-Null
    Invoke-Cli @("domain", "add", $idn) | Out-Null
    Invoke-Cli @("domain", "import", (Join-Path $projectRoot "tests\fixtures\domains.txt")) | Out-Null
    Invoke-Cli @("domain", "exclude", "example.com") | Out-Null
    Invoke-Cli @("ip", "add", "203.0.113.0/24") | Out-Null
    Invoke-Cli @("ip", "add", "2001:db8::1") | Out-Null

    $domains = @(Invoke-Cli @("domain", "list"))
    if ($domains.Count -ne 3) { throw "Expected 3 unique domains, got $($domains.Count)." }
    if ($domains -notcontains "xn--e1afmkfd.xn--p1ai") { throw "IDN normalization failed." }

    New-Item `
        -ItemType Directory `
        -Path (Join-Path $resolvedTest "config\profiles") `
        -Force | Out-Null
    New-Item `
        -ItemType Directory `
        -Path (Join-Path $resolvedTest "assets") `
        -Force | Out-Null
    Copy-Item `
        -LiteralPath (Join-Path $projectRoot "config\profiles\strategy-wa-pc-pos1.json") `
        -Destination (Join-Path $resolvedTest "config\profiles\strategy-wa-pc-pos1.json")
    foreach ($asset in @(
        "ACTIVE_DISCORD_UDP.bin"
        "stun.bin"
        "tls_clienthello_www_google_com.bin"
    )) {
        Copy-Item `
            -LiteralPath (Join-Path $projectRoot "assets\$asset") `
            -Destination (Join-Path $resolvedTest "assets\$asset")
    }

    $render = (Invoke-Cli @("render")) -join "`n"
    foreach ($expected in @("--hostlist=", "--hostlist-exclude=", "--ipset=", "--new=http-ip")) {
        if (-not $render.Contains($expected)) { throw "Rendered command misses $expected." }
    }

    $mappingTool = Join-Path $projectRoot "manage-network-mappings.ps1"
    $testHosts = Join-Path $resolvedTest "hosts"
    Copy-Item `
        -LiteralPath (Join-Path $projectRoot "tests\fixtures\hosts-test.txt") `
        -Destination $testHosts
    & powershell.exe `
        -NoLogo `
        -NoProfile `
        -ExecutionPolicy Bypass `
        -File $mappingTool `
        install `
        -HostsPath $testHosts | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Mapping installation failed." }
    $hostsContent = [IO.File]::ReadAllText($testHosts)
    if (-not $hostsContent.Contains("# TrafficProfileManager Mapping BEGIN")) {
        throw "Managed mapping block was not added."
    }
    if (-not $hostsContent.Contains("203.0.113.10 unrelated.example")) {
        throw "Mapping installation changed an unrelated hosts entry."
    }

    & powershell.exe `
        -NoLogo `
        -NoProfile `
        -ExecutionPolicy Bypass `
        -File $mappingTool `
        cleanup `
        -HostsPath $testHosts | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Mapping cleanup failed." }
    $hostsContent = [IO.File]::ReadAllText($testHosts)
    if ($hostsContent.Contains("# TrafficProfileManager Mapping BEGIN")) {
        throw "Managed mapping block was not removed."
    }
    if (-not $hostsContent.Contains("203.0.113.10 unrelated.example")) {
        throw "Mapping cleanup changed an unrelated hosts entry."
    }

    $incompleteHosts = $hostsContent.TrimEnd() +
        [Environment]::NewLine +
        "# TrafficProfileManager Mapping BEGIN" +
        [Environment]::NewLine
    [IO.File]::WriteAllText(
        $testHosts,
        $incompleteHosts,
        [Text.UTF8Encoding]::new($false)
    )
    $guardTriggered = $false
    try {
        & $mappingTool cleanup -HostsPath $testHosts | Out-Null
    } catch {
        $guardTriggered = $true
    }
    if (-not $guardTriggered) {
        throw "Incomplete mapping block was not rejected."
    }
    if ([IO.File]::ReadAllText($testHosts) -ne $incompleteHosts) {
        throw "Incomplete mapping guard changed the hosts file."
    }

    Write-Host "Smoke test passed." -ForegroundColor Green
} finally {
    Remove-Item Env:ZAPRETCTL_HOME -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $resolvedTest) {
        Remove-Item -LiteralPath $resolvedTest -Recurse -Force
    }
}
