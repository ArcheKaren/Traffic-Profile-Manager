[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Command = "help",

    [Parameter(Position = 1)]
    [string]$Arg1,

    [Parameter(Position = 2)]
    [string]$Arg2,

    [Parameter(Position = 3)]
    [string]$Arg3
)

$ErrorActionPreference = "Stop"
$CommandArgs = @(
    @($Arg1, $Arg2, $Arg3) | Where-Object { -not [string]::IsNullOrEmpty($_) }
)
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:AppRoot = if ($env:ZAPRETCTL_HOME) {
    [IO.Path]::GetFullPath($env:ZAPRETCTL_HOME)
} else {
    Split-Path -Parent $MyInvocation.MyCommand.Path
}

. (Join-Path $PSScriptRoot "tools\game-filter-library.ps1")

function Get-AppPath([string]$RelativePath) {
    return [IO.Path]::GetFullPath((Join-Path $script:AppRoot $RelativePath))
}

function Write-AtomicLines([string]$Path, [string[]]$Lines) {
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $temporary = "$Path.$PID.tmp"
    [IO.File]::WriteAllLines($temporary, $Lines, $script:Utf8NoBom)
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function Write-AtomicText([string]$Path, [string]$Text) {
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $temporary = "$Path.$PID.tmp"
    [IO.File]::WriteAllText($temporary, $Text, $script:Utf8NoBom)
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function Write-JsonFile([string]$Path, $Value) {
    Write-AtomicText $Path (($Value | ConvertTo-Json -Depth 20) + [Environment]::NewLine)
}

function Read-JsonFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "File not found: $Path. Run 'zapretctl init' first."
    }
    return Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
}

function Initialize-App {
    foreach ($directory in @(
        "config",
        "config\profiles",
        "config\game-filters",
        "lists",
        "logs",
        "runtime",
        "state"
    )) {
        New-Item -ItemType Directory -Path (Get-AppPath $directory) -Force | Out-Null
    }

    $configPath = Get-AppPath "config\config.json"
    if (-not (Test-Path -LiteralPath $configPath)) {
        $config = [ordered]@{
            activeProfile = "strategy-wa-pc-pos1"
            runtimePath = ""
            allowAllWithoutTargets = $false
            autoHostlist = $false
            debug = $true
        }
        Write-JsonFile $configPath $config
    }

    $listHeaders = [ordered]@{
        "lists\domains.txt" = @("# Domains handled by zapret2. One domain per line.", "# example.org")
        "lists\user-domains.txt" = @("# Custom domains. One domain per line.", "# example.org")
        "lists\domains-exclude.txt" = @("# Excluded domains. One domain per line.")
        "lists\user-domains-exclude.txt" = @("# Custom domain exclusions. One domain per line.", "# example.org")
        "lists\domains-auto.txt" = @("# Auto-detected domains. Do not edit while winws2 is running.")
        "lists\ips.txt" = @("# IPv4, IPv6 or CIDR handled by zapret2. One entry per line.", "# 203.0.113.0/24")
        "lists\user-ips.txt" = @("# Custom IPv4, IPv6, and CIDR values. One entry per line.", "# 203.0.113.0/24")
        "lists\ips-exclude.txt" = @("# Excluded IP/CIDR entries. One entry per line.")
        "lists\user-ips-exclude.txt" = @("# Custom IP/CIDR exclusions. One entry per line.", "# 203.0.113.0/24")
    }
    foreach ($item in $listHeaders.GetEnumerator()) {
        $path = Get-AppPath $item.Key
        if (-not (Test-Path -LiteralPath $path)) {
            Write-AtomicLines $path $item.Value
        }
    }

    Write-Host "Ready: $script:AppRoot"
    Write-Host "Add a target: zapretctl domain add example.org"
    Write-Host "Place the official Windows bundle in runtime and run: zapretctl doctor"
}

function Ensure-Initialized {
    if (-not (Test-Path -LiteralPath (Get-AppPath "config\config.json"))) {
        throw "The project is not initialized. Run 'zapretctl init'."
    }
}

function Get-MeaningfulLines([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    return @(
        Get-Content -LiteralPath $Path |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -and -not $_.StartsWith("#") }
    )
}

