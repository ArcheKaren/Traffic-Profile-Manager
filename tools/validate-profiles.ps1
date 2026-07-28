$ErrorActionPreference = "Continue"
$appRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path $appRoot "tools\profile-library.ps1")
$profiles = @(Get-TrafficProfiles $appRoot -IncludeInvalid)
$stateRoot = Join-Path $appRoot "state"
New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
$validationPath = Join-Path $stateRoot "last-validation.txt"

$failed = 0
$results = New-Object "Collections.Generic.List[string]"
if ($profiles.Count -eq 0) {
    Write-Host "No profile files were found." -ForegroundColor Red
    $results.Add("No profile files were found.")
    [IO.File]::WriteAllLines(
        $validationPath,
        $results.ToArray()
    )
    exit 1
}
foreach ($profile in $profiles) {
    if (-not $profile.Valid) {
        Write-Host "[FAIL] $($profile.Id)" -ForegroundColor Red
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
        Write-Host "[OK]   $($profile.Id)$suffix" -ForegroundColor Green
        $results.Add("[OK]   $($profile.Id)$suffix")
    } else {
        Write-Host "[FAIL] $($profile.Id)" -ForegroundColor Red
        $results.Add("[FAIL] $($profile.Id)")
        foreach ($line in $output) { $results.Add("       $line") }
        $failed++
    }
}

Write-Host ""
if ($failed) {
    Write-Host "$failed profile(s) failed validation." -ForegroundColor Red
    $results.Add("$failed profile(s) failed validation.")
    [IO.File]::WriteAllLines($validationPath, $results.ToArray())
    exit 1
}
Write-Host "All profiles passed validation." -ForegroundColor Green
$results.Add("All profiles passed validation.")
[IO.File]::WriteAllLines($validationPath, $results.ToArray())
