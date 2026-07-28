param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet("install", "refresh", "cleanup", "watch")]
    [string]$Action,

    [string]$HostsPath = "",

    [int]$WinwsPid = 0,

    [string]$AppRoot = ""
)

$ErrorActionPreference = "Stop"
$appRoot = if ($AppRoot) {
    [IO.Path]::GetFullPath($AppRoot)
} else {
    $PSScriptRoot
}
$hostsPath = if ($HostsPath) {
    [IO.Path]::GetFullPath($HostsPath)
} else {
    Join-Path $env:SystemRoot "System32\drivers\etc\hosts"
}
$beginMarker = "# TrafficProfileManager Mapping BEGIN"
$endMarker = "# TrafficProfileManager Mapping END"
$whatsAppAddress = "57.144.245.32"
$webAddressCache = Join-Path $appRoot "state\instagram-web-ip.txt"
$threadsWebAddressCache = Join-Path $appRoot "state\threads-web-ip.txt"

. (Join-Path $PSScriptRoot "tools\game-filter-library.ps1")

$metaFallback = @{
    "instagram.com" = "157.240.0.174"
    "www.instagram.com" = "157.240.0.174"
    "i.instagram.com" = "157.240.253.63"
    "graph.instagram.com" = "57.144.244.192"
    "help.instagram.com" = "157.240.0.174"
    "privacycenter.instagram.com" = "157.240.0.174"
    "cdninstagram.com" = "157.240.253.63"
    "static.cdninstagram.com" = "157.240.253.63"
    "scontent.cdninstagram.com" = "157.240.253.63"
    "threads.com" = "57.144.248.192"
    "www.threads.com" = "157.240.17.63"
}
$secureDnsProviders = @(
    @{
        Host = "cloudflare-dns.com"
        Address = "1.1.1.1"
        Url = "https://cloudflare-dns.com/dns-query?name={0}&type=A"
    }
    @{
        Host = "dns.google"
        Address = "8.8.8.8"
        Url = "https://dns.google/resolve?name={0}&type=A"
    }
)

function Read-HostsLines {
    if (-not (Test-Path -LiteralPath $hostsPath -PathType Leaf)) {
        throw "Windows hosts file was not found: $hostsPath"
    }
    return @([IO.File]::ReadAllLines($hostsPath))
}

function Write-HostsLines([string[]]$Lines) {
    $text = ($Lines -join [Environment]::NewLine).TrimEnd() +
        [Environment]::NewLine
    [IO.File]::WriteAllText(
        $hostsPath,
        $text,
        [Text.UTF8Encoding]::new($false)
    )
}

function Remove-ManagedBlock {
    $lines = Read-HostsLines
    $beginIndexes = @(
        for ($index = 0; $index -lt $lines.Count; $index++) {
            if ($lines[$index] -eq $beginMarker) { $index }
        }
    )
    $endIndexes = @(
        for ($index = 0; $index -lt $lines.Count; $index++) {
            if ($lines[$index] -eq $endMarker) { $index }
        }
    )

    if ($beginIndexes.Count -eq 0 -and $endIndexes.Count -eq 0) { return }
    if (
        $beginIndexes.Count -ne 1 -or
        $endIndexes.Count -ne 1 -or
        $endIndexes[0] -le $beginIndexes[0]
    ) {
        throw "The managed mapping block in hosts is incomplete or duplicated. It was not modified."
    }
    $begin = $beginIndexes[0]
    $end = $endIndexes[0]

    $result = New-Object "Collections.Generic.List[string]"
    for ($index = 0; $index -lt $lines.Count; $index++) {
        if ($index -lt $begin -or $index -gt $end) {
            $result.Add($lines[$index])
        }
    }
    Write-HostsLines $result.ToArray()
}

function Get-WhatsAppHostNames {
    $names = New-Object "Collections.Generic.HashSet[string]" (
        [StringComparer]::OrdinalIgnoreCase
    )

    @(
        "web.whatsapp.com"
        "www.whatsapp.com"
        "static.whatsapp.net"
        "pps.whatsapp.net"
        "dit.whatsapp.net"
        "mmg.whatsapp.net"
        "graph.whatsapp.com"
        "g.whatsapp.net"
        "media-hel3-1.cdn.whatsapp.net"
        "media-arn2-1.cdn.whatsapp.net"
    ) | ForEach-Object { [void]$names.Add($_) }

    Get-DnsClientCache -ErrorAction SilentlyContinue |
        ForEach-Object {
            $name = ([string]$_.Entry).Trim().TrimEnd(".").ToLowerInvariant()
            if ($name -match "^[a-z0-9.-]+\.(whatsapp\.com|whatsapp\.net)$") {
                [void]$names.Add($name)
            }
        }

    return @($names | Sort-Object)
}