function Normalize-Domain([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { throw "A domain is required." }
    $domain = $Value.Trim().ToLowerInvariant()
    $exact = $domain.StartsWith("^")
    if ($exact) { $domain = $domain.Substring(1) }
    $domain = $domain.TrimEnd(".")
    if ($domain.Contains("://") -or $domain.Contains("/") -or $domain.Contains(":") -or $domain.Contains("*")) {
        throw "'$Value' is not a domain. Enter a name without a scheme, path, port, or '*'."
    }
    try {
        $domain = (New-Object Globalization.IdnMapping).GetAscii($domain)
    } catch {
        throw "Invalid domain name: $Value"
    }
    if ($domain.Length -gt 253 -or $domain -notmatch "^[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?$") {
        throw "Invalid domain name: $Value"
    }
    foreach ($label in $domain.Split(".")) {
        if (-not $label -or $label.Length -gt 63 -or $label.StartsWith("-") -or $label.EndsWith("-")) {
            throw "Invalid domain name: $Value"
        }
    }
    return $(if ($exact) { "^$domain" } else { $domain })
}

function Normalize-IpNetwork([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { throw "An IP address or CIDR is required." }
    $candidate = $Value.Trim()
    $parts = $candidate.Split("/")
    if ($parts.Count -gt 2) { throw "Invalid IP/CIDR: $Value" }
    $address = $null
    if (-not [Net.IPAddress]::TryParse($parts[0], [ref]$address)) {
        throw "Invalid IP address: $Value"
    }
    if ($parts.Count -eq 1) { return $address.ToString().ToLowerInvariant() }
    $prefix = 0
    if (-not [int]::TryParse($parts[1], [ref]$prefix)) {
        throw "Invalid CIDR prefix length: $Value"
    }
    $maximum = if ($address.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork) { 32 } else { 128 }
    if ($prefix -lt 0 -or $prefix -gt $maximum) {
        throw "The CIDR prefix length for this address must be between 0 and $maximum."
    }
    return "$($address.ToString().ToLowerInvariant())/$prefix"
}

function Get-ListPath([string]$Kind, [bool]$Exclude) {
    if ($Kind -eq "domain") {
        return Get-AppPath $(if ($Exclude) { "lists\domains-exclude.txt" } else { "lists\user-domains.txt" })
    }
    return Get-AppPath $(if ($Exclude) { "lists\ips-exclude.txt" } else { "lists\user-ips.txt" })
}

function Normalize-ListValue([string]$Kind, [string]$Value) {
    if ($Kind -eq "domain") { return Normalize-Domain $Value }
    return Normalize-IpNetwork $Value
}

function Add-ListValue([string]$Kind, [string]$Value, [bool]$Exclude) {
    $path = Get-ListPath $Kind $Exclude
    $normalized = Normalize-ListValue $Kind $Value
    $lines = @(if (Test-Path -LiteralPath $path) { Get-Content -LiteralPath $path })
    if ($lines | Where-Object { $_.Trim().ToLowerInvariant() -eq $normalized.ToLowerInvariant() }) {
        Write-Host "Already present: $normalized"
        return
    }
    Write-AtomicLines $path @($lines + $normalized)
    Write-Host "Added: $normalized"
}

function Remove-ListValue([string]$Kind, [string]$Value, [bool]$Exclude) {
    $path = Get-ListPath $Kind $Exclude
    $normalized = Normalize-ListValue $Kind $Value
    $found = $false
    $lines = @(
        Get-Content -LiteralPath $path | Where-Object {
            if ($_.Trim().ToLowerInvariant() -eq $normalized.ToLowerInvariant()) {
                $found = $true
                return $false
            }
            return $true
        }
    )
    if (-not $found) {
        Write-Host "Not found: $normalized"
        return
    }
    Write-AtomicLines $path $lines
    Write-Host "Removed: $normalized"
}

function Import-List([string]$Kind, [string]$Source, [bool]$Exclude) {
    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) {
        throw "Import file not found: $Source"
    }
    $path = Get-ListPath $Kind $Exclude
    $existingLines = @(Get-Content -LiteralPath $path)
    $known = @{}
    foreach ($line in $existingLines) {
        $trimmed = $line.Trim()
        if ($trimmed -and -not $trimmed.StartsWith("#")) { $known[$trimmed.ToLowerInvariant()] = $true }
    }
    $added = New-Object Collections.Generic.List[string]
    $lineNumber = 0
    foreach ($line in Get-Content -LiteralPath $Source) {
        $lineNumber++
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith("#")) { continue }
        try {
            $normalized = Normalize-ListValue $Kind $trimmed
        } catch {
            throw "Error in '$Source', line $lineNumber`: $($_.Exception.Message)"
        }
        $key = $normalized.ToLowerInvariant()
        if (-not $known.ContainsKey($key)) {
            $known[$key] = $true
            $added.Add($normalized)
        }
    }
    $combined = New-Object Collections.Generic.List[string]
    foreach ($existingValue in $existingLines) { $combined.Add([string]$existingValue) }
    foreach ($newValue in $added) { $combined.Add([string]$newValue) }
    Write-AtomicLines $path $combined.ToArray()
    Write-Host "New entries imported: $($added.Count)"
}

function Invoke-ListCommand([string]$Kind, [string[]]$InputArgs) {
    Ensure-Initialized
    if (-not $InputArgs -or $InputArgs.Count -eq 0) {
        throw "Specify an action: add, remove, list, exclude, or import."
    }
    $action = $InputArgs[0].ToLowerInvariant()
    switch ($action) {
        "add" {
            if ($InputArgs.Count -lt 2) { throw "Specify a value." }
            Add-ListValue $Kind $InputArgs[1] $false
        }
        "remove" {
            if ($InputArgs.Count -lt 2) { throw "Specify a value." }
            Remove-ListValue $Kind $InputArgs[1] $false
        }
        "exclude" {
            if ($InputArgs.Count -lt 2) { throw "Specify a value." }
            $subAction = if ($InputArgs.Count -ge 3) { $InputArgs[1].ToLowerInvariant() } else { "add" }
            $valueIndex = if ($InputArgs.Count -ge 3) { 2 } else { 1 }
            if ($subAction -eq "remove") {
                Remove-ListValue $Kind $InputArgs[$valueIndex] $true
            } elseif ($subAction -eq "add") {
                Add-ListValue $Kind $InputArgs[$valueIndex] $true
            } else {
                throw "The exclude action accepts add or remove."
            }
        }
        "list" {
            $exclude = $InputArgs -contains "--exclude"
            $values = @(Get-MeaningfulLines (Get-ListPath $Kind $exclude))
            if ($values.Count -eq 0) { Write-Host "(list is empty)"; return }
            $values | ForEach-Object { Write-Output $_ }
        }
        "import" {
            if ($InputArgs.Count -lt 2) { throw "Specify an import file." }
            Import-List $Kind $InputArgs[1] ($InputArgs -contains "--exclude")
        }
        default { throw "Unknown action '$action'." }
    }
}

