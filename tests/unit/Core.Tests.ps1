Describe "TrafficProfileManager.Core shared helpers" {
    BeforeAll {
        $projectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        Import-Module (
            Join-Path $projectRoot `
                "modules\TrafficProfileManager.Core\TrafficProfileManager.Core.psd1"
        ) -Force
    }

    It "normalizes IDN domains and exact-match markers" {
        $idn = -join ([char[]]@(
            0x005E,
            0x043F,
            0x0440,
            0x0438,
            0x043C,
            0x0435,
            0x0440,
            0x002E,
            0x0440,
            0x0444,
            0x002E
        ))
        ConvertTo-TpmDomain $idn | Should -Be "^xn--e1afmkfd.xn--p1ai"
    }

    It "rejects URL-shaped domain input" {
        { ConvertTo-TpmDomain "https://example.org/path" } | Should -Throw
    }

    It "normalizes IP addresses and validates CIDR bounds" {
        ConvertTo-TpmIpNetwork "2001:0DB8::1/64" | Should -Be "2001:db8::1/64"
        { ConvertTo-TpmIpNetwork "192.0.2.1/33" } | Should -Throw
    }

    It "reports administrator state as a boolean" {
        (Test-TpmIsAdministrator) | Should -BeOfType ([bool])
    }

    It "quotes spaces, embedded quotes, and trailing slashes for Windows" {
        ConvertTo-TpmWindowsArgument "plain" | Should -Be "plain"
        ConvertTo-TpmWindowsArgument "two words" | Should -Be '"two words"'
        ConvertTo-TpmWindowsArgument 'a "b"' | Should -Be '"a \"b\""'
        ConvertTo-TpmWindowsArgument "path with space\" | Should -Be '"path with space\\"'
    }

    It "rejects line breaks and NUL in process arguments" {
        { Test-TpmArgumentVector @("ok", "line`nbreak") } | Should -Throw
        { Test-TpmArgumentVector @("ok", "nul$([char]0)value") } | Should -Throw
    }

    It "loads Windows ACL commands in a Windows PowerShell child without changing its parent environment" {
        $originalModulePath = $env:PSModulePath
        $startInfo = New-TpmProcessStartInfo -FilePath "powershell.exe" -CreateNoWindow `
            -RedirectStandardOutput -RedirectStandardError -ArgumentList @(
                "-NoLogo", "-NoProfile", "-NonInteractive", "-Command",
                'try { Get-Acl -LiteralPath $PSHOME -ErrorAction Stop | Out-Null; [Console]::Out.Write("ACL_OK") } catch { exit 1 }'
            )
        $process = [Diagnostics.Process]::Start($startInfo)
        try {
            $process.WaitForExit(15000) | Should -BeTrue
            $output = $process.StandardOutput.ReadToEnd()
            $process.ExitCode | Should -Be 0
            $output | Should -BeExactly "ACL_OK"
            $env:PSModulePath | Should -BeExactly $originalModulePath
        } finally {
            if (-not $process.HasExited) { $process.Kill() }
            $process.Dispose()
        }
    }

    It "passes shell metacharacters as inert child-process arguments" {
        $values = @(
            "ampersand&whoami",
            "pipe|value",
            "semi;colon",
            '`$(literal)',
            'quote"value',
            "space and trailing slash\"
        )
        $startInfo = New-TpmProcessStartInfo `
            -FilePath "powershell.exe" `
            -ArgumentList (@(
                "-NoLogo",
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                (Join-Path $projectRoot "tests\fixtures\echo-arguments.ps1")
            ) + $values) `
            -CreateNoWindow `
            -RedirectStandardOutput `
            -RedirectStandardError
        $process = [Diagnostics.Process]::Start($startInfo)
        $standardOutput = $process.StandardOutput.ReadToEnd()
        $standardError = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        $standardError | Should -Be ""
        $process.ExitCode | Should -Be 0
        $parsedOutput = $standardOutput | ConvertFrom-Json
        $actualValues = @($parsedOutput)
        $actualValues | Should -HaveCount $values.Count
        for ($index = 0; $index -lt $values.Count; $index++) {
            $actualValues[$index] | Should -BeExactly $values[$index]
        }
    }
}