function Get-InstagramHostNames {
    $names = New-Object "Collections.Generic.HashSet[string]" (
        [StringComparer]::OrdinalIgnoreCase
    )

    @(
        "instagram.com"
        "www.instagram.com"
        "i.instagram.com"
        "graph.instagram.com"
        "help.instagram.com"
        "privacycenter.instagram.com"
        "api.instagram.com"
        "edge-chat.instagram.com"
        "gateway.instagram.com"
        "upload.instagram.com"
        "lookaside.instagram.com"
        "cdninstagram.com"
        "static.cdninstagram.com"
        "scontent.cdninstagram.com"
        "threads.com"
        "www.threads.com"
        "threads.net"
        "www.threads.net"
    ) | ForEach-Object { [void]$names.Add($_) }

    Get-DnsClientCache -ErrorAction SilentlyContinue |
        ForEach-Object {
            $name = ([string]$_.Entry).Trim().TrimEnd(".").ToLowerInvariant()
            if (
                $name -match "^(instagram\.com|cdninstagram\.com|threads\.com|threads\.net|[a-z0-9.-]+\.(instagram\.com|cdninstagram\.com|threads\.com|threads\.net))$"
            ) {
                [void]$names.Add($name)
            }
        }

    return @($names | Sort-Object)
}

function Invoke-SecureDnsQuery($Provider, [string]$Name) {
    try {
        $url = $Provider.Url -f [Uri]::EscapeDataString($Name)
        $resolve = "$($Provider.Host):443:$($Provider.Address)"
        $output = & curl.exe `
            --silent `
            --show-error `
            --fail `
            --connect-timeout 3 `
            --max-time 8 `
            --resolve $resolve `
            --header "accept: application/dns-json" `
            $url 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $output) { return $null }
        $response = ($output -join [Environment]::NewLine) |
            ConvertFrom-Json
        if ([int]$response.Status -ne 0) { return $null }
        foreach ($answer in @($response.Answer)) {
            if ([int]$answer.type -ne 1) { continue }
            $address = $null
            if (
                [Net.IPAddress]::TryParse(
                    [string]$answer.data,
                    [ref]$address
                ) -and
                $address.AddressFamily -eq
                    [Net.Sockets.AddressFamily]::InterNetwork
            ) {
                return $address.ToString()
            }
        }
    } catch {
        return $null
    }
    return $null
}

function Get-SecureDnsProvider {
    foreach ($provider in $secureDnsProviders) {
        if (Invoke-SecureDnsQuery $provider "www.instagram.com") {
            return $provider
        }
    }
    return $null
}