function Get-Config {
    return Read-JsonFile (Get-AppPath "config\config.json")
}

function Save-Config($Config) {
    Write-JsonFile (Get-AppPath "config\config.json") $Config
}

function Get-ActiveProfile {
    $config = Get-Config
    $path = Get-AppPath "config\profiles\$($config.activeProfile).json"
    return Read-JsonFile $path
}

function Invoke-ProfileCommand([string[]]$InputArgs) {
    Ensure-Initialized
    $action = if ($InputArgs -and $InputArgs.Count) { $InputArgs[0].ToLowerInvariant() } else { "list" }
    switch ($action) {
        "list" {
            $config = Get-Config
            Get-ChildItem -LiteralPath (Get-AppPath "config\profiles") -Filter "*.json" | ForEach-Object {
                $marker = if ($_.BaseName -eq $config.activeProfile) { "*" } else { " " }
                Write-Output "$marker $($_.BaseName)"
            }
        }
        "use" {
            if ($InputArgs.Count -lt 2) { throw "Specify a profile name." }
            $name = $InputArgs[1]
            if ($name -notmatch "^[a-zA-Z0-9_-]+$") { throw "Invalid profile name." }
            if (-not (Test-Path -LiteralPath (Get-AppPath "config\profiles\$name.json"))) {
                throw "Profile '$name' was not found."
            }
            $config = Get-Config
            $config.activeProfile = $name
            Save-Config $config
            Write-Host "Active profile: $name"
        }
        "show" {
            $profile = if ($InputArgs.Count -ge 2) {
                Read-JsonFile (Get-AppPath "config\profiles\$($InputArgs[1]).json")
            } else {
                Get-ActiveProfile
            }
            $profile | ConvertTo-Json -Depth 20
        }
        default { throw "Unknown profile action '$action'." }
    }
}

