Describe 'Repeated comparison and baseline ranking' {
    BeforeAll {
        $projectRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        . (Join-Path $projectRoot 'tools/benchmark-library.ps1')
        function New-Check([string]$Profile,[string]$Target,[int]$Round,[bool]$Success,[int]$Number=1){[pscustomobject]@{ProfileId=$Profile;ProfileNumber=$Number;Profile=$Profile;Target=$Target;Round=$Round;Success=$Success;Healthy=$Success}}
    }
    It 'never recommends the no-profile baseline as a runnable strategy' {
        $rows=@((New-Check '__baseline__' a 1 $true),(New-Check real a 1 $true))
        $ranking=@(Get-TpmBenchmarkRanking $rows)
        $ranking.Count|Should -Be 1
        $ranking[0].ProfileId|Should -Be real
    }
    It 'distinguishes stability from a single successful response' {
        $rows=@((New-Check a one 1 $true),(New-Check a one 2 $false),(New-Check a two 1 $true),(New-Check a two 2 $true))
        $result=@(Get-TpmBenchmarkRanking $rows)[0]
        $result.Score|Should -Be 75
        $result.Stable|Should -Be 1
        $result.RepeatedTargets|Should -Be 2
        (@(Get-TpmBenchmarkRanking @((New-Check b one 1 $true)))[0]).RepeatedTargets|Should -Be 0
    }
    It 'ranks reliable responses ahead of reachable server errors at equal reachability' {
        $a=New-Check a one 1 $true 1;$a.Healthy=$false
        $b=New-Check b one 1 $true 2
        (@(Get-TpmBenchmarkRanking @($a,$b))[0]).ProfileId|Should -Be b
    }
    It 'supports CSV string booleans without counting False as success' {
        $rows=@([pscustomobject]@{ProfileId='a';ProfileNumber='1';Profile='A';Target='one';Round='1';Success='False';Healthy='False'})
        (@(Get-TpmBenchmarkRanking $rows)[0]).Score|Should -Be 0
    }
    It 'rejects malformed text settings and excessive retries' {
        $path=Join-Path $TestDrive 'benchmark.json'
        [IO.File]::WriteAllText($path,'{"schemaVersion":1,"fullRounds":99}')
        {Get-TpmBenchmarkSettings $path full}|Should -Throw '*fullRounds*'
        [IO.File]::WriteAllText($path,'{"schemaVersion":1,"baseline":"false"}')
        {Get-TpmBenchmarkSettings $path quick}|Should -Throw '*boolean*'
    }
    It 'labels errors by observed stage without claiming a DPI cause' {
        Get-TpmBenchmarkFailureKind 6 '000'|Should -Be DNS
        Get-TpmBenchmarkFailureKind 60 '000'|Should -Be TLS
        Get-TpmBenchmarkFailureKind 28 '000'|Should -Be timeout
        Get-TpmBenchmarkFailureKind 0 '503'|Should -Be 'HTTP 5xx'
    }
}
