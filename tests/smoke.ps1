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

function Get-AclSemanticSignature([string]$Path) {
    $acl = Get-Acl -LiteralPath $Path
    $rules = @(
        $acl.Access |
            ForEach-Object {
                "{0}|{1}|{2}|{3}|{4}|{5}" -f @(
                    $_.IdentityReference.Value,
                    $_.AccessControlType,
                    [int]$_.FileSystemRights,
                    [int]$_.InheritanceFlags,
                    [int]$_.PropagationFlags,
                    $_.IsInherited
                )
            } |
            Sort-Object
    )
    return @(
        [string]$acl.Owner
        [string]$acl.Group
        [string]$acl.AreAccessRulesProtected
        $rules
    ) -join [Environment]::NewLine
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
    $userListPaths = @(
        "lists\user-domains.txt"
        "lists\user-domains-exclude.txt"
        "lists\user-ips.txt"
        "lists\user-ips-exclude.txt"
    )
    $preservedUserList = Join-Path $resolvedTest "lists\user-domains.txt"
    $preservedContent = (
        "# Existing custom list." + [Environment]::NewLine +
        "# It must not be overwritten." + [Environment]::NewLine
    )
    [IO.File]::WriteAllText(
        $preservedUserList,
        $preservedContent,
        [Text.UTF8Encoding]::new($false)
    )
    foreach ($relativePath in $userListPaths | Select-Object -Skip 1) {
        Remove-Item -LiteralPath (Join-Path $resolvedTest $relativePath) -Force
    }
    Invoke-Cli @("profile", "list") | Out-Null
    foreach ($relativePath in $userListPaths) {
        if (
            -not (Test-Path -LiteralPath (
                Join-Path $resolvedTest $relativePath
            ) -PathType Leaf)
        ) {
            throw "Missing user list was not initialized: $relativePath"
        }
    }
    if ([IO.File]::ReadAllText($preservedUserList) -ne $preservedContent) {
        throw "Existing user list was overwritten during initialization."
    }

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
        "ACTIVE_GAME_UDP.bin"
        "stun.bin"
        "tls_clienthello_www_google_com.bin"
    )) {
        Copy-Item `
            -LiteralPath (Join-Path $projectRoot "assets\$asset") `
            -Destination (Join-Path $resolvedTest "assets\$asset")
    }

    $missingBeforeRender = Join-Path (
        Join-Path $resolvedTest "lists"
    ) "user-domains-exclude.txt"
    Remove-Item -LiteralPath $missingBeforeRender -Force
    $preservedBeforeRender = [IO.File]::ReadAllBytes($preservedUserList)
    $render = (Invoke-Cli @("render")) -join "`n"
    if (-not (Test-Path -LiteralPath $missingBeforeRender -PathType Leaf)) {
        throw "Profile rendering did not initialize a missing user list."
    }
    if (
        -not [Linq.Enumerable]::SequenceEqual(
            [byte[]]$preservedBeforeRender,
            [byte[]][IO.File]::ReadAllBytes($preservedUserList)
        )
    ) {
        throw "Profile rendering changed an existing user list."
    }
    foreach ($expected in @("--hostlist=", "--hostlist-exclude=", "--ipset=", "--new=http-ip")) {
        if (-not $render.Contains($expected)) { throw "Rendered command misses $expected." }
    }
    . (Join-Path $projectRoot "tools\profile-library.ps1")
    $profilePath = Join-Path (
        Join-Path $resolvedTest "config\profiles"
    ) "strategy-wa-pc-pos1.json"
    $unsafeProfile = Get-Content -Raw -LiteralPath $profilePath |
        ConvertFrom-Json
    $unsafeProfile.blobs[0].path = "lists\domains.txt"
    $outsideAssetRejected = $false
    try {
        [void](Test-TrafficProfileDefinition `
            $unsafeProfile `
            $profilePath `
            $resolvedTest)
    } catch {
        $outsideAssetRejected = $true
    }
    if (-not $outsideAssetRejected) {
        throw "Profile accepted a blob outside the assets directory."
    }

    $mappingTool = Join-Path $projectRoot "manage-network-mappings.ps1"
    $testHosts = Join-Path $resolvedTest "hosts"
    $gameFilterPath = Join-Path $resolvedTest "config\game-filters\test-game"
    New-Item -ItemType Directory -Path $gameFilterPath -Force | Out-Null
    [IO.File]::WriteAllText(
        (Join-Path $gameFilterPath "filter.json"),
        @'
{
  "schemaVersion": 2,
  "id": "test-game",
  "displayName": "Test Game",
  "description": "Smoke-test filter.",
  "transport": {
    "mode": "all",
    "preset": "balanced",
    "tcpPorts": "12000-12010",
    "udpPorts": "22000-22010",
    "udpFake": "assets\\ACTIVE_GAME_UDP.bin"
  }
}
'@,
        [Text.UTF8Encoding]::new($false)
    )
    $gameFiles = @{
        "hosts.txt" = "198.51.100.44 signon.test-game.example"
        "domains.txt" = "test-game.example"
        "ips.txt" = "198.51.100.44/32"
        "domains-exclude.txt" = "# No exclusions"
        "ips-exclude.txt" = "# No exclusions"
    }
    foreach ($item in $gameFiles.GetEnumerator()) {
        [IO.File]::WriteAllText(
            (Join-Path $gameFilterPath $item.Key),
            $item.Value + [Environment]::NewLine,
            [Text.UTF8Encoding]::new($false)
        )
    }
    [IO.File]::WriteAllText(
        (Join-Path $resolvedTest "state\enabled-game-filters.txt"),
        "test-game" + [Environment]::NewLine,
        [Text.UTF8Encoding]::new($false)
    )
    $gameManager = Join-Path $projectRoot "tools\game-filter-manager.ps1"
    & powershell.exe `
        -NoLogo `
        -NoProfile `
        -ExecutionPolicy Bypass `
        -File $gameManager `
        disable `
        test-game `
        -RootPath $resolvedTest | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Game filter disable failed." }
    $enabledState = [string](Get-Content -Raw -LiteralPath (
        Join-Path $resolvedTest "state\enabled-game-filters.txt"
    ))
    if (-not [string]::IsNullOrWhiteSpace($enabledState)) {
        throw "Disabled game filter remained in local state."
    }
    & powershell.exe `
        -NoLogo `
        -NoProfile `
        -ExecutionPolicy Bypass `
        -File $gameManager `
        enable `
        test-game `
        -RootPath $resolvedTest | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Game filter enable failed." }

    $gameRender = (Invoke-Cli @("render")) -join "`n"
    foreach ($expected in @(
        "config\game-filters\test-game\domains.txt",
        "config\game-filters\test-game\ips.txt",
        "--wf-tcp-out=80,443,2053,2083,2087,2096,8443,12000-12010",
        "--wf-udp-out=443,19294-19344,22000-22010,50000-50100",
        "--blob=tpm_game_udp_test_game:",
        "--new=tpm-game-test-game-tcp",
        "--filter-tcp=12000-12010",
        "--new=tpm-game-test-game-udp",
        "--filter-udp=22000-22010",
        "--lua-desync=fake:blob=tpm_game_udp_test_game:payload=~empty:repeats=4"
    )) {
        if (-not $gameRender.Contains($expected)) {
            throw "Rendered command misses enabled game filter path: $expected"
        }
    }

    . (Join-Path $projectRoot "tools\game-filter-library.ps1")
    if (
        (ConvertTo-GameFilterPortExpression (
            "443,12000-12010,12005-12020"
        )) -ne "443,12000-12020"
    ) {
        throw "Game transport port normalization failed."
    }
    $emptyIps = Join-Path $resolvedTest "empty-game-ips.txt"
    [IO.File]::WriteAllText(
        $emptyIps,
        "# Empty by design" + [Environment]::NewLine,
        [Text.UTF8Encoding]::new($false)
    )
    $unsafeTransport = [pscustomobject]@{
        transport = [pscustomobject]@{
            mode = "udp"
            preset = "balanced"
            udpPorts = "22000-22010"
            udpFake = "assets\ACTIVE_GAME_UDP.bin"
        }
    }
    $emptyIpRejected = $false
    try {
        [void](Get-GameFilterTransport (
            $unsafeTransport
        ) $resolvedTest $emptyIps)
    } catch {
        $emptyIpRejected = $true
    }
    if (-not $emptyIpRejected) {
        throw "Transport without an IP scope was accepted."
    }
    $unsafeTransport.transport.udpFake = "..\outside.bin"
    $unsafePathRejected = $false
    try {
        [void](Get-GameFilterTransport (
            $unsafeTransport
        ) $resolvedTest (Join-Path $gameFilterPath "ips.txt"))
    } catch {
        $unsafePathRejected = $true
    }
    if (-not $unsafePathRejected) {
        throw "Transport accepted a UDP fake outside the program folder."
    }

    Copy-Item `
        -LiteralPath (Join-Path $projectRoot "tests\fixtures\hosts-test.txt") `
        -Destination $testHosts
    $hostsAcl = Get-AclSemanticSignature $testHosts
    & powershell.exe `
        -NoLogo `
        -NoProfile `
        -ExecutionPolicy Bypass `
        -File $mappingTool `
        install `
        -AppRoot $resolvedTest `
        -HostsPath $testHosts | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Mapping installation failed." }
    $hostsContent = [IO.File]::ReadAllText($testHosts)
    if (-not $hostsContent.Contains("# TrafficProfileManager Mapping BEGIN")) {
        throw "Managed mapping block was not added."
    }
    if (-not $hostsContent.Contains("203.0.113.10 unrelated.example")) {
        throw "Mapping installation changed an unrelated hosts entry."
    }
    if (-not $hostsContent.Contains(
        "198.51.100.44`tsignon.test-game.example"
    )) {
        throw "Enabled game filter mapping was not added."
    }
    & powershell.exe `
        -NoLogo `
        -NoProfile `
        -ExecutionPolicy Bypass `
        -File $mappingTool `
        install `
        -AppRoot $resolvedTest `
        -HostsPath $testHosts | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Repeated mapping installation failed." }
    $hostsContent = [IO.File]::ReadAllText($testHosts)
    if (
        ([regex]::Matches(
            $hostsContent,
            [regex]::Escape("# TrafficProfileManager Mapping BEGIN")
        )).Count -ne 1
    ) {
        throw "Repeated mapping installation duplicated the managed block."
    }
    if ((Get-AclSemanticSignature $testHosts) -ne $hostsAcl) {
        throw "Mapping installation changed the hosts ACL."
    }

    & powershell.exe `
        -NoLogo `
        -NoProfile `
        -ExecutionPolicy Bypass `
        -File $mappingTool `
        cleanup `
        -AppRoot $resolvedTest `
        -HostsPath $testHosts | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Mapping cleanup failed." }
    $hostsContent = [IO.File]::ReadAllText($testHosts)
    if ($hostsContent.Contains("# TrafficProfileManager Mapping BEGIN")) {
        throw "Managed mapping block was not removed."
    }
    if (-not $hostsContent.Contains("203.0.113.10 unrelated.example")) {
        throw "Mapping cleanup changed an unrelated hosts entry."
    }
    if ((Get-AclSemanticSignature $testHosts) -ne $hostsAcl) {
        throw "Mapping cleanup changed the hosts ACL."
    }
    $leftovers = @(
        Get-ChildItem -LiteralPath (Split-Path -Parent $testHosts) -File |
            Where-Object {
                $_.Name -like "hosts.*.tmp" -or
                $_.Name -like "hosts.*.backup"
            }
    )
    if ($leftovers.Count) {
        throw "Atomic hosts update left temporary or backup files behind."
    }

    $utf16Hosts = Join-Path $resolvedTest "hosts-utf16"
    [IO.File]::WriteAllText(
        $utf16Hosts,
        "127.0.0.1 localhost`r`n",
        [Text.UnicodeEncoding]::new($false, $true)
    )
    & $mappingTool install -AppRoot $resolvedTest -HostsPath $utf16Hosts |
        Out-Null
    & $mappingTool cleanup -AppRoot $resolvedTest -HostsPath $utf16Hosts |
        Out-Null
    $utf16Bytes = [IO.File]::ReadAllBytes($utf16Hosts)
    if (
        $utf16Bytes.Length -lt 2 -or
        $utf16Bytes[0] -ne 0xFF -or
        $utf16Bytes[1] -ne 0xFE
    ) {
        throw "Hosts encoding was not preserved."
    }
    if (-not [IO.File]::ReadAllText($utf16Hosts).Contains("localhost")) {
        throw "UTF-16 hosts content was not preserved."
    }

    $conflictPath = Join-Path $resolvedTest "config\game-filters\conflict-game"
    New-Item -ItemType Directory -Path $conflictPath -Force | Out-Null
    [IO.File]::WriteAllText(
        (Join-Path $conflictPath "filter.json"),
        @'
{
  "schemaVersion": 1,
  "id": "conflict-game",
  "displayName": "Conflict Game",
  "description": "Smoke-test conflict."
}
'@,
        [Text.UTF8Encoding]::new($false)
    )
    foreach ($item in @{
        "hosts.txt" = "198.51.100.45 signon.test-game.example"
        "domains.txt" = "# No domains"
        "ips.txt" = "# No addresses"
        "domains-exclude.txt" = "# No exclusions"
        "ips-exclude.txt" = "# No exclusions"
    }.GetEnumerator()) {
        [IO.File]::WriteAllText(
            (Join-Path $conflictPath $item.Key),
            $item.Value + [Environment]::NewLine,
            [Text.UTF8Encoding]::new($false)
        )
    }
    [IO.File]::WriteAllText(
        (Join-Path $resolvedTest "state\enabled-game-filters.txt"),
        "test-game`r`nconflict-game`r`n",
        [Text.UTF8Encoding]::new($false)
    )
    $beforeConflict = [IO.File]::ReadAllText($testHosts)
    $conflictRejected = $false
    try {
        & $mappingTool install -AppRoot $resolvedTest -HostsPath $testHosts |
            Out-Null
    } catch {
        $conflictRejected = $true
    }
    if (-not $conflictRejected) {
        throw "Conflicting enabled game mappings were accepted."
    }
    if ([IO.File]::ReadAllText($testHosts) -ne $beforeConflict) {
        throw "Conflict guard changed the hosts file."
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
        & $mappingTool cleanup -AppRoot $resolvedTest -HostsPath $testHosts |
            Out-Null
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
