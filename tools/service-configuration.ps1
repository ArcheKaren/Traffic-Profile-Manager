function Get-ManagedServiceProfile {
    $protectedConfig=Join-Path $serviceRoot 'config/config.json'
    if(Test-Path -LiteralPath $protectedConfig -PathType Leaf){
        return [string]([IO.File]::ReadAllText($protectedConfig)|ConvertFrom-Json).activeProfile
    }
    if(Test-Path -LiteralPath $profileState -PathType Leaf){return [IO.File]::ReadAllText($profileState).Trim()}
    return ''
}
# Loaded by service-control.ps1, which owns the SCM, path, ACL and task checks.
function Set-ManagedServiceBinaryPath([string]$BinaryPath) {
    $instance = Get-CimInstance -ClassName Win32_Service -Filter "Name='TrafficProfileService'" -ErrorAction Stop
    $result = Invoke-CimMethod -InputObject $instance -MethodName Change -Arguments @{PathName=$BinaryPath} -ErrorAction Stop
    if ($result.ReturnValue -ne 0) { throw "Windows rejected the service command: $($result.ReturnValue)" }
}

function Get-ProtectedLaunchBinaryPath([string]$ProfileId) {
    $info = New-TpmProcessStartInfo -FilePath powershell.exe -ArgumentList @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $serviceRoot 'zapretctl.ps1'),'launch-spec',$ProfileId) -CreateNoWindow -RedirectStandardOutput -RedirectStandardError
    $process = [Diagnostics.Process]::Start($info)
    try {
        $output = $process.StandardOutput.ReadToEndAsync(); $errors = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(30000)) { $process.Kill(); throw 'Protected launch specification timed out.' }
        if ($process.ExitCode -ne 0) { throw ('Protected launch specification failed: '+$output.GetAwaiter().GetResult()+$errors.GetAwaiter().GetResult()) }
        $spec = $output.GetAwaiter().GetResult() | ConvertFrom-Json
        $expected = [IO.Path]::GetFullPath((Join-Path $serviceRoot 'runtime/winws2.exe'))
        if ($spec.schemaVersion -ne 1 -or [IO.Path]::GetFullPath([string]$spec.executable) -ine $expected -or $null -eq $spec.arguments) { throw 'Invalid protected launch specification.' }
        [void](Test-TpmArgumentVector @($spec.arguments))
        return (ConvertTo-TpmWindowsArgument $expected)+' '+((@($spec.arguments)|ForEach-Object {ConvertTo-TpmWindowsArgument ([string]$_)}) -join ' ')
    } finally { $process.Dispose() }
}

