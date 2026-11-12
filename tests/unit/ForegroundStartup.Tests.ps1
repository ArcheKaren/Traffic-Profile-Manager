Describe 'Foreground startup failure cleanup' {
    BeforeAll {
        $projectRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        Import-Module (Join-Path $projectRoot 'modules/TrafficProfileManager.Core/TrafficProfileManager.Core.psd1') -Force
    }
    It 'cleans only the owned process and state after a <FailurePoint> failure' -TestCases @(
        @{FailurePoint='start'},@{FailurePoint='pid'},@{FailurePoint='identity'},@{FailurePoint='watcher'}
    ) {
        param($FailurePoint)
        $root=Join-Path $TestDrive ([Guid]::NewGuid().ToString('N')+" user's path")
        $info=New-TpmProcessStartInfo -FilePath (Get-Process -Id $PID).Path -CreateNoWindow -RedirectStandardOutput -RedirectStandardError -ArgumentList @(
            '-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $projectRoot 'tests/fixtures/foreground-startup-failure.ps1'),
            '-ProjectRoot',$projectRoot,'-FixtureRoot',$root,'-FailurePoint',$FailurePoint
        )
        $process=[Diagnostics.Process]::Start($info)
        try {
            $output=$process.StandardOutput.ReadToEndAsync()
            $errors=$process.StandardError.ReadToEndAsync()
            if(-not $process.WaitForExit(30000)){$process.Kill();throw 'Startup failure test timed out.'}
            $process.ExitCode|Should -Be 0 -Because $errors.GetAwaiter().GetResult()
            $result=$output.GetAwaiter().GetResult()|ConvertFrom-Json
            $result.Error|Should -Be ('Injected startup failure: '+$FailurePoint)
            $result.RuntimeStoppedByController|Should -BeTrue
            $result.UnrelatedAlive|Should -BeTrue
            $result.UnrelatedFlagPreserved|Should -BeTrue
            $result.ReadyFlagPresentWhenPidPublished|Should -BeFalse
            $result.PidFilePresent|Should -BeFalse
            $result.IdentityFilePresent|Should -BeFalse
            $result.MappingCalls|Should -BeNullOrEmpty
        } finally {
            if(-not $process.HasExited){$process.Kill();[void]$process.WaitForExit(5000)}
            $process.Dispose()
            foreach($file in @('runtime-owner.json','unrelated-owner.json')){
                $path=Join-Path $root $file
                if(Test-Path -LiteralPath $path){
                    $owner=Get-Content -LiteralPath $path -Raw|ConvertFrom-Json
                    $owned=Get-Process -Id $owner.pid -ErrorAction SilentlyContinue
                    if($owned -and $owned.StartTime.ToUniversalTime().Ticks -eq $owner.ticks){$owned.Kill();[void]$owned.WaitForExit(5000)}
                }
            }
        }
    }
}