$script:TpmUtf8NoBom = New-Object Text.UTF8Encoding($false)

function Get-TpmMeaningfulLines([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
    return @(
        Get-Content -LiteralPath $Path |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -and -not $_.StartsWith("#") }
    )
}

function ConvertTo-TpmDomain([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { throw "A domain is required." }
    $domain = $Value.Trim().ToLowerInvariant()
    $exact = $domain.StartsWith("^")
    if ($exact) { $domain = $domain.Substring(1) }
    $domain = $domain.TrimEnd(".")
    if (
        $domain.Contains("://") -or
        $domain.Contains("/") -or
        $domain.Contains(":") -or
        $domain.Contains("*")
    ) {
        throw "'$Value' is not a domain. Enter a name without a scheme, path, port, or '*'."
    }
    try {
        $domain = (New-Object Globalization.IdnMapping).GetAscii($domain)
    } catch {
        throw "Invalid domain name: $Value"
    }
    if (
        $domain.Length -gt 253 -or
        $domain -notmatch "^[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?$"
    ) {
        throw "Invalid domain name: $Value"
    }
    foreach ($label in $domain.Split(".")) {
        if (
            -not $label -or
            $label.Length -gt 63 -or
            $label.StartsWith("-") -or
            $label.EndsWith("-")
        ) {
            throw "Invalid domain name: $Value"
        }
    }
    return $(if ($exact) { "^$domain" } else { $domain })
}

function ConvertTo-TpmIpNetwork([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw "An IP address or CIDR is required."
    }
    $candidate = $Value.Trim()
    $parts = $candidate.Split("/")
    if ($parts.Count -gt 2) { throw "Invalid IP/CIDR: $Value" }
    $address = $null
    if (-not [Net.IPAddress]::TryParse($parts[0], [ref]$address)) {
        throw "Invalid IP address: $Value"
    }
    if ($parts.Count -eq 1) {
        return $address.ToString().ToLowerInvariant()
    }
    $prefix = 0
    if (-not [int]::TryParse($parts[1], [ref]$prefix)) {
        throw "Invalid CIDR prefix length: $Value"
    }
    $maximum = if (
        $address.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork
    ) { 32 } else { 128 }
    if ($prefix -lt 0 -or $prefix -gt $maximum) {
        throw "The CIDR prefix length for this address must be between 0 and $maximum."
    }
    return "$($address.ToString().ToLowerInvariant())/$prefix"
}

function Test-TpmIsAdministrator {
    if ($env:OS -ne "Windows_NT") { return $true }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
}

function Test-TpmArgumentVector([string[]]$ArgumentList) {
    foreach ($argument in @($ArgumentList)) {
        if ($null -eq $argument) { throw "Process arguments must not be null." }
        if ($argument.IndexOf([char]0) -ge 0 -or $argument -match "[\r\n]") {
            throw "Process arguments must not contain NUL or line breaks."
        }
    }
    return $true
}

function ConvertTo-TpmWindowsArgument([string]$Argument) {
    if ($null -eq $Argument) { throw "A process argument must not be null." }
    if ($Argument.IndexOf([char]0) -ge 0 -or $Argument -match "[\r\n]") {
        throw "A process argument must not contain NUL or line breaks."
    }
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

function New-TpmProcessStartInfo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [string[]]$ArgumentList = @(),
        [string]$WorkingDirectory = "",
        [switch]$UseShellExecute,
        [switch]$CreateNoWindow,
        [switch]$RedirectStandardOutput,
        [switch]$RedirectStandardError,
        [ValidateSet("Normal", "Hidden", "Minimized", "Maximized")]
        [string]$WindowStyle = "Normal"
    )

    [void](Test-TpmArgumentVector $ArgumentList)
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FilePath
    $startInfo.UseShellExecute = [bool]$UseShellExecute
    $startInfo.CreateNoWindow = [bool]$CreateNoWindow
    if ($WorkingDirectory) { $startInfo.WorkingDirectory = $WorkingDirectory }
    $startInfo.WindowStyle = [Diagnostics.ProcessWindowStyle][Enum]::Parse(
        [Diagnostics.ProcessWindowStyle],
        $WindowStyle
    )
    if ($RedirectStandardOutput) { $startInfo.RedirectStandardOutput = $true }
    if ($RedirectStandardError) { $startInfo.RedirectStandardError = $true }

    $argumentListProperty = $startInfo.PSObject.Properties["ArgumentList"]
    if ($null -ne $argumentListProperty) {
        foreach ($argument in @($ArgumentList)) {
            [void]$startInfo.ArgumentList.Add($argument)
        }
    } else {
        $startInfo.Arguments = (
            $ArgumentList |
                ForEach-Object { ConvertTo-TpmWindowsArgument $_ }
        ) -join " "
    }
    return $startInfo
}

Export-ModuleMember -Function @(
    "Get-TpmMeaningfulLines"
    "ConvertTo-TpmDomain"
    "ConvertTo-TpmIpNetwork"
    "Test-TpmIsAdministrator"
    "Test-TpmArgumentVector"
    "ConvertTo-TpmWindowsArgument"
    "New-TpmProcessStartInfo"
)
