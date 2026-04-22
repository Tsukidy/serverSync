BeforeAll {
    $script:ModulePath = Join-Path $PSScriptRoot '..' 'src' 'Modules' 'ConfigLoader.ps1'
    $script:FixturesDir = Join-Path $PSScriptRoot 'fixtures'
    . $script:ModulePath
}

Describe 'ConfigLoader' -Tag 'Unit' {
    Context 'Read-ServerSyncConfig with minimal valid file' {
        It 'returns a PSObject with folder_pairs populated' {
            $path = Join-Path $script:FixturesDir 'config-valid-minimal.json'
            $config = Read-ServerSyncConfig -Path $path
            $config | Should -Not -BeNullOrEmpty
            $config.folder_pairs.Count | Should -Be 1
            $config.folder_pairs[0].name | Should -Be 'ServerA'
        }
    }

    Context 'Test-ServerSyncConfig with valid config' {
        It 'returns $true and no errors' {
            $path = Join-Path $script:FixturesDir 'config-valid-minimal.json'
            $config = Read-ServerSyncConfig -Path $path
            $result = Test-ServerSyncConfig -Config $config
            $result.Valid | Should -Be $true
            $result.Errors.Count | Should -Be 0
        }
    }

    Context 'Test-ServerSyncConfig with missing nics' {
        It 'returns $false and a specific error' {
            $path = Join-Path $script:FixturesDir 'config-missing-nics.json'
            $config = Read-ServerSyncConfig -Path $path
            $result = Test-ServerSyncConfig -Config $config
            $result.Valid | Should -Be $false
            ($result.Errors -join ' ') | Should -Match 'network\.nics'
        }
    }

    Context 'Test-ServerSyncConfig with invalid retention mode on a pair' {
        It 'returns $false and names the pair' {
            $path = Join-Path $script:FixturesDir 'config-bad-retention-mode.json'
            $config = Read-ServerSyncConfig -Path $path
            $result = Test-ServerSyncConfig -Config $config
            $result.Valid | Should -Be $false
            ($result.Errors -join ' ') | Should -Match "pair 'A'"
            ($result.Errors -join ' ') | Should -Match 'retention\.mode'
        }
    }
}
