function Invoke-TpmGitRead([string]$Root, [string[]]$Arguments) {
    $process = $null
    try {
        $git = Get-Command git.exe -ErrorAction Stop
        $startInfo = New-TpmProcessStartInfo -FilePath $git.Source `
            -ArgumentList (@("--no-optional-locks", "-C", $Root) + $Arguments) `
            -CreateNoWindow -RedirectStandardOutput -RedirectStandardError
        $process = [Diagnostics.Process]::Start($startInfo)
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(5000)) {
            $process.Kill()
            return $null
        }
        if ($process.ExitCode -ne 0) { return $null }
        [void]$stderr.GetAwaiter().GetResult()
        return [pscustomobject]@{ Text = $stdout.GetAwaiter().GetResult().Trim() }
    } catch {
        return $null
    } finally {
        if ($process) { $process.Dispose() }
    }
}

function Get-TpmBuildInfo {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$AppRoot)

    $root = [IO.Path]::GetFullPath($AppRoot)
    $versionPath = Join-Path $root "metadata\VERSION"
    if (-not (Test-Path -LiteralPath $versionPath -PathType Leaf)) { $versionPath = Join-Path $root "VERSION" }
    $version = if (Test-Path -LiteralPath $versionPath -PathType Leaf) {
        [IO.File]::ReadAllText($versionPath).Trim()
    } else { "unknown" }
    $result = [ordered]@{
        schemaVersion = 1
        version = $version
        commit = $null
        localChanges = $null
        contentSha256 = $null
        source = "unknown"
    }
    $metadataPath = Join-Path $root "metadata\BUILD-INFO.json"
    if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) { $metadataPath = Join-Path $root "BUILD-INFO.json" }
    if (Test-Path -LiteralPath $metadataPath -PathType Leaf) {
        try {
            $metadata = [IO.File]::ReadAllText($metadataPath) | ConvertFrom-Json
            if (
                $metadata.schemaVersion -ne 1 -or
                $metadata.version -cne $version -or
                ($null -ne $metadata.commit -and $metadata.commit -notmatch '^[a-f0-9]{40,64}$') -or
                ($null -ne $metadata.localChanges -and $metadata.localChanges -isnot [bool]) -or
                $metadata.contentSha256 -notmatch '^[A-Fa-f0-9]{64}$'
            ) { throw "Invalid build metadata." }
            $result.commit = $metadata.commit
            $result.localChanges = $metadata.localChanges
            $result.contentSha256 = $metadata.contentSha256
            $result.source = "package"
        } catch {
            # Older or damaged metadata must not prevent inspecting the application.
            $result.source = "invalid-metadata"
        }
    } elseif (Test-Path -LiteralPath (Join-Path $root ".git")) {
        $commit = Invoke-TpmGitRead $root @("rev-parse", "--verify", "HEAD")
        $status = Invoke-TpmGitRead $root @(
            "-c", "core.fsmonitor=false", "status", "--porcelain", "--untracked-files=normal"
        )
        if ($commit -and $commit.Text -match '^[a-f0-9]{40,64}$') {
            $result.commit = $commit.Text
            $result.source = "git"
            if ($null -ne $status) { $result.localChanges = [bool]$status.Text }
        }
    }
    return [pscustomobject]$result
}
