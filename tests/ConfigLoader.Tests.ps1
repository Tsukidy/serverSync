BeforeAll {
    $script:ModulePath = [IO.Path]::Combine($PSScriptRoot, '..', 'src', 'Modules', 'ConfigLoader.ps1')
    $script:FixturesDir = Join-Path $PSScriptRoot 'fixtures'
    . $script:ModulePath
    # Also load SyncOperations so Test-ServerSyncConfig can validate
    # robocopy.extra_flags against the allowlist defined there.
    . ([IO.Path]::Combine($PSScriptRoot, '..', 'src', 'Modules', 'SyncOperations.ps1'))
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

    Context 'Select-ServerSyncPairs tag filtering' {
        BeforeAll {
            $script:TaggedPairs = @(
                [PSCustomObject]@{ name='A'; tags=@('default','daily') },
                [PSCustomObject]@{ name='B'; tags=@('weekly') },
                [PSCustomObject]@{ name='C'; tags=@() },
                [PSCustomObject]@{ name='D' }  # no tags field at all
            )
        }

        It 'includes only pairs with default tag when no -Tag given' {
            $selected = Select-ServerSyncPairs -Pairs $script:TaggedPairs
            $selected.Count | Should -Be 1
            $selected[0].name | Should -Be 'A'
        }

        It 'matches specific tag' {
            $selected = Select-ServerSyncPairs -Pairs $script:TaggedPairs -Tag 'weekly'
            $selected.Count | Should -Be 1
            $selected[0].name | Should -Be 'B'
        }

        It 'excludes pairs with empty or missing tags always' {
            $selectedD = Select-ServerSyncPairs -Pairs $script:TaggedPairs -Tag 'anything'
            $selectedD.name | Should -Not -Contain 'C'
            $selectedD.name | Should -Not -Contain 'D'
        }
    }

    Context 'Resolve-RetentionPolicy' {
        It 'uses pair retention when fully specified' {
            $defaults = [PSCustomObject]@{ default_mode='files'; default_extensions=@('.TIB'); default_count=3 }
            $pair = [PSCustomObject]@{ retention = [PSCustomObject]@{ mode='folders'; count=7 } }
            $r = Resolve-RetentionPolicy -Pair $pair -Defaults $defaults
            $r.Mode | Should -Be 'folders'
            $r.Count | Should -Be 7
        }

        It 'falls back to defaults when pair omits retention' {
            $defaults = [PSCustomObject]@{ default_mode='files'; default_extensions=@('.TIB'); default_count=3 }
            $pair = [PSCustomObject]@{ name='X' }
            $r = Resolve-RetentionPolicy -Pair $pair -Defaults $defaults
            $r.Mode | Should -Be 'files'
            $r.Extensions | Should -Be @('.TIB')
            $r.Count | Should -Be 3
        }

        It 'merges per-pair count with default extensions in files mode' {
            $defaults = [PSCustomObject]@{ default_mode='files'; default_extensions=@('.TIB'); default_count=3 }
            $pair = [PSCustomObject]@{ retention = [PSCustomObject]@{ count=10 } }
            $r = Resolve-RetentionPolicy -Pair $pair -Defaults $defaults
            $r.Mode | Should -Be 'files'
            $r.Count | Should -Be 10
            $r.Extensions | Should -Be @('.TIB')
        }

        It 'returns mode=mirror when pair specifies mirror mode' {
            $defaults = [PSCustomObject]@{ default_mode='files'; default_extensions=@('.TIB'); default_count=3 }
            $pair = [PSCustomObject]@{ retention = [PSCustomObject]@{ mode='mirror' } }
            $r = Resolve-RetentionPolicy -Pair $pair -Defaults $defaults
            $r.Mode | Should -Be 'mirror'
            # Extensions should be empty in mirror mode (no extension filtering)
            $r.Extensions.Count | Should -Be 0
        }

        It 'inherits mirror mode from defaults' {
            $defaults = [PSCustomObject]@{ default_mode='mirror'; default_extensions=@(); default_count=3 }
            $pair = [PSCustomObject]@{ name='X' }
            $r = Resolve-RetentionPolicy -Pair $pair -Defaults $defaults
            $r.Mode | Should -Be 'mirror'
        }
    }

    Context 'Test-ServerSyncConfig accepts mirror mode' {
        It 'accepts mode=mirror at the pair level' {
            $config = Read-ServerSyncConfig -Path (Join-Path $script:FixturesDir 'config-valid-minimal.json')
            $config.folder_pairs[0] | Add-Member -MemberType NoteProperty -Name 'retention' -Value ([PSCustomObject]@{ mode='mirror' }) -Force
            $config.folder_pairs[0] | Add-Member -MemberType NoteProperty -Name 'tags' -Value @('default') -Force
            $result = Test-ServerSyncConfig -Config $config
            $result.Valid | Should -Be $true
        }

        It 'accepts default_mode=mirror at the top level' {
            $config = Read-ServerSyncConfig -Path (Join-Path $script:FixturesDir 'config-valid-minimal.json')
            $config.retention.default_mode = 'mirror'
            $config.folder_pairs[0] | Add-Member -MemberType NoteProperty -Name 'tags' -Value @('default') -Force
            $result = Test-ServerSyncConfig -Config $config
            $result.Valid | Should -Be $true
        }

        It 'still rejects unknown modes' {
            $config = Read-ServerSyncConfig -Path (Join-Path $script:FixturesDir 'config-valid-minimal.json')
            $config.folder_pairs[0] | Add-Member -MemberType NoteProperty -Name 'retention' -Value ([PSCustomObject]@{ mode='bogus' }) -Force
            $result = Test-ServerSyncConfig -Config $config
            $result.Valid | Should -Be $false
            ($result.Errors -join ' ') | Should -Match 'mirror'
        }
    }

    Context 'Test-ServerSyncConfig validates update section' {
        It 'accepts a valid update section when enabled' {
            $config = Read-ServerSyncConfig -Path (Join-Path $script:FixturesDir 'config-valid-minimal.json')
            $config | Add-Member -MemberType NoteProperty -Name 'update' -Value ([PSCustomObject]@{
                enabled = $true
                repo_url = 'https://github.com/example/serverSync.git'
                branch = 'main'
                install_root = 'C:\Program Files\ServerSync'
                backup_tag_count = 3
            }) -Force
            $result = Test-ServerSyncConfig -Config $config
            $result.Valid | Should -Be $true
        }

        It 'ignores update section when enabled is false' {
            $config = Read-ServerSyncConfig -Path (Join-Path $script:FixturesDir 'config-valid-minimal.json')
            $config | Add-Member -MemberType NoteProperty -Name 'update' -Value ([PSCustomObject]@{
                enabled = $false
                repo_url = ''
                branch = ''
                install_root = ''
            }) -Force
            $result = Test-ServerSyncConfig -Config $config
            $result.Valid | Should -Be $true
        }

        It 'rejects empty repo_url when enabled' {
            $config = Read-ServerSyncConfig -Path (Join-Path $script:FixturesDir 'config-valid-minimal.json')
            $config | Add-Member -MemberType NoteProperty -Name 'update' -Value ([PSCustomObject]@{
                enabled = $true
                repo_url = ''
                branch = 'main'
                install_root = 'C:\path'
            }) -Force
            $result = Test-ServerSyncConfig -Config $config
            $result.Valid | Should -Be $false
            ($result.Errors -join ' ') | Should -Match 'repo_url'
        }

        It 'rejects malformed repo_url' {
            $config = Read-ServerSyncConfig -Path (Join-Path $script:FixturesDir 'config-valid-minimal.json')
            $config | Add-Member -MemberType NoteProperty -Name 'update' -Value ([PSCustomObject]@{
                enabled = $true
                repo_url = 'not-a-url'
                branch = 'main'
                install_root = 'C:\path'
            }) -Force
            $result = Test-ServerSyncConfig -Config $config
            $result.Valid | Should -Be $false
            ($result.Errors -join ' ') | Should -Match 'repo_url'
        }

        It 'rejects whitespace in branch name' {
            $config = Read-ServerSyncConfig -Path (Join-Path $script:FixturesDir 'config-valid-minimal.json')
            $config | Add-Member -MemberType NoteProperty -Name 'update' -Value ([PSCustomObject]@{
                enabled = $true
                repo_url = 'https://github.com/example/repo.git'
                branch = 'main with space'
                install_root = 'C:\path'
            }) -Force
            $result = Test-ServerSyncConfig -Config $config
            $result.Valid | Should -Be $false
            ($result.Errors -join ' ') | Should -Match 'branch'
        }

        It 'accepts repo_url that is in allowed_repos whitelist' {
            $config = Read-ServerSyncConfig -Path (Join-Path $script:FixturesDir 'config-valid-minimal.json')
            $config | Add-Member -MemberType NoteProperty -Name 'update' -Value ([PSCustomObject]@{
                enabled = $true
                repo_url = 'https://github.com/Tsukidy/serverSync.git'
                branch = 'main'
                install_root = 'C:\path'
                allowed_repos = @('https://github.com/Tsukidy/serverSync.git', 'git@github.com:Tsukidy/serverSync.git')
            }) -Force
            $result = Test-ServerSyncConfig -Config $config
            $result.Valid | Should -Be $true
        }

        It 'rejects repo_url not in allowed_repos whitelist' {
            $config = Read-ServerSyncConfig -Path (Join-Path $script:FixturesDir 'config-valid-minimal.json')
            $config | Add-Member -MemberType NoteProperty -Name 'update' -Value ([PSCustomObject]@{
                enabled = $true
                repo_url = 'https://github.com/evil/serverSync.git'
                branch = 'main'
                install_root = 'C:\path'
                allowed_repos = @('https://github.com/Tsukidy/serverSync.git')
            }) -Force
            $result = Test-ServerSyncConfig -Config $config
            $result.Valid | Should -Be $false
            ($result.Errors -join ' ') | Should -Match 'allowed_repos'
        }

        It 'rejects malformed entries in allowed_repos' {
            $config = Read-ServerSyncConfig -Path (Join-Path $script:FixturesDir 'config-valid-minimal.json')
            $config | Add-Member -MemberType NoteProperty -Name 'update' -Value ([PSCustomObject]@{
                enabled = $true
                repo_url = 'https://github.com/Tsukidy/serverSync.git'
                branch = 'main'
                install_root = 'C:\path'
                allowed_repos = @('https://github.com/Tsukidy/serverSync.git', 'not-a-url')
            }) -Force
            $result = Test-ServerSyncConfig -Config $config
            $result.Valid | Should -Be $false
            ($result.Errors -join ' ') | Should -Match 'not-a-url'
        }

        It 'rejects empty allowed_repos array' {
            $config = Read-ServerSyncConfig -Path (Join-Path $script:FixturesDir 'config-valid-minimal.json')
            $config | Add-Member -MemberType NoteProperty -Name 'update' -Value ([PSCustomObject]@{
                enabled = $true
                repo_url = 'https://github.com/Tsukidy/serverSync.git'
                branch = 'main'
                install_root = 'C:\path'
                allowed_repos = @()
            }) -Force
            $result = Test-ServerSyncConfig -Config $config
            $result.Valid | Should -Be $false
            ($result.Errors -join ' ') | Should -Match 'allowed_repos'
        }
    }

    Context 'Test-ServerSyncConfig validates robocopy.extra_flags allowlist' {
        It 'accepts valid extra_flags' {
            $config = Read-ServerSyncConfig -Path (Join-Path $script:FixturesDir 'config-valid-minimal.json')
            $config.robocopy.extra_flags = @('/COMPRESS', '/IPG:50')
            $result = Test-ServerSyncConfig -Config $config
            $result.Valid | Should -Be $true
        }

        It 'rejects /MIR in extra_flags (mirror is opt-in via retention.mode)' {
            $config = Read-ServerSyncConfig -Path (Join-Path $script:FixturesDir 'config-valid-minimal.json')
            $config.robocopy.extra_flags = @('/MIR')
            $result = Test-ServerSyncConfig -Config $config
            $result.Valid | Should -Be $false
            ($result.Errors -join ' ') | Should -Match 'extra_flags.*MIR'
        }

        It 'rejects /LOG path injection attempts' {
            $config = Read-ServerSyncConfig -Path (Join-Path $script:FixturesDir 'config-valid-minimal.json')
            $config.robocopy.extra_flags = @('/LOG:C:\ProgramData\ServerSync\config.json')
            $result = Test-ServerSyncConfig -Config $config
            $result.Valid | Should -Be $false
            ($result.Errors -join ' ') | Should -Match 'extra_flags'
        }

        It 'rejects unknown garbage flags' {
            $config = Read-ServerSyncConfig -Path (Join-Path $script:FixturesDir 'config-valid-minimal.json')
            $config.robocopy.extra_flags = @('/DOOM')
            $result = Test-ServerSyncConfig -Config $config
            $result.Valid | Should -Be $false
            ($result.Errors -join ' ') | Should -Match 'extra_flags'
        }

        It 'allows an empty extra_flags array' {
            $config = Read-ServerSyncConfig -Path (Join-Path $script:FixturesDir 'config-valid-minimal.json')
            $config.robocopy.extra_flags = @()
            $result = Test-ServerSyncConfig -Config $config
            $result.Valid | Should -Be $true
        }
    }
}
