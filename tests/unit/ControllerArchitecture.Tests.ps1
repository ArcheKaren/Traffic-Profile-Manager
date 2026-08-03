Describe "Controller architecture" {
    BeforeAll {
        $projectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $controllerManifest = Join-Path $projectRoot (
            "modules\TrafficProfileManager.Controller\" +
            "TrafficProfileManager.Controller.psd1"
        )
        Import-Module $controllerManifest -Force
    }

    It "exports one narrow controller entry point" {
        $commands = @(Get-Command -Module TrafficProfileManager.Controller)
        $commands.Count | Should -Be 1
        $commands[0].Name | Should -Be "Invoke-TpmControllerCommand"
    }

    It "keeps zapretctl as a thin entry point without function definitions" {
        $entryPoint = Join-Path $projectRoot "zapretctl.ps1"
        @(Get-Content -LiteralPath $entryPoint).Count | Should -BeLessOrEqual 80
        $tokens = $null
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile(
            $entryPoint,
            [ref]$tokens,
            [ref]$errors
        )
        @($errors).Count | Should -Be 0
        @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst]
        }, $true)).Count | Should -Be 0
    }

    It "keeps each private responsibility component bounded" {
        $privateRoot = Join-Path $projectRoot (
            "modules\TrafficProfileManager.Controller\Private"
        )
        $components = @(Get-ChildItem -LiteralPath $privateRoot -Filter "*.ps1")
        $components.Count | Should -Be 3
        foreach ($component in $components) {
            @(Get-Content -LiteralPath $component.FullName).Count |
                Should -BeLessOrEqual 500
        }
    }

    It "routes help through the public controller API" {
        $output = @(
            Invoke-TpmControllerCommand `
                -AppRoot $projectRoot `
                -Command "help"
        )
        ($output -join [Environment]::NewLine) |
            Should -Match "local traffic profile manager"
    }
}