function Apply-ManagedServiceConfiguration {
    Assert-ManagedServiceOwnership
    Assert-ServiceDeploymentOwnership
    $service = Get-Service -Name $serviceName -ErrorAction Stop
    $running = $service.Status -eq 'Running'
    $serviceInfo = Get-CimInstance -ClassName Win32_Service -Filter "Name='TrafficProfileService'" -ErrorAction Stop
    $oldBinaryPath = $serviceInfo.PathName
    if (@(Get-Process -Name winws2 -ErrorAction SilentlyContinue | Where-Object Id -ne $serviceInfo.ProcessId).Count) { throw 'Stop other running traffic profiles before applying service settings.' }
    $task = Get-ManagedRefreshTask
    $taskRunning = $task -and $task.State -eq 'Running'
    $config = [IO.File]::ReadAllText((Join-Path $appRoot 'config/config.json')) | ConvertFrom-Json
    $profileId = if ($Profile) { $Profile } else { [string]$config.activeProfile }
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'modules/TrafficProfileManager.Maintenance/TrafficProfileManager.Maintenance.psd1') -ErrorAction Stop
    $module = Get-Module TrafficProfileManager.Maintenance
    $activate = {
        param($Id,$WasRunning,$TaskWasRunning)
        Set-ManagedServiceBinaryPath (Get-ProtectedLaunchBinaryPath $Id)
        Set-ProtectedServiceAcl
        if($WasRunning){Start-Service -Name $serviceName -ErrorAction Stop;(Get-Service $serviceName).WaitForStatus('Running',[TimeSpan]::FromSeconds(15));Invoke-ServiceMapping refresh | Out-Null}
        else{Invoke-ServiceMapping cleanup | Out-Null}
        if($TaskWasRunning -and $WasRunning){Start-ScheduledTask -TaskName $mappingTaskName -ErrorAction Stop}
    }
    $restore = {
        param($BinaryPath,$WasRunning,$TaskWasRunning)
        Set-ManagedServiceBinaryPath $BinaryPath
        Set-ProtectedServiceAcl
        if($WasRunning){Start-Service -Name $serviceName -ErrorAction Stop;(Get-Service $serviceName).WaitForStatus('Running',[TimeSpan]::FromSeconds(15));Invoke-ServiceMapping refresh | Out-Null}
        else{Invoke-ServiceMapping cleanup | Out-Null}
        if($TaskWasRunning -and $WasRunning){Start-ScheduledTask -TaskName $mappingTaskName -ErrorAction Stop}
    }
    & $module {
        param($AppRoot,$ServiceRoot,$ProfileId,$WasRunning,$TaskRunning,$OldBinaryPath,$Activate,$Restore)
        Invoke-MaintenanceLock $AppRoot {
            [void](Sync-DomainCatalog $AppRoot)
            $stage = New-TpmDataStage $AppRoot
            $transaction = $null; $activationAttempted=$false
            try {
                $candidatePath=Join-Path $stage 'config/config.json'
                $candidate=[IO.File]::ReadAllText($candidatePath)|ConvertFrom-Json
                $candidate.activeProfile=$ProfileId
                # Validate with the exact installed engine, without starting packet interception.
                $candidate.runtimePath=Join-Path $ServiceRoot 'runtime/winws2.exe'
                Write-MaintenanceJson $candidatePath $candidate
                Invoke-TpmCandidateCheck $AppRoot $stage $ProfileId
                $candidate.runtimePath='runtime\winws2.exe'
                Write-MaintenanceJson $candidatePath $candidate
                $changes=@()
                foreach($directory in @('config','lists','assets')){
                    $old=Resolve-MaintenancePath $ServiceRoot $directory
                    $new=Join-Path $stage $directory
                    $paths=@()
                    if(Test-Path -LiteralPath $old){$paths+=@(Get-ChildItem -LiteralPath $old -File -Recurse|ForEach-Object {$_.FullName.Substring($ServiceRoot.TrimEnd('\').Length+1)})}
                    if(Test-Path -LiteralPath $new){$paths+=@(Get-ChildItem -LiteralPath $new -File -Recurse|ForEach-Object {$_.FullName.Substring($stage.Length+1)})}
                    foreach($relative in @($paths|Sort-Object -Unique)){
                        [void](Resolve-MaintenancePath $ServiceRoot $relative)
                        $source=Resolve-MaintenancePath $stage $relative
                        $changes+=[pscustomobject]@{path=$relative;source=$(if(Test-Path -LiteralPath $source){$source}else{$null})}
                    }
                }
                foreach($name in @('enabled-game-filters.txt','universal-game-transport.json','domain-packs.json')){
                    $source=Resolve-MaintenancePath $stage "state/$name"
                    $changes+=[pscustomobject]@{path="state/$name";source=$(if(Test-Path -LiteralPath $source){$source}else{$null})}
                }
                $snapshot=New-TpmConfigurationSnapshot $stage $ProfileId
                Write-MaintenanceJson (Join-Path $stage 'applied-service.json') $snapshot
                $changes+=[pscustomobject]@{path='state/applied-service.json';source=(Join-Path $stage 'applied-service.json')}
                # No privileged state has changed until all candidate validation has passed.
                $activationAttempted=$true
                if($TaskRunning){Stop-ScheduledTask -TaskName TrafficProfileMappingRefresh -ErrorAction Stop}
                if($WasRunning){Stop-Service -Name TrafficProfileService -ErrorAction Stop;(Get-Service TrafficProfileService).WaitForStatus('Stopped',[TimeSpan]::FromSeconds(15))}
                $transaction=Invoke-FileTransaction $ServiceRoot $changes 'apply-service-configuration'
                # SCM ownership/path/ACL helpers stay in service-control.ps1's script scope.
                & $Activate $ProfileId $WasRunning $TaskRunning
                [pscustomobject]@{profile=$ProfileId;applied=$true;running=$WasRunning;transactionId=$transaction.transactionId}
            } catch {
                $failure=$_
                if($activationAttempted){
                    try {
                        Stop-Service -Name TrafficProfileService -ErrorAction Stop
                        (Get-Service TrafficProfileService).WaitForStatus('Stopped',[TimeSpan]::FromSeconds(15))
                        if($transaction){
                            $directory=Resolve-MaintenancePath $ServiceRoot ("backups/transactions/"+$transaction.transactionId)
                            $journal=[IO.File]::ReadAllText((Join-Path $directory 'transaction.json'))|ConvertFrom-Json
                            Undo-TransactionFiles $ServiceRoot $directory $journal
                        }
                        & $Restore $OldBinaryPath $WasRunning $TaskRunning
                    } catch { throw ('Applying settings failed; automatic recovery was incomplete. Inspect the service state. '+$failure.Exception.Message+'; '+$_.Exception.Message) }
                }
                throw $failure
            } finally { Remove-Item -LiteralPath $stage -Recurse -Force }
        }
    } $appRoot $serviceRoot $profileId $running $taskRunning $oldBinaryPath $activate $restore
}
