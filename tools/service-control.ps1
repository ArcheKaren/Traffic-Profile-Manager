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
$mappingWatcher = Join-Path $appRoot "tools\watch-service-mappings.ps1"

. (Join-Path $appRoot "zapretctl.ps1") help | Out-Null

if ($Action -ne "status" -and -not (Test-IsAdministrator)) {
    throw "Administrator rights are required."
}

function Remove-ManagedService {
    $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
    if ($service) {
        if ($service.Status -ne "Stopped") {
            Stop-Service -Name $serviceName -Force -ErrorAction SilentlyContinue
            $service.WaitForStatus("Stopped", [TimeSpan]::FromSeconds(10))
        }
        & sc.exe delete $serviceName | Out-Null
        Start-Sleep -Milliseconds 500
    }
}

function Remove-ManagedRefreshTask {
    $task = Get-ScheduledTask -TaskName $mappingTaskName -ErrorAction SilentlyContinue
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
        if (-not $Profile -or $Profile -notmatch "^[a-zA-Z0-9_-]+$") {
            throw "A valid profile name is required."
        }
        if (-not (Test-Path -LiteralPath (Join-Path $appRoot "config\profiles\$Profile.json"))) {
            throw "Profile not found: $Profile"
        }
        if (Get-Process -Name "winws2" -ErrorAction SilentlyContinue) {
            throw "Stop the currently running profile before installing the service."
        }

        Remove-ManagedRefreshTask
        Remove-ManagedService
        & (Join-Path $appRoot "manage-network-mappings.ps1") install | Out-Null

        try {
            $executable = Find-RuntimeExecutable
            if (-not $executable) { throw "Runtime executable was not found." }
            $arguments = @(
                Build-WinwsArguments $false $Profile |
                    Where-Object { $_ -ne "--daemon" -and -not $_.StartsWith("--pidfile=") }
            )
            $binaryPath = (Quote-WindowsArgument $executable) + " " +
                (($arguments | ForEach-Object { Quote-WindowsArgument $_ }) -join " ")

            New-Service -Name $serviceName `
                -BinaryPathName $binaryPath `
                -DisplayName $serviceDisplayName `
                -Description "Applies the selected local traffic profile." `
                -StartupType Automatic | Out-Null
            Start-Service -Name $serviceName
            & (Join-Path $appRoot "manage-network-mappings.ps1") refresh | Out-Null
            [IO.File]::WriteAllText($profileState, $Profile)
            Write-Host "Service installed and started." -ForegroundColor Green
            Write-Host "Profile: $Profile"
            Write-Host "Startup mapping refresh: off"
            Write-Host "Enable it explicitly from Manager.bat if required."
            Write-Host "Keep this folder at its current location while the service is installed."
        } catch {
            Remove-ManagedRefreshTask
            Remove-ManagedService
            & (Join-Path $appRoot "manage-network-mappings.ps1") cleanup
            throw
        }
    }
    "remove" {
        Remove-ManagedRefreshTask
        Remove-ManagedService
        & (Join-Path $appRoot "manage-network-mappings.ps1") cleanup
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
            }
        } else {
            Write-Host "Service: not installed"
        }
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
        $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
        if (-not $service) {
            throw "The automatic service is not installed."
        }
        if ($service.Status -ne "Running") {
            Start-Service -Name $serviceName
            $service.WaitForStatus("Running", [TimeSpan]::FromSeconds(15))
        }
        & (Join-Path $appRoot "manage-network-mappings.ps1") refresh | Out-Null
        $task = Get-ScheduledTask -TaskName $mappingTaskName -ErrorAction SilentlyContinue
        if ($task) {
            Start-ScheduledTask -TaskName $mappingTaskName
        }
        Write-Host "Service started." -ForegroundColor Green
        Write-Host "Startup mapping refresh: $(if ($task) { 'on' } else { 'off' })"
    }
    "stop" {
        $task = Get-ScheduledTask -TaskName $mappingTaskName -ErrorAction SilentlyContinue
        if ($task) {
            Stop-ScheduledTask -TaskName $mappingTaskName -ErrorAction SilentlyContinue
        }
        $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
        if ($service -and $service.Status -ne "Stopped") {
            Stop-Service -Name $serviceName -Force
            $service.WaitForStatus("Stopped", [TimeSpan]::FromSeconds(15))
        }
        & (Join-Path $appRoot "manage-network-mappings.ps1") cleanup
        Write-Host "Service stopped for the current Windows session." -ForegroundColor Green
        if ($task) {
            Write-Host "Startup mapping refresh remains on for the next Windows startup."
        }
    }
    "task-on" {
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
        & (Join-Path $appRoot "manage-network-mappings.ps1") refresh | Out-Host
        Write-Host "Temporary mappings refreshed." -ForegroundColor Green
    }
    "cleanup" {
        if (Get-Process -Name "winws2" -ErrorAction SilentlyContinue) {
            throw "Stop the active profile or service before cleaning temporary mappings."
        }
        & (Join-Path $appRoot "manage-network-mappings.ps1") cleanup
        Write-Host "Temporary mappings cleaned." -ForegroundColor Green
    }
}
