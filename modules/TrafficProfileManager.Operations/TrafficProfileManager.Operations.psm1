$script:TpmOperationsUtf8NoBom = New-Object Text.UTF8Encoding($false)

function Write-TpmOperationLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$AppRoot,

        [Parameter(Mandatory = $true)]
        [ValidatePattern("^[a-z0-9-]{1,40}$")]
        [string]$Component,

        [Parameter(Mandatory = $true)]
        [ValidatePattern("^[a-z0-9-]{1,60}$")]
        [string]$Operation,

        [Parameter(Mandatory = $true)]
        [ValidateSet("started", "succeeded", "failed")]
        [string]$Status,

        [string]$Message = "",
        [hashtable]$Data = @{}
    )

    $root = [IO.Path]::GetFullPath($AppRoot)
    $logRoot = Join-Path $root "logs"
    if (-not (Test-Path -LiteralPath $logRoot -PathType Container)) {
        New-Item -ItemType Directory -Path $logRoot -Force | Out-Null
    }
    $path = Join-Path $logRoot "operations.jsonl"
    $entry = [ordered]@{
        schemaVersion = 1
        timestampUtc = [DateTime]::UtcNow.ToString("o")
        component = $Component
        operation = $Operation
        status = $Status
        processId = $PID
        user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        message = ([string]$Message).Replace("`r", " ").Replace("`n", " ")
        data = if ($null -eq $Data) { @{} } else { $Data }
    }
    $line = ($entry | ConvertTo-Json -Depth 12 -Compress) + [Environment]::NewLine
    $bytes = $script:TpmOperationsUtf8NoBom.GetBytes($line)
    $lastError = $null
    for ($attempt = 1; $attempt -le 20; $attempt++) {
        try {
            $stream = [IO.File]::Open(
                $path,
                [IO.FileMode]::Append,
                [IO.FileAccess]::Write,
                [IO.FileShare]::Read
            )
            try {
                $stream.Write($bytes, 0, $bytes.Length)
                $stream.Flush($true)
            } finally {
                $stream.Dispose()
            }
            return
        } catch [IO.IOException] {
            $lastError = $_
            Start-Sleep -Milliseconds 25
        }
    }
    throw "Could not append the operation journal: $($lastError.Exception.Message)"
}

Export-ModuleMember -Function "Write-TpmOperationLog"
