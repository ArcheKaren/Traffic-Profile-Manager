# Executed in the comparison script's scope after its runtime helpers have been defined.
function Invoke-BenchmarkRound($Profile, [int]$Round) {
    Write-TpmUi ('{0} {1}: {2}' -f (Get-TpmText 'Round'),$Round,$Profile.Label) -Tone Title
    try {
        if ($Profile.Id -ne '__baseline__') { Start-Profile $Profile.Id }
        $checks = @(Invoke-TargetChecks $targets)
    } catch {
        $message = $_.Exception.Message
        Write-TpmUi $message -Tone Error
        $checks = @(foreach ($target in $targets) { [pscustomobject]@{Target=$target.Name;Url=$target.Url;Success=$false;Healthy=$false;HttpCode='000';ExitCode=-1;Detail=$message} })
    } finally { if ($Profile.Id -ne '__baseline__') { Stop-ActiveProfile } }
    foreach ($check in $checks) {
        $allResults.Add([pscustomobject]@{ProfileNumber=$Profile.Number;ProfileId=$Profile.Id;Profile=$Profile.Label;Round=$Round;Target=$check.Target;Url=$check.Url
            Success=$check.Success;Healthy=$check.Healthy;HttpCode=$check.HttpCode;ExitCode=$check.ExitCode;FailureKind=(Get-TpmBenchmarkFailureKind $check.ExitCode $check.HttpCode);Detail=$check.Detail})
        $mark=if(-not $check.Success){'--'}elseif($check.Healthy){'OK'}else{'UP'}
        Write-TpmUi ('  {0,-18} {1,3} HTTP {2}' -f $check.Target,$mark,$check.HttpCode) -Tone $(if($check.Healthy){'Success'}elseif($check.Success){'Warning'}else{'Error'})
    }
}
try {
    if (-not (Test-TpmIsAdministrator)) { throw 'Run tools\Test Profiles.bat and approve the administrator prompt.' }
    if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) { throw 'curl.exe is required and was not found.' }
    if (Get-Service -Name TrafficProfileService -ErrorAction SilentlyContinue | Where-Object Status -eq Running) { throw 'Stop the automatic service before running the comparison.' }
    if (@(Get-Process -Name winws2 -ErrorAction SilentlyContinue).Count) { throw 'Stop running profiles before starting the comparison. Existing sessions will not be stopped automatically.' }
    foreach ($profile in $invalidProfiles) { Write-TpmUi ($profile.Id+': '+$profile.Error) -Tone Error }
    if (-not $profileCatalog.Count) { throw 'No valid profile files were found.' }
    $targets = @(Read-Targets)
    $selected = if ($Profiles.Count) { @($profileCatalog | Where-Object Id -in $Profiles) } else { $profileCatalog }
    if ($Profiles.Count -and $selected.Count -ne @($Profiles | Select-Object -Unique).Count) { throw 'One or more profile IDs are unknown.' }
    Write-TpmUi 'Traffic Profile Comparison' -Tone Title
    Write-TpmUi ('Profiles: {0}   Endpoints: {1}' -f $selected.Count,$targets.Count)
    Write-TpmUi 'HTTP reachability does not verify game latency or voice connections.' -Tone Warning
    if (-not $NonInteractive) {
        Write-TpmUi '[1] Quick: one pass and repeated checks of the leaders'
        Write-TpmUi '[2] Full: repeated checks of every profile'
        Write-TpmUi '[0] Cancel'
        $choice=Read-TpmUi 'Select an option'
        if ($choice -eq '0' -or $choice -match '^(q|quit)$') { return }
        if ($choice -eq '2') { $Mode='full';if(-not $PSBoundParameters.ContainsKey('Rounds')){$Rounds=$settings.fullRounds} }
        elseif ($choice -eq '1') { $Mode='quick';if(-not $PSBoundParameters.ContainsKey('Rounds')){$Rounds=$settings.quickRounds} }
        elseif ($choice) { throw 'Invalid comparison mode.' }
    }
    # Preflight and the prompt precede files, mappings and worker processes.
    New-Item -ItemType Directory -Path $resultRoot,$stateRoot -Force | Out-Null
    $allResults=New-Object 'Collections.Generic.List[object]'
    if ($settings.baseline -and -not $SkipBaseline) {
        Write-TpmUi 'Baseline: no profile, current system DNS and hosts settings.' -Tone Info
        $baseline=[pscustomobject]@{Number=0;Id='__baseline__';Label='Baseline (no profile)'}
        for($round=1;$round -le $Rounds;$round++){Invoke-BenchmarkRound $baseline $round}
    }
    [IO.File]::WriteAllLines($benchmarkHostList,@('# Temporary comparison targets')+@($targets.Host|Sort-Object -Unique),[Text.UTF8Encoding]::new($false))
    $env:TRAFFIC_PROFILE_BENCHMARK_LIST=$benchmarkHostList
    $script:managedMappingsInstalled=$true
    & (Join-Path $appRoot 'tools/manage-network-mappings.ps1') install | Out-Host
    $watcherInfo=New-TpmProcessStartInfo -FilePath powershell.exe -ArgumentList @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $appRoot 'tools/watch-benchmark.ps1'),'-ControllerPid',[string]$PID,'-ControllerStartTicks',[string](Get-Process -Id $PID).StartTime.ToUniversalTime().Ticks) -UseShellExecute -WindowStyle Hidden
    [void][Diagnostics.Process]::Start($watcherInfo)
    $profileIndex=0
    foreach($profile in $selected){
        $profileIndex++
        Write-Progress -Activity (Get-TpmText 'Traffic Profile Comparison') -Status $profile.Label -PercentComplete (100*$profileIndex/$selected.Count)
        for($round=1;$round -le $Rounds;$round++){Invoke-BenchmarkRound $profile $round}
    }
    if($Mode -eq 'quick' -and $settings.finalistExtraRounds -gt 0){
        $leaders=@(Get-TpmBenchmarkRanking $allResults.ToArray() | Select-Object -First $settings.finalistCount)
        Write-TpmUi 'Rechecking the leading profiles' -Tone Title
        foreach($leader in $leaders){
            $profile=@($selected|Where-Object Id -eq $leader.ProfileId)[0]
            for($extra=1;$extra -le $settings.finalistExtraRounds;$extra++){Invoke-BenchmarkRound $profile ($Rounds+$extra)}
        }
    }
    Write-Progress -Activity (Get-TpmText 'Traffic Profile Comparison') -Completed
    $ranking=@(Get-TpmBenchmarkRanking $allResults.ToArray())
    $stamp=Get-Date -Format 'yyyyMMdd-HHmmss-fff'
    $csvPath=Join-Path $resultRoot "profile-comparison-$stamp.csv"
    $textPath=Join-Path $resultRoot "profile-comparison-$stamp.txt"
    $allResults|Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8
    $baselineRows=@($allResults|Where-Object ProfileId -eq '__baseline__')
    $baselineScore=if($baselineRows.Count){[Math]::Round(100*@($baselineRows|Where-Object Success).Count/$baselineRows.Count,1)}else{$null}
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'modules/TrafficProfileManager.Maintenance/TrafficProfileManager.Maintenance.psd1') -ErrorAction Stop
    $snapshot=New-TpmConfigurationSnapshot $appRoot
    $metadata=[ordered]@{schemaVersion=2;generatedAt=[DateTimeOffset]::Now.ToString('o');version=(Get-TpmBuildInfo $appRoot).version;targets=@($targets.Url);profiles=@($selected.Id);mode=$Mode;rounds=$Rounds;baselineScore=$baselineScore;configurationSha256=$snapshot.contentSha256;ranking=$ranking}
    [IO.File]::WriteAllText((Join-Path $resultRoot "profile-comparison-$stamp.json"),($metadata|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
    $summary=@('Traffic Profile Comparison',"Created: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')","Mode: $Mode; initial rounds: $Rounds","Baseline reachability: $baselineScore",'Score = HTTP reachability, not application health. Stable = targets reached in every repeated check.','Quick mode repeats leaders only; single-pass results do not establish stability.','',($ranking|Format-Table Number,Profile,Passed,Total,Score,Stable,RepeatedTargets -AutoSize|Out-String).TrimEnd(),'', 'Errors by stage:',($allResults|Where-Object {-not $_.Healthy}|Group-Object FailureKind|Select-Object Name,Count|Format-Table -AutoSize|Out-String).TrimEnd())
    [IO.File]::WriteAllLines($textPath,$summary,[Text.UTF8Encoding]::new($false))
    Write-TpmUi 'Ranking' -Tone Title
    foreach($item in $ranking){
        Write-TpmUi ('{0}. {1}: {2}% ({3}/{4})' -f $item.Number,$item.Profile,$item.Score,$item.Passed,$item.Total)
        if($item.RepeatedTargets){Write-TpmUi ('  '+(Get-TpmText 'Stable targets')+': '+$item.Stable+'/'+$item.RepeatedTargets)}
    }
    Write-TpmUi 'Reports:'
    Write-TpmUi ('  '+$textPath);Write-TpmUi ('  '+$csvPath)
    if(-not @($ranking|Where-Object Score -gt 0).Count){Write-TpmUi 'No reachable targets. A working strategy could not be recommended.' -Tone Warning}
    elseif($null -ne $baselineScore -and $baselineScore -ge $ranking[0].Score){Write-TpmUi 'No reachability improvement over the baseline was measured.' -Tone Warning}
    elseif($ranking[0].RepeatedTargets -lt $targets.Count){Write-TpmUi 'The leading result needs repeated verification. Use full mode to confirm it.' -Tone Warning}
    else{Write-TpmUi ('Best result: '+$ranking[0].Profile) -Tone Success}
} finally {
    Stop-ActiveProfile
    if($script:managedMappingsInstalled){& (Join-Path $appRoot 'tools/manage-network-mappings.ps1') cleanup *> $null}
    if($null -eq $originalBenchmarkEnvironment){Remove-Item Env:\TRAFFIC_PROFILE_BENCHMARK_LIST -ErrorAction SilentlyContinue}else{$env:TRAFFIC_PROFILE_BENCHMARK_LIST=$originalBenchmarkEnvironment}
    if($script:managedMappingsInstalled -and (Test-Path -LiteralPath $benchmarkHostList)){Remove-Item -LiteralPath $benchmarkHostList -Force -ErrorAction SilentlyContinue}
}
