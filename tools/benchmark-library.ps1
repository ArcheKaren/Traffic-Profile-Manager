function Get-TpmBenchmarkRanking([object[]]$Rows) {
    @(
        foreach ($group in @($Rows | Where-Object { $_.ProfileId -ne '__baseline__' } | Group-Object ProfileId)) {
            $items = @($group.Group)
            $passed = @($items | Where-Object { $_.Success -eq $true -or $_.Success -eq 'True' }).Count
            $healthy = @($items | Where-Object { $_.Healthy -eq $true -or $_.Healthy -eq 'True' }).Count
            $stable = 0; $repeated = 0
            foreach ($target in @($items | Group-Object Target)) {
                if ($target.Count -ge 2 -and 'Round' -in $items[0].PSObject.Properties.Name -and 'Target' -in $items[0].PSObject.Properties.Name) {
                    $repeated++
                    if (-not @($target.Group | Where-Object { $_.Success -ne $true -and $_.Success -ne 'True' }).Count) { $stable++ }
                }
            }
            [pscustomobject]@{ProfileId=$group.Name;Number=$items[0].ProfileNumber;Profile=$items[0].Profile;Passed=$passed;Total=$items.Count
                Score=[Math]::Round(100*$passed/$items.Count,1);Healthy=$healthy;Stable=$stable;RepeatedTargets=$repeated
                StablePercent=$(if($repeated){[Math]::Round(100*$stable/$repeated,1)}else{0})}
        }
    ) | Sort-Object @{Expression='Score';Descending=$true},@{Expression='StablePercent';Descending=$true},@{Expression={if($_.Total){$_.Healthy/$_.Total}else{0}};Descending=$true},@{Expression='Number';Descending=$false}
}

function Get-TpmBenchmarkFailureKind([int]$ExitCode, [string]$HttpCode) {
    if ($ExitCode -eq 6) { return 'DNS' }
    if ($ExitCode -in @(35,51,58,60,77,83,90,91)) { return 'TLS' }
    if ($ExitCode -eq 28) { return 'timeout' }
    if ($ExitCode -eq 7) { return 'TCP' }
    if ($ExitCode -eq 0 -and $HttpCode -match '^5') { return 'HTTP 5xx' }
    if ($ExitCode -eq 0 -and $HttpCode -match '^[234]') { return 'HTTP' }
    return 'connection'
}

function Get-TpmBenchmarkSettings([string]$Path, [string]$Mode) {
    $defaults = [pscustomobject]@{schemaVersion=1;timeoutSeconds=8;startupSeconds=2;quickRounds=1;fullRounds=3;finalistCount=3;finalistExtraRounds=2;baseline=$true}
    if (Test-Path -LiteralPath $Path) {
        $value = [IO.File]::ReadAllText($Path) | ConvertFrom-Json
        if ($value -isnot [pscustomobject] -or $value.schemaVersion -ne 1) { throw 'Invalid benchmark settings schemaVersion.' }
        foreach ($field in $value.PSObject.Properties) {
            if ($field.Name -notin $defaults.PSObject.Properties.Name) { throw "Unknown benchmark setting: $($field.Name)" }
            $defaults.($field.Name) = $field.Value
        }
    }
    foreach ($name in @('timeoutSeconds','startupSeconds','quickRounds','fullRounds','finalistCount','finalistExtraRounds')) {
        $number = $defaults.$name
        $minimum = if ($name -in @('startupSeconds','finalistExtraRounds')) {0} else {1}
        $maximum = if ($name -eq 'timeoutSeconds') {120} elseif ($name -eq 'startupSeconds') {30} elseif ($name -eq 'finalistCount') {20} else {10}
        if ($number -isnot [int] -and $number -isnot [long]) { throw "benchmark.$name must be an integer." }
        if ($number -lt $minimum -or $number -gt $maximum) { throw "benchmark.$name must be between $minimum and $maximum." }
    }
    if ($defaults.baseline -isnot [bool]) { throw 'benchmark.baseline must be boolean.' }
    $defaults | Add-Member -NotePropertyName rounds -NotePropertyValue $(if ($Mode -eq 'full') {$defaults.fullRounds} else {$defaults.quickRounds})
    return $defaults
}