function Find-RuntimeExecutable {
    $config = Get-Config
    if ($config.runtimePath) {
        $configured = if ([IO.Path]::IsPathRooted([string]$config.runtimePath)) {
            [string]$config.runtimePath
        } else {
            Get-AppPath ([string]$config.runtimePath)
        }
        if (Test-Path -LiteralPath $configured -PathType Leaf) { return [IO.Path]::GetFullPath($configured) }
    }
    $candidates = @(
        (Get-AppPath "runtime\winws2.exe"),
        (Get-AppPath "runtime\zapret-winws\winws2.exe"),
        (Get-AppPath "runtime\zapret-win-bundle-master\zapret-winws\winws2.exe")
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    $found = Get-ChildItem -LiteralPath (Get-AppPath "runtime") -Filter "winws2.exe" -File -Recurse -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($found) { return $found.FullName }
    return $null
}

function Find-RuntimeFile([string]$Name, [string]$Executable) {
    if ($Executable) {
        $near = Join-Path (Split-Path -Parent $Executable) $Name
        if (Test-Path -LiteralPath $near -PathType Leaf) { return $near }
        $luaNear = Join-Path (Split-Path -Parent $Executable) "lua\$Name"
        if (Test-Path -LiteralPath $luaNear -PathType Leaf) { return $luaNear }
    }
    $found = Get-ChildItem -LiteralPath (Get-AppPath "runtime") -Filter $Name -File -Recurse -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($found) { return $found.FullName }
    return $null
}

function Test-IsAdministrator {
    if ($env:OS -ne "Windows_NT") { return $true }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Add-ProfileArguments(
    [Collections.Generic.List[string]]$Result,
    $Profile,
    [string]$TargetKind,
    [ref]$IsFirst
) {
    $domainLists = @(
        Get-AppPath "lists\domains.txt"
        Get-AppPath "lists\user-domains.txt"
    )
    $domainLists += @(
        Get-EnabledGameFilterListPaths $script:AppRoot "domain"
    )
    if ($env:TRAFFIC_PROFILE_BENCHMARK_LIST) {
        $benchmarkList = [IO.Path]::GetFullPath($env:TRAFFIC_PROFILE_BENCHMARK_LIST)
        $appRootPrefix = $script:AppRoot.TrimEnd("\") + "\"
        if ($benchmarkList.StartsWith($appRootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            $domainLists += $benchmarkList
        }
    }
    $domainExcludes = @(
        Get-AppPath "lists\domains-exclude.txt"
        Get-AppPath "lists\user-domains-exclude.txt"
    )
    $domainExcludes += @(
        Get-EnabledGameFilterListPaths $script:AppRoot "domain-exclude"
    )
    $autoList = Get-AppPath "lists\domains-auto.txt"
    $ipLists = @(
        Get-AppPath "lists\ips.txt"
        Get-AppPath "lists\user-ips.txt"
    )
    $ipLists += @(
        Get-EnabledGameFilterListPaths $script:AppRoot "ip"
    )
    $ipExcludes = @(
        Get-AppPath "lists\ips-exclude.txt"
        Get-AppPath "lists\user-ips-exclude.txt"
    )
    $ipExcludes += @(
        Get-EnabledGameFilterListPaths $script:AppRoot "ip-exclude"
    )
    $config = Get-Config

    foreach ($rule in $Profile.rules) {
        $scope = if ($rule.PSObject.Properties.Name -contains "scope") { [string]$rule.scope } else { "targets" }
        if ($TargetKind -eq "first" -and $scope -ne "first") { continue }
        if ($TargetKind -eq "all" -and $scope -ne "all") { continue }
        if ($TargetKind -ne "first" -and $TargetKind -ne "all" -and $scope -in @("first", "all")) { continue }

        $profileName = "$($rule.name)-$TargetKind"
        if ($IsFirst.Value) {
            $Result.Add("--name=$profileName")
            $IsFirst.Value = $false
        } else {
            $Result.Add("--new=$profileName")
        }
        foreach ($argument in $rule.match) {
            $expandedArgument = ([string]$argument).Replace("{app}", $script:AppRoot)
            $Result.Add($expandedArgument)
        }
        if ($TargetKind -eq "domain") {
            foreach ($domainList in $domainLists) {
                if (Test-Path -LiteralPath $domainList -PathType Leaf) {
                    $Result.Add("--hostlist=$domainList")
                }
            }
            foreach ($domainExclude in $domainExcludes) {
                if ((Get-MeaningfulLines $domainExclude).Count -gt 0) {
                    $Result.Add("--hostlist-exclude=$domainExclude")
                }
            }
            if ($config.autoHostlist) {
                $Result.Add("--hostlist-auto=$autoList")
            }
        } elseif ($TargetKind -eq "ip") {
            foreach ($ipList in $ipLists) {
                if (Test-Path -LiteralPath $ipList -PathType Leaf) {
                    $Result.Add("--ipset=$ipList")
                }
            }
            foreach ($ipExclude in $ipExcludes) {
                if ((Get-MeaningfulLines $ipExclude).Count -gt 0) {
                    $Result.Add("--ipset-exclude=$ipExclude")
                }
            }
        }
        foreach ($argument in $rule.actions) {
            $expandedArgument = ([string]$argument).Replace("{app}", $script:AppRoot)
            $Result.Add($expandedArgument)
        }
    }
}

function Add-GameTransportArguments(
    [Collections.Generic.List[string]]$Result,
    [object[]]$Transports,
    [ref]$IsFirst
) {
    $globalExcludes = @(
        Get-AppPath "lists\ips-exclude.txt"
        Get-AppPath "lists\user-ips-exclude.txt"
    )
    foreach ($filter in $Transports) {
        $transport = $filter.Transport
        $id = ([string]$filter.Id).Replace("-", "_")
        $excludes = @($globalExcludes + @($filter.IpExcludesPath))

        if ($transport.UsesTcp) {
            if ($IsFirst.Value) {
                $Result.Add("--name=tpm-game-$($filter.Id)-tcp")
                $IsFirst.Value = $false
            } else {
                $Result.Add("--new=tpm-game-$($filter.Id)-tcp")
            }
            $Result.Add("--filter-tcp=$($transport.TcpPorts)")
            $Result.Add("--ipset=$($filter.IpsPath)")
            foreach ($exclude in $excludes) {
                if ((Get-MeaningfulLines $exclude).Count -gt 0) {
                    $Result.Add("--ipset-exclude=$exclude")
                }
            }
            $Result.Add("--out-range=-d3")
            if ($transport.Preset -eq "extended") {
                $Result.Add(
                    "--lua-desync=multisplit:pos=1:seqovl=568:" +
                    "seqovl_pattern=tpm_game_tcp_pattern:payload=~empty"
                )
            } else {
                $Result.Add(
                    "--lua-desync=multisplit:pos=2:payload=~empty"
                )
            }
        }

        if ($transport.UsesUdp) {
            if ($IsFirst.Value) {
                $Result.Add("--name=tpm-game-$($filter.Id)-udp")
                $IsFirst.Value = $false
            } else {
                $Result.Add("--new=tpm-game-$($filter.Id)-udp")
            }
            $Result.Add("--filter-udp=$($transport.UdpPorts)")
            $Result.Add("--ipset=$($filter.IpsPath)")
            foreach ($exclude in $excludes) {
                if ((Get-MeaningfulLines $exclude).Count -gt 0) {
                    $Result.Add("--ipset-exclude=$exclude")
                }
            }
            $repeats = if ($transport.Preset -eq "extended") { 12 } else { 4 }
            $Result.Add("--out-range=-d2")
            $Result.Add(
                "--lua-desync=fake:blob=tpm_game_udp_${id}:" +
                "payload=~empty:repeats=$repeats"
            )
        }
    }
}

function Build-WinwsArguments([bool]$DryRun, [string]$ProfileName = "") {
    $config = Get-Config
    $profile = if ($ProfileName) {
        if ($ProfileName -notmatch "^[a-zA-Z0-9_-]+$") { throw "Invalid profile name." }
        Read-JsonFile (Get-AppPath "config\profiles\$ProfileName.json")
    } else {
        Get-ActiveProfile
    }
    $gameTransports = @(
        Get-EnabledGameFilterTransports $script:AppRoot
    )
    $executable = Find-RuntimeExecutable
    $luaLib = Find-RuntimeFile "zapret-lib.lua" $executable
    $luaAntidpi = Find-RuntimeFile "zapret-antidpi.lua" $executable
    $domainCount = @(Get-MeaningfulLines (Get-AppPath "lists\domains.txt")).Count +
        @(Get-MeaningfulLines (Get-AppPath "lists\user-domains.txt")).Count
    foreach ($path in Get-EnabledGameFilterListPaths $script:AppRoot "domain") {
        $domainCount += @(Get-MeaningfulLines $path).Count
    }
    if ($env:TRAFFIC_PROFILE_BENCHMARK_LIST) {
        $benchmarkList = [IO.Path]::GetFullPath($env:TRAFFIC_PROFILE_BENCHMARK_LIST)
        $appRootPrefix = $script:AppRoot.TrimEnd("\") + "\"
        if ($benchmarkList.StartsWith($appRootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            $domainCount += @(Get-MeaningfulLines $benchmarkList).Count
        }
    }
    $ipCount = @(Get-MeaningfulLines (Get-AppPath "lists\ips.txt")).Count +
        @(Get-MeaningfulLines (Get-AppPath "lists\user-ips.txt")).Count
    foreach ($path in Get-EnabledGameFilterListPaths $script:AppRoot "ip") {
        $ipCount += @(Get-MeaningfulLines $path).Count
    }
    if ($domainCount -eq 0 -and $ipCount -eq 0 -and -not $config.allowAllWithoutTargets) {
        throw "No domain or IP targets are configured. Add a target or explicitly enable allowAllWithoutTargets in config.json."
    }

    $result = New-Object "Collections.Generic.List[string]"
    if (-not $DryRun) {
        $result.Add("--daemon")
        $result.Add("--pidfile=$(Get-AppPath 'state\winws2.pid')")
    } else {
        $result.Add("--dry-run")
    }
    if ($config.debug) {
        $result.Add("--debug=@$(Get-AppPath 'logs\winws2.log')")
    } else {
        $result.Add("--debug=0")
    }
    if ($luaLib) { $result.Add("--lua-init=@$luaLib") }
    if ($luaAntidpi) { $result.Add("--lua-init=@$luaAntidpi") }
    if ($profile.blobs) {
        foreach ($blob in $profile.blobs) {
            if ([string]$blob.name -notmatch "^[a-zA-Z0-9_]+$") {
                throw "Invalid blob name: $($blob.name)"
            }
            $blobPath = Get-AppPath ([string]$blob.path)
            if (-not (Test-Path -LiteralPath $blobPath -PathType Leaf)) {
                throw "Blob file not found: $blobPath"
            }
            $result.Add("--blob=$($blob.name):@$blobPath")
        }
    }
    $profileBlobNames = @($profile.blobs | ForEach-Object { [string]$_.name })
    if (
        @($gameTransports | Where-Object {
            $_.Transport.UsesTcp -and $_.Transport.Preset -eq "extended"
        }).Count
    ) {
        if ($profileBlobNames -contains "tpm_game_tcp_pattern") {
            throw "Profile blob name 'tpm_game_tcp_pattern' is reserved."
        }
        $tcpPattern = Get-AppPath "assets\tls_clienthello_www_google_com.bin"
        if (-not (Test-Path -LiteralPath $tcpPattern -PathType Leaf)) {
            throw "Game transport TCP pattern was not found: $tcpPattern"
        }
        $result.Add("--blob=tpm_game_tcp_pattern:@$tcpPattern")
    }
    foreach ($filter in @(
        $gameTransports | Where-Object { $_.Transport.UsesUdp }
    )) {
        $blobName = "tpm_game_udp_$(([string]$filter.Id).Replace('-', '_'))"
        if ($profileBlobNames -contains $blobName) {
            throw "Profile blob name '$blobName' is reserved."
        }
        $result.Add("--blob=${blobName}:@$($filter.Transport.UdpFakePath)")
    }

    $tcpOut = Merge-GameFilterPortExpressions @(
        [string]$profile.interception.tcpOut
        $gameTransports |
            Where-Object { $_.Transport.UsesTcp } |
            ForEach-Object { [string]$_.Transport.TcpPorts }
    )
    $udpOut = Merge-GameFilterPortExpressions @(
        [string]$profile.interception.udpOut
        $gameTransports |
            Where-Object { $_.Transport.UsesUdp } |
            ForEach-Object { [string]$_.Transport.UdpPorts }
    )
    if ($tcpOut) {
        $result.Add("--wf-tcp-out=$tcpOut")
    }
    if ($udpOut) { $result.Add("--wf-udp-out=$udpOut") }
    if ($profile.interception.tcpIn) { $result.Add("--wf-tcp-in=$($profile.interception.tcpIn)") }
    if ($profile.interception.udpIn) { $result.Add("--wf-udp-in=$($profile.interception.udpIn)") }
    if ($profile.interception.rawParts) {
        foreach ($relativePath in $profile.interception.rawParts) {
            $rawPart = Get-AppPath ([string]$relativePath)
            if (-not (Test-Path -LiteralPath $rawPart -PathType Leaf)) {
                throw "WinDivert filter fragment not found: $rawPart"
            }
            $result.Add("--wf-raw-part=@$rawPart")
        }
    }

    $first = $true
    Add-ProfileArguments $result $profile "first" ([ref]$first)
    if ($domainCount -gt 0) {
        Add-ProfileArguments $result $profile "domain" ([ref]$first)
    }
    if ($ipCount -gt 0) {
        Add-ProfileArguments $result $profile "ip" ([ref]$first)
    }
    Add-ProfileArguments $result $profile "all" ([ref]$first)
    if ($domainCount -eq 0 -and $ipCount -eq 0 -and $config.allowAllWithoutTargets) {
        foreach ($rule in $profile.rules) {
            if ($first) {
                $result.Add("--name=$($rule.name)-all")
                $first = $false
            } else {
                $result.Add("--new=$($rule.name)-all")
            }
            foreach ($argument in $rule.match) { $result.Add([string]$argument) }
            foreach ($argument in $rule.actions) { $result.Add([string]$argument) }
        }
    }
    Add-GameTransportArguments $result $gameTransports ([ref]$first)
    return $result.ToArray()
}

function Start-ZapretForeground([string]$ProfileName) {
    Ensure-Initialized
    if (-not (Test-IsAdministrator)) {
        throw "Run the BAT file or terminal as administrator for WinDivert."
    }
    if (Get-RunningPid) {
        throw "Stop the background winws2 process first: zapretctl stop"
    }
    $executable = Find-RuntimeExecutable
    if (-not $executable) { throw "winws2.exe was not found in runtime." }
    if (-not (Find-RuntimeFile "zapret-lib.lua" $executable) -or
        -not (Find-RuntimeFile "zapret-antidpi.lua" $executable)) {
        throw "The standard zapret2 Lua libraries were not found."
    }

    $arguments = @(
        Build-WinwsArguments $false $ProfileName |
            Where-Object { $_ -ne "--daemon" -and -not $_.StartsWith("--pidfile=") }
    )
    Write-Host ""
    Write-Host "Profile: $ProfileName" -ForegroundColor Cyan
    Write-Host "The traffic profile remains active while this window is open." -ForegroundColor Green
    Write-Host "Press Ctrl+C or close the window to stop it." -ForegroundColor Yellow
    Write-Host ""

    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $executable
    $startInfo.Arguments = (($arguments | ForEach-Object { Quote-WindowsArgument $_ }) -join " ")
    $startInfo.WorkingDirectory = Split-Path -Parent $executable
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $false
    $process = [Diagnostics.Process]::Start($startInfo)
    $windowsPidPath = Get-AppPath "state\winws2.windows.pid"
    Write-AtomicText $windowsPidPath ([string]$process.Id)
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
            "-WinwsPid",
            [string]$process.Id,
            "-ReadyPath",
            $mappingReadyPath
        )) {
            $watcherArguments.Add($argument)
        }
        $watcherArguments.Add("-CleanupMappings")
        $watcherInfo = New-Object Diagnostics.ProcessStartInfo
        $watcherInfo.FileName = "powershell.exe"
        $watcherInfo.Arguments = (($watcherArguments | ForEach-Object { Quote-WindowsArgument $_ }) -join " ")
        $watcherInfo.UseShellExecute = $true
        $watcherInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
        [void][Diagnostics.Process]::Start($watcherInfo)
        $watcherStarted = $true

        try {
            & (Get-AppPath "manage-network-mappings.ps1") refresh | Out-Host
        } catch {
            Write-Warning "Secure mappings could not be refreshed: $($_.Exception.Message)"
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
            Remove-Item -LiteralPath $mappingReadyPath -Force -ErrorAction SilentlyContinue
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
    }
}

function Quote-WindowsArgument([string]$Argument) {
    if ($Argument -notmatch '[\s"]') { return $Argument }
    $builder = New-Object Text.StringBuilder
    [void]$builder.Append('"')
    $slashes = 0
    foreach ($character in $Argument.ToCharArray()) {
        if ($character -eq '\') {
            $slashes++
            continue
        }
        if ($character -eq '"') {
            [void]$builder.Append(('\' * ($slashes * 2 + 1)))
            [void]$builder.Append('"')
            $slashes = 0
            continue
        }
        if ($slashes) {
            [void]$builder.Append(('\' * $slashes))
            $slashes = 0
        }
        [void]$builder.Append($character)
    }
    if ($slashes) { [void]$builder.Append(('\' * ($slashes * 2))) }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Get-RunningPid {
    $pidPath = Get-AppPath "state\winws2.windows.pid"
    if (-not (Test-Path -LiteralPath $pidPath)) { return $null }
    $storedPid = 0
    if (-not [int]::TryParse((Get-Content -Raw -LiteralPath $pidPath).Trim(), [ref]$storedPid)) { return $null }
    $process = Get-Process -Id $storedPid -ErrorAction SilentlyContinue
    if ($process -and $process.ProcessName -eq "winws2") { return $storedPid }
    return $null
}

function Start-Zapret([bool]$DryRun, [string]$ProfileName = "") {
    Ensure-Initialized
    if (-not $DryRun -and -not (Test-IsAdministrator)) {
        throw "Run the terminal as administrator to start WinDivert."
    }
    if (Get-RunningPid) { throw "winws2 is already running." }
    $executable = Find-RuntimeExecutable
    if (-not $executable) {
        throw "winws2.exe was not found. Extract the official zapret-win-bundle into runtime."
    }
    $luaLib = Find-RuntimeFile "zapret-lib.lua" $executable
    $luaAntidpi = Find-RuntimeFile "zapret-antidpi.lua" $executable
    if (-not $luaLib -or -not $luaAntidpi) {
        throw "zapret-lib.lua and zapret-antidpi.lua were not found with the Windows bundle."
    }
    $arguments = Build-WinwsArguments $DryRun $ProfileName
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $executable
    $startInfo.Arguments = (($arguments | ForEach-Object { Quote-WindowsArgument $_ }) -join " ")
    $startInfo.WorkingDirectory = Split-Path -Parent $executable
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    if ($DryRun) {
        $startInfo.EnvironmentVariables["__COMPAT_LAYER"] = "RunAsInvoker"
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
    }
    $process = [Diagnostics.Process]::Start($startInfo)
    if ($DryRun) {
        $standardOutput = $process.StandardOutput.ReadToEnd()
        $standardError = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        if ($standardOutput) {
            Write-Host $standardOutput.TrimEnd()
        }
        if ($standardError) {
            Write-Host $standardError.TrimEnd() -ForegroundColor Red
        }
        if ($process.ExitCode -ne 0) { throw "Parameter validation exited with code $($process.ExitCode)." }
        Write-Host "winws2 accepted the parameters."
        return
    }
    $windowsPidPath = Get-AppPath "state\winws2.windows.pid"
    Write-AtomicText $windowsPidPath ([string]$process.Id)
    Start-Sleep -Milliseconds 500
    if (-not $process.HasExited) {
        Write-Host "winws2 started, Windows PID $($process.Id)"
        return
    }
    $pidPath = Get-AppPath "state\winws2.pid"
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        Start-Sleep -Milliseconds 100
        if ($process.HasExited -and $process.ExitCode -ne 0) {
            if (Test-Path -LiteralPath $windowsPidPath) { Remove-Item -LiteralPath $windowsPidPath -Force }
            throw "winws2 exited with code $($process.ExitCode). Check logs\winws2.log."
        }
        if (-not $process.HasExited) {
            Write-Host "winws2 started, Windows PID $($process.Id)"
            return
        }
    }
    if (Test-Path -LiteralPath $windowsPidPath) { Remove-Item -LiteralPath $windowsPidPath -Force }
    throw "winws2 exited immediately after startup. Check logs\winws2.log."
}

function Stop-Zapret {
    Ensure-Initialized
    $running = Get-RunningPid
    if (-not $running) {
        foreach ($pidPath in @(
            (Get-AppPath "state\winws2.pid"),
            (Get-AppPath "state\winws2.windows.pid")
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
        (Get-AppPath "state\winws2.windows.pid")
    )) {
        if (Test-Path -LiteralPath $pidPath) { Remove-Item -LiteralPath $pidPath -Force }
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
    $baseDomains = @(Get-MeaningfulLines (Get-AppPath "lists\domains.txt")).Count
    $userDomains = @(Get-MeaningfulLines (Get-AppPath "lists\user-domains.txt")).Count
    $baseIps = @(Get-MeaningfulLines (Get-AppPath "lists\ips.txt")).Count
    $userIps = @(Get-MeaningfulLines (Get-AppPath "lists\user-ips.txt")).Count
    Write-Host "Domains: $($baseDomains + $userDomains) (built-in: $baseDomains, custom: $userDomains)"
    Write-Host "IP/CIDR: $($baseIps + $userIps) (built-in: $baseIps, custom: $userIps)"
}

function Adopt-ZapretProcess {
    Ensure-Initialized
    $running = Get-RunningPid
    if ($running) {
        Write-Host "winws2 is already registered, Windows PID $running"
        return
    }
    $candidates = @(Get-Process -Name "winws2" -ErrorAction SilentlyContinue)
    if ($candidates.Count -eq 0) { throw "No running winws2.exe process was found." }
    if ($candidates.Count -gt 1) {
        throw "Multiple winws2 processes were found and cannot be selected safely."
    }
    Write-AtomicText (Get-AppPath "state\winws2.windows.pid") ([string]$candidates[0].Id)
    Write-Host "Process registered, Windows PID $($candidates[0].Id)"
}

function Show-Render([string]$ProfileName = "") {
    Ensure-Initialized
    $executable = Find-RuntimeExecutable
    if (-not $executable) { $executable = "<runtime>\winws2.exe" }
    Write-Output (Quote-WindowsArgument $executable)
    Build-WinwsArguments $false $ProfileName |
        ForEach-Object { Write-Output "  $(Quote-WindowsArgument $_)" }
}

function Show-Doctor {
    Ensure-Initialized
    $failures = 0
    function Report([bool]$Ok, [string]$Text) {
        if ($Ok) {
            Write-Host "[OK]   $Text" -ForegroundColor Green
        } else {
            Write-Host "[FAIL] $Text" -ForegroundColor Red
            $script:doctorFailures++
        }
    }
    $script:doctorFailures = 0
    Report (Test-IsAdministrator) "Administrator privileges"
    $executable = Find-RuntimeExecutable
    Report ([bool]$executable) $(if ($executable) { "winws2.exe: $executable" } else { "winws2.exe in runtime" })
    Report ([bool](Find-RuntimeFile "zapret-lib.lua" $executable)) "zapret-lib.lua"
    Report ([bool](Find-RuntimeFile "zapret-antidpi.lua" $executable)) "zapret-antidpi.lua"
    Report ((Test-Path -LiteralPath (Get-AppPath "config\profiles\$((Get-Config).activeProfile).json"))) "Active profile"
    $targets = @(Get-MeaningfulLines (Get-AppPath "lists\domains.txt")).Count +
        @(Get-MeaningfulLines (Get-AppPath "lists\user-domains.txt")).Count +
        @(Get-MeaningfulLines (Get-AppPath "lists\ips.txt")).Count +
        @(Get-MeaningfulLines (Get-AppPath "lists\user-ips.txt")).Count
    Report ($targets -gt 0 -or (Get-Config).allowAllWithoutTargets) "At least one target is configured"
    if ($executable) {
        $driver = Find-RuntimeFile "WinDivert64.sys" $executable
        $dll = Find-RuntimeFile "WinDivert.dll" $executable
        Report ([bool]$driver) "WinDivert64.sys"
        Report ([bool]$dll) "WinDivert.dll"
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
    if (-not (Test-Path -LiteralPath $path)) { Write-Host "The log has not been created yet."; return }
    $tail = 80
    if ($InputArgs.Count -ge 2 -and $InputArgs[0] -eq "--tail") {
        if (-not [int]::TryParse($InputArgs[1], [ref]$tail) -or $tail -lt 1) { throw "Invalid line count." }
    }
    Get-Content -LiteralPath $path -Tail $tail
}

function Invoke-RuntimeCommand([string[]]$InputArgs) {
    Ensure-Initialized
    if (-not $InputArgs -or $InputArgs.Count -lt 2 -or $InputArgs[0].ToLowerInvariant() -ne "path") {
        throw "Usage: zapretctl runtime path <path-to-winws2.exe>"
    }
    $path = [IO.Path]::GetFullPath($InputArgs[1])
    if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or [IO.Path]::GetFileName($path) -ne "winws2.exe") {
        throw "The specified winws2.exe was not found: $path"
    }
    $config = Get-Config
    $config.runtimePath = $path
    Save-Config $config
    Write-Host "Runtime: $path"
}

function Show-Help {
    @"
zapretctl - local traffic profile manager

  init                                  create configuration and lists
  domain add|remove <domain>            modify the domain list
  domain exclude [add|remove] <domain>  modify domain exclusions
  domain list [--exclude]               show the list
  domain import <file> [--exclude]      import a list
  ip add|remove <IP/CIDR>               modify the IP list
  ip exclude [add|remove] <IP/CIDR>     modify IP exclusions
  ip list [--exclude]                   show the list
  ip import <file> [--exclude]          import a list
  profile list|show|use <name>          manage profiles
  runtime path <winws2.exe>             set an explicit runtime path
  start                                 start winws2
  foreground <profile>                  run in the current window
  check                                 validate parameters with --dry-run
  stop | restart | status               manage the process
  adopt                                 register an existing winws2 process
  render                                show the generated command
  doctor                                check the installation
  logs [--tail N]                       show the log

Running without domain or IP targets is disabled by default to avoid processing
all traffic accidentally. Settings are stored in config\config.json.
"@
}

try {
    switch ($Command.ToLowerInvariant()) {
        "help" { Show-Help }
        "--help" { Show-Help }
        "-h" { Show-Help }
        "init" { Initialize-App }
        "domain" { Invoke-ListCommand "domain" $CommandArgs }
        "ip" { Invoke-ListCommand "ip" $CommandArgs }
        "profile" { Invoke-ProfileCommand $CommandArgs }
        "runtime" { Invoke-RuntimeCommand $CommandArgs }
        "start" { Start-Zapret $false }
        "foreground" {
            if (-not $CommandArgs -or $CommandArgs.Count -lt 1) { throw "Specify a profile." }
            Start-ZapretForeground $CommandArgs[0]
        }
        "check" {
            $profileName = if ($CommandArgs -and $CommandArgs.Count) { $CommandArgs[0] } else { "" }
            Start-Zapret $true $profileName
        }
        "stop" { Stop-Zapret }
        "restart" { Stop-Zapret; Start-Zapret $false }
        "status" { Show-Status }
        "adopt" { Adopt-ZapretProcess }
        "render" {
            $profileName = if ($CommandArgs -and $CommandArgs.Count) { $CommandArgs[0] } else { "" }
            Show-Render $profileName
        }
        "doctor" { Show-Doctor }
        "logs" { Show-Logs $CommandArgs }
        default { throw "Unknown command '$Command'. Run 'zapretctl help'." }
    }
} catch {
    Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

