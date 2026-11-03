Describe 'Console manager language selection' {
    BeforeAll {
        $projectRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        Import-Module (Join-Path $projectRoot 'modules\TrafficProfileManager.Core\TrafficProfileManager.Core.psd1') -Force
        Import-Module (Join-Path $projectRoot 'modules\TrafficProfileManager.Maintenance\TrafficProfileManager.Maintenance.psd1') -Force
        function New-ConsoleDataFixture([string]$Language='en') {
            $root=Join-Path $TestDrive ([Guid]::NewGuid().ToString('N')+" menu user's path")
            New-Item -ItemType Directory -Path $root|Out-Null
            foreach($directory in @('modules','tools')) { Copy-Item -LiteralPath (Join-Path $projectRoot $directory) -Destination $root -Recurse }
            foreach($directory in @('state','config/game-filters/marathon','lists','assets')) { New-Item -ItemType Directory -Path (Join-Path $root $directory) -Force|Out-Null }
            Copy-Item -LiteralPath (Join-Path $projectRoot 'lists/catalog.json') -Destination (Join-Path $root 'lists/catalog.json')
            Copy-Item -LiteralPath (Join-Path $projectRoot 'lists/packs') -Destination (Join-Path $root 'lists') -Recurse
            Copy-Item -LiteralPath (Join-Path $projectRoot 'assets/ACTIVE_GAME_UDP.bin') -Destination (Join-Path $root 'assets/ACTIVE_GAME_UDP.bin')
            [IO.File]::WriteAllText((Join-Path $root 'state/user-settings.json'),('{"language":"'+$Language+'"}'))
            [IO.File]::WriteAllText((Join-Path $root 'config/config.json'),'{"activeProfile":"custom"}')
            $filter=@{schemaVersion=2;id='marathon';displayName='Marathon sign-in';description='Optional user-provided sign-in mappings. Review the relay address before enabling.';transport=@{mode='off';preset='balanced';tcpPorts='1024-65535';udpPorts='1024-65535';udpFake='assets\ACTIVE_GAME_UDP.bin'}}
            [IO.File]::WriteAllText((Join-Path $root 'config/game-filters/marathon/filter.json'),($filter|ConvertTo-Json -Depth 5))
            foreach($name in @('hosts.txt','domains.txt','ips.txt','domains-exclude.txt','ips-exclude.txt')) { [IO.File]::WriteAllText((Join-Path $root "config/game-filters/marathon/$name"),'# fixture') }
            return $root
        }
        function Invoke-ConsoleFixture([string]$Root,[string[]]$Answers) {
            $info=New-TpmProcessStartInfo -FilePath (Get-Command powershell.exe).Source -ArgumentList @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $Root 'tools\console-manager.ps1')) -CreateNoWindow -RedirectStandardOutput -RedirectStandardError
            $info.RedirectStandardInput=$true
            $info.StandardOutputEncoding=[Text.Encoding]::UTF8
            $process=[Diagnostics.Process]::Start($info)
            try {
                $output=$process.StandardOutput.ReadToEndAsync()
                $errorOutput=$process.StandardError.ReadToEndAsync()
                foreach($answer in $Answers){$process.StandardInput.WriteLine($answer)}
                $process.StandardInput.Close()
                if(-not $process.WaitForExit(20000)){$process.Kill();throw 'Console test timed out.'}
                if($process.ExitCode -ne 0){throw $errorOutput.GetAwaiter().GetResult()}
                return $output.GetAwaiter().GetResult()
            }finally{$process.Dispose()}
        }
    }
    It 'opens the domain pack manager and numbers its entries without array addition errors' {
        $root=New-ConsoleDataFixture
        $output=Invoke-ConsoleFixture $root @('14','0','0')
        $output|Should -Match 'video-platforms'
        $output|Should -Match '(?m)^\[1\] \[ON'
        $output|Should -Not -Match 'op_Addition|Exception|not recognized|Press Enter to continue'
    }
    It 'renders the game filter page in the selected language without changing metadata' -TestCases @(@{Language='en'},@{Language='ru'}) {
        param($Language)
        $root=New-ConsoleDataFixture $Language
        $custom=Join-Path $root 'config/game-filters/nmrih'
        Copy-Item -LiteralPath (Join-Path $root 'config/game-filters/marathon') -Destination $custom -Recurse
        $manifestPath=Join-Path $custom 'filter.json'
        $filter=[IO.File]::ReadAllText($manifestPath)|ConvertFrom-Json
        $filter.id='nmrih';$filter.displayName='NoMoreRoomInHell';$filter.description='Custom game filter.';$filter.transport.mode='all'
        [IO.File]::WriteAllText($manifestPath,($filter|ConvertTo-Json -Depth 5))
        [IO.File]::WriteAllText((Join-Path $custom 'ips.txt'),'198.51.100.42')
        $before=(Get-FileHash $manifestPath).Hash
        $output=Invoke-ConsoleFixture $root @('13','0','0')
        $output|Should -Match 'NoMoreRoomInHell'
        if($Language -eq 'ru') {
            $dictionary=[IO.File]::ReadAllText((Join-Path $root 'modules/TrafficProfileManager.Console/ru.json'))|ConvertFrom-Json
            $output|Should -Match ([regex]::Escape($dictionary.'Custom game filter.'))
            $output|Should -Match ([regex]::Escape($dictionary.'Transport: off'))
            $output|Should -Match ([regex]::Escape($dictionary.balanced))
            $output|Should -Not -Match 'Enabled filters add|Universal transport:|Transport: off|Custom game filter\.|Optional user-provided|balanced'
        } else {
            $output|Should -Match 'Enabled filters add|Universal transport: OFF|Transport: off|Custom game filter\.'
        }
        (Get-FileHash $manifestPath).Hash|Should -Be $before
        $output|Should -Not -Match 'Exception|not recognized'
    }
    It 'cancels an empty archive path without an exception' {
        $root=New-ConsoleDataFixture 'ru'
        $output=Invoke-ConsoleFixture $root @('17','2','','0')
        $output|Should -Not -Match 'GetFullPath|Exception|not recognized'
        Test-Path (Join-Path $root 'backups/transactions')|Should -BeFalse
    }
    It 'accepts a quoted archive path and previews it without restoring' {
        $root=New-ConsoleDataFixture 'ru'
        $backup=New-TpmUserBackup $root
        $output=Invoke-ConsoleFixture $root @('17','2',('"'+$backup.archive+'"'),'cancel','','0')
        $output|Should -Match 'config/config.json'
        $output|Should -Not -Match 'GetFullPath|Exception|not recognized'
        Test-Path (Join-Path $root 'backups/transactions')|Should -BeFalse
    }
    It 'lists existing backups and accepts a backup number' {
        $root=New-ConsoleDataFixture
        $backup=New-TpmUserBackup $root
        $output=Invoke-ConsoleFixture $root @('17','2','1','cancel','','0')
        $output|Should -Match ([regex]::Escape([IO.Path]::GetFileName($backup.archive)))
        $output|Should -Match 'config/config.json'
        $output|Should -Not -Match 'GetFullPath|Exception|not recognized'
        Test-Path (Join-Path $root 'backups/transactions')|Should -BeFalse
    }
    It 'clears the main menu when opening a submenu and returns without an extra pause' {
        $root=Join-Path $TestDrive 'Screen transitions'
        New-Item -ItemType Directory -Path $root|Out-Null
        Copy-Item -LiteralPath (Join-Path $projectRoot 'modules') -Destination $root -Recurse
        Copy-Item -LiteralPath (Join-Path $projectRoot 'tools') -Destination $root -Recurse
        $modulePath=Join-Path $root 'modules\TrafficProfileManager.Console\TrafficProfileManager.Console.psm1'
        $text=[IO.File]::ReadAllText($modulePath)
        $tokens=$null;$errors=$null
        $ast=[Management.Automation.Language.Parser]::ParseInput($text,[ref]$tokens,[ref]$errors)
        $clear=$ast.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Clear-TpmScreen'},$true)
        # Replace only the terminal boundary in the test copy, keeping real navigation.
        $text=$text.Remove($clear.Body.Extent.StartOffset,$clear.Body.Extent.EndOffset-$clear.Body.Extent.StartOffset).Insert($clear.Body.Extent.StartOffset,'{ Write-Host "__SCREEN_CLEAR__" }')
        [IO.File]::WriteAllText($modulePath,$text,[Text.UTF8Encoding]::new($false))
        $output=Invoke-ConsoleFixture $root @('9','0','17','0','18','0','0')
        $screens=$output -split '__SCREEN_CLEAR__'
        $background=@($screens|Where-Object {$_ -match 'Start the installed service now'})
        $background.Count|Should -Be 1
        $background[0]|Should -Not -Match 'Saved comparison results|Test and compare profiles'
        $output|Should -Not -Match 'Press Enter to continue'
        $output|Should -Not -Match 'Exception|not recognized'
    }
    It 'starts in English, changes language through the menu, and remembers the choice' {
        $root=Join-Path $TestDrive "Console user's path"
        New-Item -ItemType Directory -Path $root|Out-Null
        Copy-Item -LiteralPath (Join-Path $projectRoot 'modules') -Destination $root -Recurse
        Copy-Item -LiteralPath (Join-Path $projectRoot 'tools') -Destination $root -Recurse
        $output=Invoke-ConsoleFixture $root @('16','2','','0')
        $output|Should -Match 'Language: en'
        $language=([IO.File]::ReadAllText((Join-Path $root 'state\user-settings.json'))|ConvertFrom-Json).language
        $language|Should -Be 'ru'
        $dictionary=[IO.File]::ReadAllText((Join-Path $root 'modules\TrafficProfileManager.Console\ru.json'))|ConvertFrom-Json
        $output|Should -Match ([regex]::Escape($dictionary.'Show status'))
        $output|Should -Not -Match 'Cannot|Exception|not recognized'
        $again=Invoke-ConsoleFixture $root @('16','1','','0')
        ([IO.File]::ReadAllText((Join-Path $root 'state\user-settings.json'))|ConvertFrom-Json).language|Should -Be 'en'
        $again|Should -Match 'Language: en'
    }
}
