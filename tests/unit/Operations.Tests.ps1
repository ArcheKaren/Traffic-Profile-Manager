Describe "Operation journal" {
    BeforeAll {
        $projectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        Import-Module (
            Join-Path $projectRoot `
                "modules\TrafficProfileManager.Operations\TrafficProfileManager.Operations.psd1"
        ) -Force
    }

    It "appends structured JSON Lines entries" {
        Write-TpmOperationLog `
            -AppRoot $TestDrive `
            -Component "unit-test" `
            -Operation "restore" `
            -Status "started" `
            -Message "first`nline" `
            -Data @{ archive = "test.zip" }
        Write-TpmOperationLog `
            -AppRoot $TestDrive `
            -Component "unit-test" `
            -Operation "restore" `
            -Status "succeeded"

        $entries = @(
            Get-Content -LiteralPath (Join-Path $TestDrive "logs\operations.jsonl") |
                ForEach-Object { $_ | ConvertFrom-Json }
        )
        $entries.Count | Should -Be 2
        $entries[0].schemaVersion | Should -Be 1
        $entries[0].message | Should -Be "first line"
        $entries[0].data.archive | Should -Be "test.zip"
        $entries[1].status | Should -Be "succeeded"
    }
}
