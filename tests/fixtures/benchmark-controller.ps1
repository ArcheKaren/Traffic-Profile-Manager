param([string]$StateRoot,[int]$ReadyDelayMs=0,[switch]$ExitBeforeReady)
$ErrorActionPreference='Stop'
[IO.File]::WriteAllText((Join-Path $StateRoot 'winws2.windows.pid'),[string]$PID)
Start-Sleep -Milliseconds $ReadyDelayMs
if($ExitBeforeReady){exit 0}
[IO.File]::WriteAllText((Join-Path $StateRoot ("mapping-ready-$PID.flag")),'ready')
Start-Sleep -Seconds 60