param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet(
        "install",
        "remove",
        "status",
        "start",
        "stop",
        "task-on",
        "task-off",
        "refresh",
        "cleanup"
    )]
    [string]$Action,

    [Parameter(Position = 1)]
    [string]$Profile = ""
)

$ErrorActionPreference = "Stop"
$appRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$serviceName = "TrafficProfileService"
$serviceDisplayName = "Traffic Profile Service"
$mappingTaskName = "TrafficProfileMappingRefresh"
$profileState = Join-Path $appRoot "state\service-profile.txt"
$commonDataRoot = [Environment]::GetFolderPath(
    [Environment+SpecialFolder]::CommonApplicationData
)
$serviceContainer = Join-Path $commonDataRoot "TrafficProfileManager"
$serviceRoot = Join-Path $serviceContainer "Service"
$serviceMarker = Join-Path $serviceRoot ".tpm-managed-service"
$serviceMappingTool = Join-Path $serviceRoot "manage-network-mappings.ps1"
$mappingWatcher = Join-Path $serviceRoot "tools\watch-service-mappings.ps1"

. (Join-Path $appRoot "zapretctl.ps1") help | Out-Null

if ($Action -ne "status" -and -not (Test-IsAdministrator)) {
    throw "Administrator rights are required."
}

function Get-ManagedServiceExecutable {
    $registryPath = "HKLM:\SYSTEM\CurrentControlSet\Services\$serviceName"
    if (-not (Test-Path -LiteralPath $registryPath)) { return $null }
    $imagePath = [string](
        Get-ItemPropertyValue -LiteralPath $registryPath -Name ImagePath
    )
    $executable = if ($imagePath -match '^\s*"(?<path>[^"]+)"') {
        $Matches.path
    } elseif ($imagePath -match "^\s*(?<path>\S+)") {
        $Matches.path
    } else {
        ""
    }
    if (-not $executable) { return $null }
    return [IO.Path]::GetFullPath(
        [Environment]::ExpandEnvironmentVariables($executable)
    )
}

