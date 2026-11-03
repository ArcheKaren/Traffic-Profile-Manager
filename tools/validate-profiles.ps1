$ErrorActionPreference = "Stop"
$appRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) "modules\TrafficProfileManager.Console\TrafficProfileManager.Console.psd1") -ErrorAction Stop
Set-TpmUiRoot $appRoot

Import-Module (
    Join-Path $appRoot `
        "modules\TrafficProfileManager.Profile\TrafficProfileManager.Profile.psd1"
) -ErrorAction Stop
$profiles = @(Get-TrafficProfiles $appRoot -IncludeInvalid)
$stateRoot = Join-Path $appRoot "state"
New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
$validationPath = Join-Path $stateRoot "last-validation.txt"

$failed = 0
$results = New-Object "Collections.Generic.List[string]"
if ($profiles.Count -eq 0) {
    Write-TpmUi "No profile files were found." -ForegroundColor Red
    $results.Add("No profile files were found.")
    [IO.File]::WriteAllLines(
        $validationPath,
        $results.ToArray()
    )
    exit 1
}
foreach ($profile in $profiles) {
    if (-not $profile.Valid) {
        Write-TpmUi "[FAIL] $($profile.Id)" -ForegroundColor Red
        $results.Add("[FAIL] $($profile.Id)")
        $results.Add("       $($profile.Error)")
        $failed++
        continue
    }

    $output = @()
    $succeeded = $false
    $attempt = 0
    do {
        $attempt++
        $output = & (Join-Path $appRoot "zapretctl.ps1") check $profile.Id *>&1
        $succeeded = $?
        if (-not $succeeded -and $attempt -lt 3) {
            Start-Sleep -Milliseconds 750
        }
    } while (-not $succeeded -and $attempt -lt 3)

    if ($succeeded) {
        $suffix = if ($attempt -gt 1) { " (attempt $attempt)" } else { "" }
        Write-TpmUi "[OK]   $($profile.Id)$suffix" -ForegroundColor Green
        $results.Add("[OK]   $($profile.Id)$suffix")
    } else {
        Write-TpmUi "[FAIL] $($profile.Id)" -ForegroundColor Red
        $results.Add("[FAIL] $($profile.Id)")
        foreach ($line in $output) { $results.Add("       $line") }
        $failed++
    }
}

Write-TpmUi ""
if ($failed) {
    Write-TpmUi "$failed profile(s) failed validation." -ForegroundColor Red
    $results.Add("$failed profile(s) failed validation.")
    [IO.File]::WriteAllLines($validationPath, $results.ToArray())
    exit 1
}
Write-TpmUi "All profiles passed validation." -ForegroundColor Green
$results.Add("All profiles passed validation.")
[IO.File]::WriteAllLines($validationPath, $results.ToArray())
exit 0
