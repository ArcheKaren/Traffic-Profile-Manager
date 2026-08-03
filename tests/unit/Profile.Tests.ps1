Describe "Traffic profile validation" {
    BeforeAll {
        $projectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        Import-Module (
            Join-Path $projectRoot `
                "modules\TrafficProfileManager.Profile\TrafficProfileManager.Profile.psd1"
        ) -Force
    }

    It "exports only the profile catalog and validation boundary" {
        $commands = @(
            Get-Command -Module TrafficProfileManager.Profile |
                Select-Object -ExpandProperty Name
        )
        ($commands -join ",") | Should -Be (
            "Get-TrafficProfiles," +
            "Resolve-TrafficProfileDefinition," +
            "Test-TrafficProfileDefinition"
        )
    }

    It "accepts every bundled profile" {
        $profiles = @(Get-TrafficProfiles $projectRoot -IncludeInvalid)
        $profiles.Count | Should -BeGreaterThan 0
        @($profiles | Where-Object { -not $_.Valid }).Count | Should -Be 0
    }

    It "runs JSON Schema validation before semantic checks" {
        $path = Join-Path $projectRoot "config\profiles\strategy-current-default.json"
        $profile = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json
        $profile.name = "schema-valid-but-wrong-file-name"
        $profile | Add-Member -NotePropertyName unexpectedProperty -NotePropertyValue $true
        {
            Test-TrafficProfileDefinition `
                -Profile $profile `
                -AppRoot $projectRoot `
                -ProfilePath $path
        } | Should -Throw "*JSON Schema*unknown property*"
    }

    It "rejects command separators embedded as line breaks" {
        $path = Join-Path $projectRoot "config\profiles\strategy-current-default.json"
        $profile = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json
        $profile.rules[0].actions[0] = "--dpi-desync=fake`r`nwhoami"
        {
            Test-TrafficProfileDefinition `
                -Profile $profile `
                -AppRoot $projectRoot `
                -ProfilePath $path
        } | Should -Throw "*JSON Schema*pattern*"
    }
}