function Assert-ManagedServiceOwnership {
    $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
    if (-not $service) { return }
    $executable = Get-ManagedServiceExecutable
    $allowedRoots = @(
        [IO.Path]::GetFullPath($appRoot).TrimEnd("\")
        [IO.Path]::GetFullPath($serviceRoot).TrimEnd("\")
    )
    $owned = $false
    foreach ($root in $allowedRoots) {
        if (
            $executable -and
            $executable.StartsWith(
                $root + "\",
                [StringComparison]::OrdinalIgnoreCase
            )
        ) {
            $owned = $true
            break
        }
    }
    if (-not $owned) {
        throw (
            "A service named '$serviceName' exists but is not owned by this " +
            "Traffic Profile Manager installation. It was not modified."
        )
    }
}

function Remove-ManagedService {
    $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
    if ($service) {
        Assert-ManagedServiceOwnership
        if ($service.Status -ne "Stopped") {
            Stop-Service -Name $serviceName -Force -ErrorAction SilentlyContinue
            $service.WaitForStatus("Stopped", [TimeSpan]::FromSeconds(10))
        }
        & sc.exe delete $serviceName | Out-Null
        Start-Sleep -Milliseconds 500
    }
}

function Assert-ServiceDeploymentPath {
    $resolvedCommonData = [IO.Path]::GetFullPath($commonDataRoot).TrimEnd("\")
    $resolvedContainer = [IO.Path]::GetFullPath($serviceContainer)
    $resolvedServiceRoot = [IO.Path]::GetFullPath($serviceRoot)
    if (
        -not $resolvedContainer.StartsWith(
            $resolvedCommonData + "\",
            [StringComparison]::OrdinalIgnoreCase
        ) -or
        (Split-Path -Leaf $resolvedContainer) -cne "TrafficProfileManager" -or
        -not $resolvedServiceRoot.StartsWith(
            $resolvedContainer.TrimEnd("\") + "\",
            [StringComparison]::OrdinalIgnoreCase
        ) -or
        (Split-Path -Leaf $resolvedServiceRoot) -cne "Service"
    ) {
        throw "Unsafe protected service path: $resolvedServiceRoot"
    }
    foreach ($path in @($resolvedContainer, $resolvedServiceRoot)) {
        if (
            (Test-Path -LiteralPath $path) -and
            ((Get-Item -LiteralPath $path -Force).Attributes -band
                [IO.FileAttributes]::ReparsePoint)
        ) {
            throw "The protected service path must not be a reparse point: $path"
        }
    }
}

function Set-ProtectedServiceAcl {
    if (-not (Test-IsAdministrator)) {
        throw "Administrator rights are required to protect the service deployment."
    }
    Assert-ServiceDeploymentPath
    $inheritance = (
        [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
        [Security.AccessControl.InheritanceFlags]::ObjectInherit
    )
    $propagation = [Security.AccessControl.PropagationFlags]::None
    $allow = [Security.AccessControl.AccessControlType]::Allow
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sidValue in @("S-1-5-18", "S-1-5-32-544")) {
        $sid = New-Object Security.Principal.SecurityIdentifier($sidValue)
        $rule = New-Object Security.AccessControl.FileSystemAccessRule(
            $sid,
            [Security.AccessControl.FileSystemRights]::FullControl,
            $inheritance,
            $propagation,
            $allow
        )
        [void]$acl.AddAccessRule($rule)
    }
    $usersSid = New-Object Security.Principal.SecurityIdentifier(
        "S-1-5-32-545"
    )
    $readRule = New-Object Security.AccessControl.FileSystemAccessRule(
        $usersSid,
        [Security.AccessControl.FileSystemRights]::ReadAndExecute,
        $inheritance,
        $propagation,
        $allow
    )
    [void]$acl.AddAccessRule($readRule)
    Set-Acl -LiteralPath $serviceContainer -AclObject $acl
    Set-Acl -LiteralPath $serviceRoot -AclObject $acl

    $effective = Get-Acl -LiteralPath $serviceRoot
    $allowedSids = @("S-1-5-18", "S-1-5-32-544")
    $writeMask = (
        [Security.AccessControl.FileSystemRights]::WriteData -bor
        [Security.AccessControl.FileSystemRights]::AppendData -bor
        [Security.AccessControl.FileSystemRights]::WriteExtendedAttributes -bor
        [Security.AccessControl.FileSystemRights]::WriteAttributes -bor
        [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor
        [Security.AccessControl.FileSystemRights]::Delete -bor
        [Security.AccessControl.FileSystemRights]::ChangePermissions -bor
        [Security.AccessControl.FileSystemRights]::TakeOwnership
    )
    foreach ($rule in $effective.Access) {
        if ($rule.AccessControlType -ne $allow) { continue }
        $sid = $rule.IdentityReference.Translate(
            [Security.Principal.SecurityIdentifier]
        ).Value
        if (
            $sid -notin $allowedSids -and
            (([int64]$rule.FileSystemRights -band [int64]$writeMask) -ne 0)
        ) {
            throw "Protected service directory is writable by $sid."
        }
    }
}

function Assert-ServiceDeploymentOwnership {
    Assert-ServiceDeploymentPath
    if (
        (Test-Path -LiteralPath $serviceRoot -PathType Container) -and
        -not (Test-Path -LiteralPath $serviceMarker -PathType Leaf)
    ) {
        throw (
            "An unrecognized protected service directory exists at " +
            "'$serviceRoot'. It was not modified."
        )
    }
}

function Remove-ServiceDeployment {
    Assert-ServiceDeploymentOwnership
    if (-not (Test-Path -LiteralPath $serviceRoot -PathType Container)) {
        return
    }
    $reparsePoint = Get-ChildItem -LiteralPath $serviceRoot -Force -Recurse |
        Where-Object {
            $_.Attributes -band [IO.FileAttributes]::ReparsePoint
        } |
        Select-Object -First 1
    if ($reparsePoint) {
        throw "Refusing to remove a service deployment containing a reparse point: $($reparsePoint.FullName)"
    }
    Remove-Item -LiteralPath $serviceRoot -Recurse -Force
}

function Copy-ServiceTree([string]$RelativePath) {
    $sourceRoot = Join-Path $appRoot $RelativePath
    if (-not (Test-Path -LiteralPath $sourceRoot -PathType Container)) {
        throw "Service source directory was not found: $RelativePath"
    }
    foreach ($file in Get-ChildItem -LiteralPath $sourceRoot -File -Recurse) {
        $relativeFile = $file.FullName.Substring($appRoot.Length + 1)
        $destination = Join-Path $serviceRoot $relativeFile
        New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force |
            Out-Null
        Copy-Item -LiteralPath $file.FullName -Destination $destination -Force
    }
}

function Copy-ServiceFile(
    [string]$Source,
    [string]$RelativeDestination
) {
    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) {
        throw "Service source file was not found: $Source"
    }
    $destination = Join-Path $serviceRoot $RelativeDestination
    New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force |
        Out-Null
    Copy-Item -LiteralPath $Source -Destination $destination -Force
}

function Get-VerifiedServiceRuntimeFile([string]$Key) {
    $manifestPath = Join-Path $appRoot "runtime\SOURCE.json"
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "Runtime provenance manifest was not found: $manifestPath"
    }
    $manifest = Get-Content -Raw -LiteralPath $manifestPath |
        ConvertFrom-Json
    $property = $manifest.runtimeFiles.PSObject.Properties[$Key]
    $entry = if ($property) { $property.Value } else { $null }
    if (
        -not $entry -or
        [string]$entry.sha256 -notmatch "^[A-Fa-f0-9]{64}$"
    ) {
        throw "Runtime provenance entry '$Key' is missing or invalid."
    }
    $runtimeRoot = [IO.Path]::GetFullPath(
        (Join-Path $appRoot "runtime")
    ).TrimEnd("\")
    $candidates = @(
        [string]$entry.releasePath
        [string]$entry.path
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    foreach ($relativePath in $candidates) {
        if ([IO.Path]::IsPathRooted($relativePath)) { continue }
        $candidate = [IO.Path]::GetFullPath(
            (Join-Path $runtimeRoot $relativePath)
        )
        if (-not $candidate.StartsWith(
            $runtimeRoot + "\",
            [StringComparison]::OrdinalIgnoreCase
        )) {
            continue
        }
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            continue
        }
        $file = Get-Item -LiteralPath $candidate
        if (
            $file.Length -eq [int64]$entry.length -and
            (Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash -ieq
                [string]$entry.sha256
        ) {
            return $candidate
        }
        throw "Runtime provenance mismatch: $relativePath"
    }
    throw "Verified runtime component was not found for '$Key'."
}

function Sync-ServiceMutableData {
    if (-not (Test-Path -LiteralPath $serviceMarker -PathType Leaf)) {
        throw "The protected service deployment is missing."
    }
    foreach ($directory in @(
        "config\game-filters",
        "config\network-mappings",
        "lists"
    )) {
        Copy-ServiceTree $directory
    }
    $enabledState = Join-Path $appRoot "state\enabled-game-filters.txt"
    $protectedState = Join-Path $serviceRoot "state\enabled-game-filters.txt"
    if (Test-Path -LiteralPath $enabledState -PathType Leaf) {
        Copy-ServiceFile $enabledState "state\enabled-game-filters.txt"
    } elseif (Test-Path -LiteralPath $protectedState) {
        Remove-Item -LiteralPath $protectedState -Force
    }
}

function New-ServiceDeployment([string]$Profile) {
    if (-not (Test-IsAdministrator)) {
        throw "Administrator rights are required to create the service deployment."
    }
    Assert-ServiceDeploymentPath
    Remove-ServiceDeployment
    New-Item -ItemType Directory -Path $serviceRoot -Force | Out-Null
    [IO.File]::WriteAllText(
        $serviceMarker,
        "Traffic Profile Manager protected service deployment.`r`n",
        [Text.UTF8Encoding]::new($false)
    )
    try {
        Set-ProtectedServiceAcl
        $runtimeFiles = [ordered]@{
            "runtime\winws2.exe" = $(Get-VerifiedServiceRuntimeFile "winws2")
            "runtime\WinDivert.dll" = $(Get-VerifiedServiceRuntimeFile "winDivertDll")
            "runtime\WinDivert64.sys" = $(Get-VerifiedServiceRuntimeFile "winDivertDriver")
            "runtime\cygwin1.dll" = $(Get-VerifiedServiceRuntimeFile "cygwin")
            "runtime\lua\zapret-lib.lua" = $(Get-VerifiedServiceRuntimeFile "luaLib")
            "runtime\lua\zapret-antidpi.lua" = $(Get-VerifiedServiceRuntimeFile "luaAntidpi")
        }
        foreach ($item in $runtimeFiles.GetEnumerator()) {
            Copy-ServiceFile ([string]$item.Value) ([string]$item.Key)
        }
        Copy-ServiceFile (
            Join-Path $appRoot "runtime\SOURCE.json"
        ) "runtime\SOURCE.json"
        foreach ($relativePath in @(
            "manage-network-mappings.ps1",
            "tools\game-filter-library.ps1",
            "tools\network-mapping-library.ps1",
            "tools\watch-service-mappings.ps1"
        )) {
            Copy-ServiceFile (Join-Path $appRoot $relativePath) $relativePath
        }
        foreach ($directory in @("assets", "config\profiles")) {
            Copy-ServiceTree $directory
        }
        Copy-ServiceFile (
            Join-Path $appRoot "config\rule-groups.json"
        ) "config\rule-groups.json"
        foreach ($directory in @("logs", "state")) {
            New-Item -ItemType Directory -Path (Join-Path $serviceRoot $directory) -Force |
                Out-Null
        }
        Sync-ServiceMutableData

        $sourceConfig = Get-Content -Raw -LiteralPath (
            Join-Path $appRoot "config\config.json"
        ) | ConvertFrom-Json
        $sourceConfig.activeProfile = $Profile
        $sourceConfig.runtimePath = "runtime\winws2.exe"
        [IO.File]::WriteAllText(
            (Join-Path $serviceRoot "config\config.json"),
            ($sourceConfig | ConvertTo-Json -Depth 20) + [Environment]::NewLine,
            [Text.UTF8Encoding]::new($false)
        )
        Set-ProtectedServiceAcl
    } catch {
        $deploymentError = $_
        try {
            Remove-ServiceDeployment
        } catch {
            Write-Warning "Could not remove the partial service deployment: $($_.Exception.Message)"
        }
        throw $deploymentError
    }
}

function Invoke-ServiceMapping(
    [ValidateSet("install", "refresh", "cleanup")]
    [string]$MappingAction
) {
    if (Test-Path -LiteralPath $serviceMappingTool -PathType Leaf) {
        & $serviceMappingTool $MappingAction -AppRoot $serviceRoot
    } elseif ($MappingAction -eq "cleanup") {
        & (Join-Path $appRoot "manage-network-mappings.ps1") cleanup
    } else {
        throw "Protected service mapping tool was not found."
    }
}

function Get-ManagedRefreshTask {
    $task = Get-ScheduledTask -TaskName $mappingTaskName -ErrorAction SilentlyContinue
    if (-not $task) { return $null }
    $knownWatchers = @(
        [IO.Path]::GetFullPath(
            (Join-Path $appRoot "tools\watch-service-mappings.ps1")
        )
        [IO.Path]::GetFullPath($mappingWatcher)
    )
    $owned = $false
    foreach ($taskAction in @($task.Actions)) {
        $execute = [string]$taskAction.Execute
        $arguments = [string]$taskAction.Arguments
        if (
            (Split-Path -Leaf $execute) -in @("powershell", "powershell.exe") -and
            $arguments -match '(?i)(?:^|\s)-File\s+"(?<path>[^"]+)"'
        ) {
            $taskScript = [IO.Path]::GetFullPath(
                [Environment]::ExpandEnvironmentVariables($Matches.path)
            )
            foreach ($knownWatcher in $knownWatchers) {
                if ($taskScript.Equals(
                    $knownWatcher,
                    [StringComparison]::OrdinalIgnoreCase
                )) {
                    $owned = $true
                    break
                }
            }
        }
        if ($owned) { break }
    }
    if (-not $owned) {
        throw (
            "A scheduled task named '$mappingTaskName' exists but is not owned " +
            "by this Traffic Profile Manager installation. It was not modified."
        )
    }
    return $task
}

function Remove-ManagedRefreshTask {
    $task = Get-ManagedRefreshTask
    if (-not $task) { return }
    Stop-ScheduledTask -TaskName $mappingTaskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $mappingTaskName -Confirm:$false
}

function Install-ManagedRefreshTask {
    if (-not (Test-Path -LiteralPath $mappingWatcher -PathType Leaf)) {
        throw "Service mapping watcher was not found: $mappingWatcher"
    }

    Remove-ManagedRefreshTask
    $arguments = (
        '-NoLogo -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass ' +
        '-File "{0}" -ServiceName "{1}"'
    ) -f $mappingWatcher, $serviceName
    $action = New-ScheduledTaskAction `
        -Execute "powershell.exe" `
        -Argument $arguments
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal `
        -UserId "SYSTEM" `
        -LogonType ServiceAccount `
        -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -Hidden `
        -MultipleInstances IgnoreNew `
        -RestartCount 3 `
        -RestartInterval ([TimeSpan]::FromMinutes(1)) `
        -ExecutionTimeLimit ([TimeSpan]::Zero)

    Register-ScheduledTask `
        -TaskName $mappingTaskName `
        -Action $action `
        -Trigger $trigger `
        -Principal $principal `
        -Settings $settings `
        -Description "Refreshes temporary mappings for Traffic Profile Service." `
        -Force | Out-Null
}

switch ($Action) {
    "install" {
        Ensure-Initialized
        if (-not $Profile -or $Profile -notmatch "^[a-zA-Z0-9_-]+$") {
            throw "A valid profile name is required."
        }
        if (-not (Test-Path -LiteralPath (Join-Path $appRoot "config\profiles\$Profile.json"))) {
            throw "Profile not found: $Profile"
        }
        if (Get-Process -Name "winws2" -ErrorAction SilentlyContinue) {
            throw "Stop the currently running profile before installing the service."
        }

        Assert-ManagedServiceOwnership
        Assert-ServiceDeploymentOwnership
        Remove-ManagedRefreshTask
        Remove-ManagedService
        try {
            New-ServiceDeployment $Profile
            $sourceScriptRoot = $script:AppRoot
            $script:AppRoot = $serviceRoot
            try {
                $executable = Find-RuntimeExecutable
                $arguments = @(
                    Build-WinwsArguments $false $Profile |
                        Where-Object {
                            $_ -ne "--daemon" -and
                            -not $_.StartsWith("--pidfile=")
                        }
                )
            } finally {
                $script:AppRoot = $sourceScriptRoot
            }
            $binaryPath = (Quote-WindowsArgument $executable) + " " +
                (($arguments | ForEach-Object { Quote-WindowsArgument $_ }) -join " ")

            Invoke-ServiceMapping install | Out-Null
            New-Service -Name $serviceName `
                -BinaryPathName $binaryPath `
                -DisplayName $serviceDisplayName `
                -Description "Applies the selected local traffic profile." `
                -StartupType Automatic | Out-Null
            Start-Service -Name $serviceName
            Invoke-ServiceMapping refresh | Out-Null
            [IO.File]::WriteAllText($profileState, $Profile)
            Write-Host "Service installed and started." -ForegroundColor Green
            Write-Host "Profile: $Profile"
            Write-Host "Startup mapping refresh: off"
            Write-Host "Enable it explicitly from Manager.bat if required."
            Write-Host "The privileged runtime is isolated in the protected ProgramData deployment."
        } catch {
            $installError = $_
            foreach ($cleanupOperation in @(
                { Remove-ManagedRefreshTask },
                { Remove-ManagedService },
                { Invoke-ServiceMapping cleanup },
                { Remove-ServiceDeployment }
            )) {
                try {
                    & $cleanupOperation
                } catch {
                    Write-Warning "Installation rollback was incomplete: $($_.Exception.Message)"
                }
            }
            throw $installError
        }
    }
    "remove" {
        Assert-ManagedServiceOwnership
        Assert-ServiceDeploymentOwnership
        Remove-ManagedRefreshTask
        Remove-ManagedService
        Invoke-ServiceMapping cleanup
        Remove-ServiceDeployment
        if (Test-Path -LiteralPath $profileState) {
            Remove-Item -LiteralPath $profileState -Force
        }
        Write-Host "Service removed and temporary mappings cleaned." -ForegroundColor Green
    }
    "status" {
        $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
        if ($service) {
            Write-Host "Service: installed"
            Write-Host "State:   $($service.Status)"
            if (Test-Path -LiteralPath $profileState) {
                Write-Host "Profile: $((Get-Content -Raw -LiteralPath $profileState).Trim())"
            } elseif (
                Test-Path `
                    -LiteralPath (Join-Path $serviceRoot "config\config.json") `
                    -PathType Leaf
            ) {
                $protectedConfig = Get-Content -Raw -LiteralPath (
                    Join-Path $serviceRoot "config\config.json"
                ) | ConvertFrom-Json
                Write-Host "Profile: $([string]$protectedConfig.activeProfile)"
            }
        } else {
            Write-Host "Service: not installed"
        }
        Write-Host (
            "Protected deployment: {0}" -f
            $(if (Test-Path -LiteralPath $serviceMarker -PathType Leaf) {
                $serviceRoot
            } else {
                "missing"
            })
        )
        $task = Get-ScheduledTask -TaskName $mappingTaskName -ErrorAction SilentlyContinue
        if ($task) {
            Write-Host "Startup mapping refresh: on ($($task.State))"
        } else {
            Write-Host "Startup mapping refresh: off"
        }
        $processes = @(Get-Process -Name "winws2" -ErrorAction SilentlyContinue)
        Write-Host "Runtime processes: $($processes.Count)"
        $hostsPath = Join-Path $env:SystemRoot "System32\drivers\etc\hosts"
        $managed = Select-String -LiteralPath $hostsPath `
            -Pattern "# TrafficProfileManager Mapping BEGIN" `
            -SimpleMatch -Quiet -ErrorAction SilentlyContinue
        Write-Host "Temporary mappings: $(if ($managed) { 'active' } else { 'clean' })"
        try {
            $gameFilters = @(Get-EnabledGameFilters $appRoot -ThrowOnInvalid)
            $filterNames = @($gameFilters | ForEach-Object DisplayName)
            Write-Host (
                "Game filters: {0}" -f
                $(if ($filterNames.Count) {
                    $filterNames -join ", "
                } else {
                    "none"
                })
            )
        } catch {
            Write-Host "Game filters: invalid ($($_.Exception.Message))" `
                -ForegroundColor Red
        }
    }
    "start" {
        Assert-ManagedServiceOwnership
        Assert-ServiceDeploymentOwnership
        $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
        if (-not $service) {
            throw "The automatic service is not installed."
        }
        if ($service.Status -ne "Running") {
            Sync-ServiceMutableData
            Start-Service -Name $serviceName
            $service.WaitForStatus("Running", [TimeSpan]::FromSeconds(15))
        }
        Invoke-ServiceMapping refresh | Out-Null
        $task = Get-ManagedRefreshTask
        if ($task) {
            Start-ScheduledTask -TaskName $mappingTaskName
        }
        Write-Host "Service started." -ForegroundColor Green
        Write-Host "Startup mapping refresh: $(if ($task) { 'on' } else { 'off' })"
    }
    "stop" {
        Assert-ManagedServiceOwnership
        Assert-ServiceDeploymentOwnership
        $task = Get-ManagedRefreshTask
        if ($task) {
            Stop-ScheduledTask -TaskName $mappingTaskName -ErrorAction SilentlyContinue
        }
        $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
        if ($service -and $service.Status -ne "Stopped") {
            Stop-Service -Name $serviceName -Force
            $service.WaitForStatus("Stopped", [TimeSpan]::FromSeconds(15))
        }
        Invoke-ServiceMapping cleanup
        Write-Host "Service stopped for the current Windows session." -ForegroundColor Green
        if ($task) {
            Write-Host "Startup mapping refresh remains on for the next Windows startup."
        }
    }
    "task-on" {
        Assert-ManagedServiceOwnership
        Assert-ServiceDeploymentOwnership
        if (-not (Get-Service -Name $serviceName -ErrorAction SilentlyContinue)) {
            throw "Install the automatic service before enabling its startup refresh task."
        }
        Install-ManagedRefreshTask
        Write-Host "Startup mapping refresh: on" -ForegroundColor Green
        Write-Host "The task will begin at the next Windows startup."
    }
    "task-off" {
        Remove-ManagedRefreshTask
        Write-Host "Startup mapping refresh: off" -ForegroundColor Green
        Write-Host "The scheduled task was removed."
    }
    "refresh" {
        if (-not (Get-Process -Name "winws2" -ErrorAction SilentlyContinue)) {
            throw "No traffic profile or service is currently running."
        }
        $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
        if ($service -and $service.Status -eq "Running") {
            Assert-ManagedServiceOwnership
            Assert-ServiceDeploymentOwnership
            Sync-ServiceMutableData
            Invoke-ServiceMapping refresh | Out-Host
        } else {
            & (Join-Path $appRoot "manage-network-mappings.ps1") refresh |
                Out-Host
        }
        Write-Host "Temporary mappings refreshed." -ForegroundColor Green
    }
    "cleanup" {
        if (Get-Process -Name "winws2" -ErrorAction SilentlyContinue) {
            throw "Stop the active profile or service before cleaning temporary mappings."
        }
        Invoke-ServiceMapping cleanup
        Write-Host "Temporary mappings cleaned." -ForegroundColor Green
    }
}