function Test-MetaWebAddress(
    [string]$HostName,
    [string]$Address
) {
    try {
        $output = & curl.exe `
            --silent `
            --show-error `
            --location `
            --output NUL `
            --write-out "%{http_code}" `
            --connect-timeout 2 `
            --max-time 4 `
            --resolve "$HostName`:443:$Address" `
            "https://$HostName/" 2>$null
        $curlExitCode = $LASTEXITCODE
        if ($curlExitCode -ne 0) { return $false }
        return ([string]$output).Trim() -match "^[234]\d\d$"
    } catch {
        return $false
    }
}

function Select-InstagramWebAddress($Mappings) {
    $candidates = New-Object "Collections.Generic.List[string]"
    $seen = New-Object "Collections.Generic.HashSet[string]" (
        [StringComparer]::OrdinalIgnoreCase
    )

    if (Test-Path -LiteralPath $webAddressCache -PathType Leaf) {
        $cached = (Get-Content -Raw -LiteralPath $webAddressCache).Trim()
        if ($cached -and $seen.Add($cached)) { $candidates.Add($cached) }
    }

    foreach ($name in @(
        "www.instagram.com"
        "i.instagram.com"
        "graph.instagram.com"
        "scontent.cdninstagram.com"
        "static.cdninstagram.com"
    )) {
        if ($Mappings.ContainsKey($name)) {
            $address = $Mappings[$name]
            if ($seen.Add($address)) { $candidates.Add($address) }
        }
    }

    foreach ($address in @($metaFallback.Values | Sort-Object -Unique)) {
        if ($seen.Add($address)) { $candidates.Add($address) }
    }

    foreach ($address in @($candidates | Select-Object -First 6)) {
        if (Test-MetaWebAddress "www.instagram.com" $address) {
            $stateRoot = Split-Path -Parent $webAddressCache
            New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
            [IO.File]::WriteAllText(
                $webAddressCache,
                $address + [Environment]::NewLine,
                [Text.UTF8Encoding]::new($false)
            )
            return $address
        }
    }
    return $null
}

function Select-ThreadsWebAddress($Mappings) {
    $candidates = New-Object "Collections.Generic.List[string]"
    $seen = New-Object "Collections.Generic.HashSet[string]" (
        [StringComparer]::OrdinalIgnoreCase
    )

    if (Test-Path -LiteralPath $threadsWebAddressCache -PathType Leaf) {
        $cached = (Get-Content -Raw -LiteralPath $threadsWebAddressCache).Trim()
        if ($cached -and $seen.Add($cached)) { $candidates.Add($cached) }
    }

    foreach ($name in @(
        "www.threads.com"
        "threads.com"
        "www.instagram.com"
        "i.instagram.com"
        "graph.instagram.com"
    )) {
        if ($Mappings.ContainsKey($name)) {
            $address = $Mappings[$name]
            if ($seen.Add($address)) { $candidates.Add($address) }
        }
    }

    foreach ($address in @($metaFallback.Values | Sort-Object -Unique)) {
        if ($seen.Add($address)) { $candidates.Add($address) }
    }

    foreach ($address in @($candidates | Select-Object -First 6)) {
        if (Test-MetaWebAddress "www.threads.com" $address) {
            $stateRoot = Split-Path -Parent $threadsWebAddressCache
            New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
            [IO.File]::WriteAllText(
                $threadsWebAddressCache,
                $address + [Environment]::NewLine,
                [Text.UTF8Encoding]::new($false)
            )
            return $address
        }
    }
    return $null
}

function Get-ManagedMappings([bool]$IncludeInstagram) {
    $mappings = New-Object "Collections.Generic.Dictionary[string,string]" (
        [StringComparer]::OrdinalIgnoreCase
    )

    foreach ($name in Get-WhatsAppHostNames) {
        $mappings[$name] = $whatsAppAddress
    }

    if ($IncludeInstagram) {
        $provider = Get-SecureDnsProvider
        foreach ($name in Get-InstagramHostNames) {
            $address = if ($provider) {
                Invoke-SecureDnsQuery $provider $name
            } else {
                $null
            }
            if (-not $address -and $metaFallback.ContainsKey($name)) {
                $address = $metaFallback[$name]
            }
            if ($address) { $mappings[$name] = $address }
        }
        $webAddress = Select-InstagramWebAddress $mappings
        if ($webAddress) {
            foreach ($name in @(
                "instagram.com"
                "www.instagram.com"
                "help.instagram.com"
                "privacycenter.instagram.com"
            )) {
                $mappings[$name] = $webAddress
            }
        }
        $threadsAddress = Select-ThreadsWebAddress $mappings
        if ($threadsAddress) {
            $mappings["threads.com"] = $threadsAddress
            $mappings["www.threads.com"] = $threadsAddress
        }
    }

    foreach ($mapping in Get-EnabledGameFilterMappings $appRoot) {
        if (
            $mappings.ContainsKey($mapping.Name) -and
            $mappings[$mapping.Name] -ne $mapping.Address
        ) {
            throw (
                "Game filter '$($mapping.FilterId)' conflicts with another " +
                "mapping for '$($mapping.Name)'."
            )
        }
        $mappings[$mapping.Name] = $mapping.Address
    }

    return $mappings
}

function Install-ManagedBlock([bool]$IncludeInstagram) {
    $mappings = Get-ManagedMappings $IncludeInstagram
    Remove-ManagedBlock
    $lines = Read-HostsLines
    $result = New-Object "Collections.Generic.List[string]"
    foreach ($line in $lines) { $result.Add($line) }
    if ($result.Count -gt 0 -and $result[$result.Count - 1] -ne "") {
        $result.Add("")
    }
    $result.Add($beginMarker)
    foreach ($name in @($mappings.Keys | Sort-Object)) {
        $result.Add("$($mappings[$name])`t$name")
    }
    $result.Add($endMarker)
    Write-HostsLines $result.ToArray()
    Clear-DnsClientCache -ErrorAction SilentlyContinue
    return $mappings.Count
}

switch ($Action) {
    "install" {
        $count = Install-ManagedBlock $false
        Write-Output "Temporary network mappings installed: $count."
    }
    "refresh" {
        $count = Install-ManagedBlock $true
        Write-Output "Temporary secure mappings installed: $count."
    }
    "cleanup" {
        Remove-ManagedBlock
        Clear-DnsClientCache -ErrorAction SilentlyContinue
    }
    "watch" {
        $deadline = [DateTime]::UtcNow.AddSeconds(15)
        do {
            $zapret = if ($WinwsPid -gt 0) {
                Get-Process -Id $WinwsPid -ErrorAction SilentlyContinue |
                    Where-Object ProcessName -eq "winws2"
            } else {
                Get-Process -Name "winws2" -ErrorAction SilentlyContinue
            }
            if ($zapret) { break }
            Start-Sleep -Milliseconds 100
        } while ([DateTime]::UtcNow -lt $deadline)

        $started = [DateTime]::UtcNow
        while ($zapret) {
            try { [void](Install-ManagedBlock $true) } catch {}
            $elapsed = ([DateTime]::UtcNow - $started).TotalSeconds
            Start-Sleep -Seconds $(if ($elapsed -lt 30) { 3 } else { 30 })
            $zapret = if ($WinwsPid -gt 0) {
                Get-Process -Id $WinwsPid -ErrorAction SilentlyContinue |
                    Where-Object ProcessName -eq "winws2"
            } else {
                Get-Process -Name "winws2" -ErrorAction SilentlyContinue
            }
        }

        Remove-ManagedBlock
        Clear-DnsClientCache -ErrorAction SilentlyContinue
    }
}
