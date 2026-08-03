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
$hostsMutexName = "Global\TrafficProfileManagerHostsLock"

. (Join-Path $PSScriptRoot "tools\game-filter-library.ps1")
. (Join-Path $PSScriptRoot "tools\network-mapping-library.ps1")

function Get-ByteHash([byte[]]$Bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return [BitConverter]::ToString(
            $sha.ComputeHash($Bytes)
        ).Replace("-", "")
    } finally {
        $sha.Dispose()
    }
}

function Read-HostsDocument {
    if (-not (Test-Path -LiteralPath $hostsPath -PathType Leaf)) {
        throw "Windows hosts file was not found: $hostsPath"
    }
    $bytes = [IO.File]::ReadAllBytes($hostsPath)
    $encoding = $null
    $preambleLength = 0
    if (
        $bytes.Length -ge 3 -and
        $bytes[0] -eq 0xEF -and
        $bytes[1] -eq 0xBB -and
        $bytes[2] -eq 0xBF
    ) {
        $encoding = New-Object Text.UTF8Encoding($false, $true)
        $preambleLength = 3
    } elseif (
        $bytes.Length -ge 2 -and
        $bytes[0] -eq 0xFF -and
        $bytes[1] -eq 0xFE
    ) {
        $encoding = New-Object Text.UnicodeEncoding($false, $false, $true)
        $preambleLength = 2
    } elseif (
        $bytes.Length -ge 2 -and
        $bytes[0] -eq 0xFE -and
        $bytes[1] -eq 0xFF
    ) {
        $encoding = New-Object Text.UnicodeEncoding($true, $false, $true)
        $preambleLength = 2
    } else {
        $encoding = New-Object Text.UTF8Encoding($false, $true)
    }

    try {
        $text = $encoding.GetString(
            $bytes,
            $preambleLength,
            $bytes.Length - $preambleLength
        )
    } catch {
        if ($preambleLength -ne 0) { throw }
        $encoding = [Text.Encoding]::Default
        $text = $encoding.GetString($bytes)
    }
    $newlineMatch = [regex]::Match($text, "\r\n|\n|\r")
    $newline = if ($newlineMatch.Success) {
        $newlineMatch.Value
    } else {
        [Environment]::NewLine
    }
    $endedWithNewline = $text -match "(\r\n|\n|\r)$"
    $lines = @([regex]::Split($text, "\r\n|\n|\r"))
    if (
        $endedWithNewline -and
        $lines.Count -gt 0 -and
        $lines[$lines.Count - 1] -eq ""
    ) {
        $lines = @($lines[0..($lines.Count - 2)])
    }
    return [pscustomobject]@{
        Bytes = $bytes
        Hash = Get-ByteHash $bytes
        Encoding = $encoding
        Preamble = if ($preambleLength -gt 0) {
            [byte[]]@($bytes[0..($preambleLength - 1)])
        } else {
            [byte[]]@()
        }
        NewLine = $newline
        EndedWithNewline = $endedWithNewline
        Lines = $lines
        Acl = Get-Acl -LiteralPath $hostsPath
        Attributes = (Get-Item -LiteralPath $hostsPath -Force).Attributes
    }
}

