Describe 'Text profile constructor' {
    BeforeAll {
        $projectRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        Import-Module (Join-Path $projectRoot 'modules/TrafficProfileManager.Maintenance/TrafficProfileManager.Maintenance.psd1') -Force
    }
    BeforeEach {
        $root=Join-Path $TestDrive ([Guid]::NewGuid().ToString('N')+" constructor user's path")
        New-Item -ItemType Directory -Path $root|Out-Null
        foreach($dir in @('config','lists','assets')){Copy-Item -LiteralPath (Join-Path $projectRoot $dir) -Destination (Join-Path $root $dir) -Recurse}
        $recipe=[pscustomobject]@{schemaVersion=1;id='my-network';displayName='My network';baseProfile='strategy-wa-pc-pos1';httpProfile='';tlsProfile='strategy-variant-split1';quicProfile='strategy-variant-quic'}
        Mock Invoke-TpmCandidateCheck {} -ModuleName TrafficProfileManager.Maintenance
    }
    It 'combines selected actions while preserving matching, interception and special rules' {
        $profile=New-TpmBuiltProfile $root $recipe
        $base=[IO.File]::ReadAllText((Join-Path $root 'config/profiles/strategy-wa-pc-pos1.json'))|ConvertFrom-Json
        $tls=[IO.File]::ReadAllText((Join-Path $root 'config/profiles/strategy-variant-split1.json'))|ConvertFrom-Json
        ($profile.interception|ConvertTo-Json -Compress)|Should -Be ($base.interception|ConvertTo-Json -Compress)
        (($profile.rules|Where-Object name -eq tls).actions -join '|')|Should -Be (($tls.rules|Where-Object name -eq tls).actions -join '|')
        (($profile.rules|Where-Object name -eq 'discord-tls')|ConvertTo-Json -Compress)|Should -Be (($base.rules|Where-Object name -eq 'discord-tls')|ConvertTo-Json -Compress)
        Test-Path -LiteralPath (Join-Path $root 'config/profiles/my-network.json')|Should -BeFalse
    }
    It 'validates before publishing and never overwrites existing or manually edited profiles' {
        $result=Save-TpmBuiltProfile $root $recipe
        $result.validated|Should -BeTrue
        Should -Invoke Invoke-TpmCandidateCheck -Times 1 -Exactly -ModuleName TrafficProfileManager.Maintenance
        Add-Content -LiteralPath $result.path -Value ' '
        $hash=(Get-FileHash $result.path).Hash
        {Save-TpmBuiltProfile $root $recipe}|Should -Throw '*already exists*'
        (Get-FileHash $result.path).Hash|Should -Be $hash
    }
    It 'publishes nothing if the installed engine rejects the candidate' {
        Mock Invoke-TpmCandidateCheck {throw 'engine rejected'} -ModuleName TrafficProfileManager.Maintenance
        {Save-TpmBuiltProfile $root $recipe}|Should -Throw '*engine rejected*'
        Test-Path -LiteralPath (Join-Path $root 'config/profiles/my-network.json')|Should -BeFalse
        Test-Path -LiteralPath (Join-Path $root 'state/profile-recipes/my-network.json')|Should -BeFalse
    }
    It 'rejects invalid IDs, unknown recipe fields and missing donors' {
        $recipe.id='../escape';{New-TpmBuiltProfile $root $recipe}|Should -Throw
        $recipe.id='valid';$recipe.tlsProfile='missing';{New-TpmBuiltProfile $root $recipe}|Should -Throw '*Invalid source*'
        $recipe.tlsProfile='';$recipe|Add-Member -NotePropertyName execute -NotePropertyValue 'anything'
        {New-TpmBuiltProfile $root $recipe}|Should -Throw '*recipe fields*'
    }
}
