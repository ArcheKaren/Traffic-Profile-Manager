function Find-RuntimeExecutable {
    $config = Get-Config
    if ($config.runtimePath) {
        $configured = if ([IO.Path]::IsPathRooted([string]$config.runtimePath)) {
            [string]$config.runtimePath
        } else {
            Get-AppPath ([string]$config.runtimePath)
        }
        if (Test-Path -LiteralPath $configured -PathType Leaf) {
            return [IO.Path]::GetFullPath($configured)
        }
    }
    $candidates = @(
        (Get-AppPath "runtime\winws2.exe"),
        (Get-AppPath "runtime\zapret-winws\winws2.exe"),
        (Get-AppPath "runtime\zapret-win-bundle-master\zapret-winws\winws2.exe")
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }
    $found = Get-ChildItem `
        -LiteralPath (Get-AppPath "runtime") `
        -Filter "winws2.exe" `
        -File `
        -Recurse `
        -ErrorAction SilentlyContinue |
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
    $found = Get-ChildItem `
        -LiteralPath (Get-AppPath "runtime") `
        -Filter $Name `
        -File `
        -Recurse `
        -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($found) { return $found.FullName }
    return $null
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
        $benchmarkList = [IO.Path]::GetFullPath(
            $env:TRAFFIC_PROFILE_BENCHMARK_LIST
        )
        $appRootPrefix = $script:AppRoot.TrimEnd("\") + "\"
        if ($benchmarkList.StartsWith(
            $appRootPrefix,
            [StringComparison]::OrdinalIgnoreCase
        )) {
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
        $scope = if ($rule.PSObject.Properties.Name -contains "scope") {
            [string]$rule.scope
        } else { "targets" }
        if ($TargetKind -eq "first" -and $scope -ne "first") { continue }
        if ($TargetKind -eq "all" -and $scope -ne "all") { continue }
        if (
            $TargetKind -ne "first" -and
            $TargetKind -ne "all" -and
            $scope -in @("first", "all")
        ) { continue }

        $profileName = "$($rule.name)-$TargetKind"
        if ($IsFirst.Value) {
            $Result.Add("--name=$profileName")
            $IsFirst.Value = $false
        } else {
            $Result.Add("--new=$profileName")
        }
        foreach ($argument in $rule.match) {
            $Result.Add(
                ([string]$argument).Replace("{app}", $script:AppRoot)
            )
        }
        if ($TargetKind -eq "domain") {
            foreach ($domainList in $domainLists) {
                if (Test-Path -LiteralPath $domainList -PathType Leaf) {
                    $Result.Add("--hostlist=$domainList")
                }
            }
            foreach ($domainExclude in $domainExcludes) {
                if ((Get-TpmMeaningfulLines $domainExclude).Count -gt 0) {
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
                if ((Get-TpmMeaningfulLines $ipExclude).Count -gt 0) {
                    $Result.Add("--ipset-exclude=$ipExclude")
                }
            }
        }
        foreach ($argument in $rule.actions) {
            $Result.Add(
                ([string]$argument).Replace("{app}", $script:AppRoot)
            )
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
        $excludes = @(
            $globalExcludes + @($filter.IpExcludesPath) |
                Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }
        )

        if ($transport.UsesTcp) {
            if ($IsFirst.Value) {
                $Result.Add("--name=tpm-game-$($filter.Id)-tcp")
                $IsFirst.Value = $false
            } else {
                $Result.Add("--new=tpm-game-$($filter.Id)-tcp")
            }
            $Result.Add("--filter-tcp=$($transport.TcpPorts)")
            if (-not [string]::IsNullOrWhiteSpace([string]$filter.IpsPath)) {
                $Result.Add("--ipset=$($filter.IpsPath)")
            }
            foreach ($exclude in $excludes) {
                if ((Get-TpmMeaningfulLines $exclude).Count -gt 0) {
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
                $Result.Add("--lua-desync=multisplit:pos=2:payload=~empty")
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
            if (-not [string]::IsNullOrWhiteSpace([string]$filter.IpsPath)) {
                $Result.Add("--ipset=$($filter.IpsPath)")
            }
            foreach ($exclude in $excludes) {
                if ((Get-TpmMeaningfulLines $exclude).Count -gt 0) {
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
    $selectedProfile = if ($ProfileName) {
        if ($ProfileName -notmatch "^[a-zA-Z0-9_-]+$") {
            throw "Invalid profile name."
        }
        $ProfileName
    } else {
        [string]$config.activeProfile
    }
    if ($selectedProfile -notmatch "^[a-zA-Z0-9_-]{1,64}$") {
        throw "Invalid profile name."
    }
    $profilePath = Get-AppPath "config\profiles\$selectedProfile.json"
    $profile = Read-JsonFile $profilePath
    [void](Test-TrafficProfileDefinition `
        $profile `
        $profilePath `
        $script:AppRoot)
    $profile = Resolve-TrafficProfileDefinition $profile $script:AppRoot
    $gameTransports = @(Get-EnabledGameFilterTransports $script:AppRoot)
    $executable = Find-RuntimeExecutable
    $luaLib = Find-RuntimeFile "zapret-lib.lua" $executable
    $luaAntidpi = Find-RuntimeFile "zapret-antidpi.lua" $executable
    $domainCount = @(
        Get-TpmMeaningfulLines (Get-AppPath "lists\domains.txt")
    ).Count + @(
        Get-TpmMeaningfulLines (Get-AppPath "lists\user-domains.txt")
    ).Count
    foreach ($path in Get-EnabledGameFilterListPaths $script:AppRoot "domain") {
        $domainCount += @(Get-TpmMeaningfulLines $path).Count
    }
    if ($env:TRAFFIC_PROFILE_BENCHMARK_LIST) {
        $benchmarkList = [IO.Path]::GetFullPath(
            $env:TRAFFIC_PROFILE_BENCHMARK_LIST
        )
        $appRootPrefix = $script:AppRoot.TrimEnd("\") + "\"
        if ($benchmarkList.StartsWith(
            $appRootPrefix,
            [StringComparison]::OrdinalIgnoreCase
        )) {
            $domainCount += @(Get-TpmMeaningfulLines $benchmarkList).Count
        }
    }
    $ipCount = @(
        Get-TpmMeaningfulLines (Get-AppPath "lists\ips.txt")
    ).Count + @(
        Get-TpmMeaningfulLines (Get-AppPath "lists\user-ips.txt")
    ).Count
    foreach ($path in Get-EnabledGameFilterListPaths $script:AppRoot "ip") {
        $ipCount += @(Get-TpmMeaningfulLines $path).Count
    }
    if (
        $domainCount -eq 0 -and
        $ipCount -eq 0 -and
        $gameTransports.Count -eq 0 -and
        -not $config.allowAllWithoutTargets
    ) {
        throw (
            "No domain or IP targets are configured. Add a target or " +
            "explicitly enable allowAllWithoutTargets in config.json."
        )
    }

    $result = New-Object "Collections.Generic.List[string]"
    if ($DryRun) {
        $result.Add("--dry-run")
    } else {
        $result.Add("--daemon")
        $result.Add("--pidfile=$(Get-AppPath 'state\winws2.pid')")
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
    $profileBlobNames = @(
        $profile.blobs | ForEach-Object { [string]$_.name }
    )
    if (@($gameTransports | Where-Object {
        $_.Transport.UsesTcp -and $_.Transport.Preset -eq "extended"
    }).Count) {
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
    if ($tcpOut) { $result.Add("--wf-tcp-out=$tcpOut") }
    if ($udpOut) { $result.Add("--wf-udp-out=$udpOut") }
    if ($profile.interception.tcpIn) {
        $result.Add("--wf-tcp-in=$($profile.interception.tcpIn)")
    }
    if ($profile.interception.udpIn) {
        $result.Add("--wf-udp-in=$($profile.interception.udpIn)")
    }
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
    if (
        $domainCount -eq 0 -and
        $ipCount -eq 0 -and
        $config.allowAllWithoutTargets
    ) {
        foreach ($rule in $profile.rules) {
            if ($first) {
                $result.Add("--name=$($rule.name)-all")
                $first = $false
            } else {
                $result.Add("--new=$($rule.name)-all")
            }
            foreach ($argument in $rule.match) {
                $result.Add([string]$argument)
            }
            foreach ($argument in $rule.actions) {
                $result.Add([string]$argument)
            }
        }
    }
    Add-GameTransportArguments $result $gameTransports ([ref]$first)
    return $result.ToArray()
}

function Get-WinwsLaunchSpecification([string]$ProfileName = "") {
    Ensure-Initialized
    $executable = Find-RuntimeExecutable
    if (-not $executable) { throw "winws2.exe was not found in runtime." }
    $arguments = @(
        Build-WinwsArguments $false $ProfileName |
            Where-Object {
                $_ -ne "--daemon" -and -not $_.StartsWith("--pidfile=")
            }
    )
    [ordered]@{
        schemaVersion = 1
        executable = [IO.Path]::GetFullPath($executable)
        workingDirectory = [IO.Path]::GetFullPath(
            (Split-Path -Parent $executable)
        )
        arguments = $arguments
    } | ConvertTo-Json -Depth 6 -Compress
}