function Write-HostsDocumentAtomic(
    $Document,
    [string[]]$Lines,
    [bool]$EndWithNewline
) {
    $currentBytes = [IO.File]::ReadAllBytes($hostsPath)
    if ((Get-ByteHash $currentBytes) -ne $Document.Hash) {
        throw "Windows hosts changed during the update. No data was overwritten."
    }
    $text = $Lines -join $Document.NewLine
    if ($EndWithNewline) { $text += $Document.NewLine }
    $body = $Document.Encoding.GetBytes($text)
    $preamble = [byte[]]$Document.Preamble
    $output = New-Object byte[] ($preamble.Length + $body.Length)
    if ($preamble.Length) {
        [Array]::Copy($preamble, 0, $output, 0, $preamble.Length)
    }
    if ($body.Length) {
        [Array]::Copy($body, 0, $output, $preamble.Length, $body.Length)
    }

    $temporary = "{0}.{1}.{2}.tmp" -f @(
        $hostsPath,
        $PID,
        [Guid]::NewGuid().ToString("N")
    )
    $backup = "{0}.{1}.{2}.backup" -f @(
        $hostsPath,
        $PID,
        [Guid]::NewGuid().ToString("N")
    )
    $completed = $false
    try {
        [IO.File]::WriteAllBytes($temporary, $output)
        Set-Acl -LiteralPath $temporary -AclObject $Document.Acl
        [IO.File]::SetAttributes($temporary, $Document.Attributes)
        [IO.File]::Replace(
            $temporary,
            $hostsPath,
            $backup,
            $true
        )
        Set-Acl -LiteralPath $hostsPath -AclObject $Document.Acl
        $completed = $true
    } finally {
        if (Test-Path -LiteralPath $temporary) {
            Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        }
        if ($completed -and (Test-Path -LiteralPath $backup)) {
            Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-WithHostsLock([scriptblock]$Operation) {
    $mutexSecurity = New-Object Security.AccessControl.MutexSecurity
    foreach ($sidValue in @("S-1-5-11", "S-1-5-18", "S-1-5-32-544")) {
        $sid = New-Object Security.Principal.SecurityIdentifier($sidValue)
        $rule = New-Object Security.AccessControl.MutexAccessRule(
            $sid,
            [Security.AccessControl.MutexRights]::FullControl,
            [Security.AccessControl.AccessControlType]::Allow
        )
        [void]$mutexSecurity.AddAccessRule($rule)
    }
    $createdNew = $false
    $mutex = New-Object Threading.Mutex(
        $false,
        $hostsMutexName,
        [ref]$createdNew,
        $mutexSecurity
    )
    $acquired = $false
    try {
        try {
            $acquired = $mutex.WaitOne([TimeSpan]::FromSeconds(30))
        } catch [Threading.AbandonedMutexException] {
            $acquired = $true
        }
        if (-not $acquired) {
            throw "Timed out waiting for another hosts update to finish."
        }
        return & $Operation
    } finally {
        if ($acquired) { [void]$mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Update-ManagedBlock($Mappings) {
    Invoke-WithHostsLock {
        $document = Read-HostsDocument
        $lines = @($document.Lines)
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

        if ($beginIndexes.Count -eq 0 -and $endIndexes.Count -eq 0) {
            $result = New-Object "Collections.Generic.List[string]"
            foreach ($line in $lines) { $result.Add($line) }
        } else {
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
        }

        if ($null -ne $Mappings) {
            if ($result.Count -gt 0 -and $result[$result.Count - 1] -ne "") {
                $result.Add("")
            }
            $result.Add($beginMarker)
            foreach ($name in @($Mappings.Keys | Sort-Object)) {
                $result.Add("$($Mappings[$name])`t$name")
            }
            $result.Add($endMarker)
        }
        $changed = (
            $null -ne $Mappings -or
            $beginIndexes.Count -ne 0 -or
            $endIndexes.Count -ne 0
        )
        if ($changed) {
            Write-HostsDocumentAtomic `
                $document `
                $result.ToArray() `
                ($document.EndedWithNewline -or $null -ne $Mappings)
        }
    }
}

function Remove-ManagedBlock {
    Update-ManagedBlock $null
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

function Get-SecureDnsProvider($Definition) {
    foreach ($provider in @($Definition.providers)) {
        if (Invoke-SecureDnsQuery $provider ([string]$Definition.probeHost)) {
            return $provider
        }
    }
    return $null
}

function Test-WebAddress(
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

function Select-ConfiguredWebAddress(
    $Override,
    $Mappings,
    [string[]]$FallbackAddresses
) {
    $cachePath = Join-Path $appRoot ([string]$Override.cacheFile)
    $candidates = New-Object "Collections.Generic.List[string]"
    $seen = New-Object "Collections.Generic.HashSet[string]" (
        [StringComparer]::OrdinalIgnoreCase
    )
    if (Test-Path -LiteralPath $cachePath -PathType Leaf) {
        $cached = (Get-Content -Raw -LiteralPath $cachePath).Trim()
        if ($cached -and $seen.Add($cached)) { $candidates.Add($cached) }
    }
    foreach ($name in @($Override.candidates)) {
        if ($Mappings.ContainsKey([string]$name)) {
            $address = $Mappings[[string]$name]
            if ($seen.Add($address)) { $candidates.Add($address) }
        }
    }
    foreach ($address in @($FallbackAddresses | Sort-Object -Unique)) {
        if ($seen.Add($address)) { $candidates.Add($address) }
    }
    $maximum = if ([int]$Override.maxCandidates -gt 0) {
        [int]$Override.maxCandidates
    } else { 6 }
    foreach ($address in @($candidates | Select-Object -First $maximum)) {
        if (Test-WebAddress ([string]$Override.testHost) $address) {
            New-Item -ItemType Directory -Path (Split-Path -Parent $cachePath) -Force |
                Out-Null
            [IO.File]::WriteAllText(
                $cachePath,
                $address + [Environment]::NewLine,
                [Text.UTF8Encoding]::new($false)
            )
            return $address
        }
    }
    return $null
}

function Get-ManagedMappings([string]$MappingAction) {
    $mappings = New-Object "Collections.Generic.Dictionary[string,string]" (
        [StringComparer]::OrdinalIgnoreCase
    )

    foreach ($definition in Get-NetworkMappingDefinitions $appRoot) {
        if ([string]$MappingAction -notin @($definition.actions)) { continue }
        $hostNames = @(Get-NetworkMappingHostNames $definition)
        if ([string]$definition.mode -eq "fixed") {
            foreach ($name in $hostNames) {
                $mappings[$name] = [string]$definition.address
            }
            continue
        }

        $fallbacks = @{}
        foreach ($property in @($definition.fallbacks.PSObject.Properties)) {
            $fallbacks[[string]$property.Name] = [string]$property.Value
        }
        $provider = Get-SecureDnsProvider $definition
        foreach ($name in $hostNames) {
            $address = if ($provider) {
                Invoke-SecureDnsQuery $provider $name
            } else { $null }
            if (-not $address -and $fallbacks.ContainsKey($name)) {
                $address = $fallbacks[$name]
            }
            if ($address) { $mappings[$name] = $address }
        }
        foreach ($override in @($definition.overrides)) {
            $selected = Select-ConfiguredWebAddress `
                $override `
                $mappings `
                @($fallbacks.Values)
            if ($selected) {
                foreach ($name in @($override.targets)) {
                    $mappings[[string]$name] = $selected
                }
            }
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

function Install-ManagedBlock([string]$MappingAction) {
    $mappings = Get-ManagedMappings $MappingAction
    Update-ManagedBlock $mappings
    Clear-DnsClientCache -ErrorAction SilentlyContinue
    return $mappings.Count
}

switch ($Action) {
    "install" {
        $count = Install-ManagedBlock "install"
        Write-Output "Temporary network mappings installed: $count."
    }
    "refresh" {
        $count = Install-ManagedBlock "refresh"
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
            try { [void](Install-ManagedBlock "refresh") } catch {}
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
