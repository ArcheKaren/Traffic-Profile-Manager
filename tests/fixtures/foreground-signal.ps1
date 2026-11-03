param([int]$TargetPid, [string]$NativeSource, [switch]$CloseWindow)
$ErrorActionPreference = "Stop"
Add-Type -Path $NativeSource
[TpmForegroundConsole]::Signal($TargetPid, [bool]$CloseWindow)
