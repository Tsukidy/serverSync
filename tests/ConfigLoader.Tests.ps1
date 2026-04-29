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

    Context 'Test-ServerSyncConfig - shape and value hardening' {
        It 'rejects a destination containing parent traversal' {
            $config = Read-ServerSyncConfig -Path (Join-Path $script:FixturesDir 'config-valid-minimal.json')
            $config.folder_pairs[0].destination = 'D:\Backups\..\..\Windows'
            $result = Test-ServerSyncConfig -Config $config
            $result.Valid | Should -Be $false
            ($result.Errors -join ' ') | Should -Match 'parent-traversal'
        }

        It 'rejects a destination containing wildcards' {
            $config = Read-ServerSyncConfig -Path (Join-Path $script:FixturesDir 'config-valid-minimal.json')
            $config.folder_pairs[0].destination = 'D:\Backups\*'
            $result = Test-ServerSyncConfig -Config $config
            $result.Valid | Should -Be $false
            ($result.Errors -join ' ') | Should -Match 'wildcard'
        }

        It 'rejects a destination that is not an absolute drive-letter path' {
            $config = Read-ServerSyncConfig -Path (Join-Path $script:FixturesDir 'config-valid-minimal.json')
            $config.folder_pairs[0].destination = '\\remote\share\dest'
            $result = Test-ServerSyncConfig -Config $config
            $result.Valid | Should -Be $false
            ($result.Errors -join ' ') | Should -Match 'drive-letter'
        }

        It 'rejects a credential_target with shell-special characters' {
            $config = Read-ServerSyncConfig -Path (Join-Path $script:FixturesDir 'config-valid-minimal.json')
            $config.folder_pairs[0].credential_target = "evil`"; calc"
            $result = Test-ServerSyncConfig -Config $config
            $result.Valid | Should -Be $false
            ($result.Errors -join ' ') | Should -Match 'credential_target'
        }

        It 'rejects a tag with shell-special characters' {
            $config = Read-ServerSyncConfig -Path (Join-Path $script:FixturesDir 'config-valid-minimal.json')
            $config.folder_pairs[0] | Add-Member -MemberType NoteProperty -Name 'tags' -Value @('default; calc') -Force
            $result = Test-ServerSyncConfig -Config $config
            $result.Valid | Should -Be $false
            ($result.Errors -join ' ') | Should -Match 'tag.*invalid characters'
        }

        It 'rejects retention.count = 0 (falsy short-circuit was a bug)' {
            $config = Read-ServerSyncConfig -Path (Join-Path $script:FixturesDir 'config-valid-minimal.json')
            $config.folder_pairs[0] | Add-Member -MemberType NoteProperty -Name 'retention' `
                -Value ([PSCustomObject]@{ mode='files'; count=0; extensions=@('.TIB') }) -Force
            $result = Test-ServerSyncConfig -Config $config
            $result.Valid | Should -Be $false
            ($result.Errors -join ' ') | Should -Match 'retention.count'
        }

        It 'rejects retention.extensions with bogus values' {
            $config = Read-ServerSyncConfig -Path (Join-Path $script:FixturesDir 'config-valid-minimal.json')
            $config.folder_pairs[0] | Add-Member -MemberType NoteProperty -Name 'retention' `
                -Value ([PSCustomObject]@{ mode='files'; count=3; extensions=@('.TIB','. evil') }) -Force
            $result = Test-ServerSyncConfig -Config $config
            $result.Valid | Should -Be $false
            ($result.Errors -join ' ') | Should -Match 'retention.extensions'
        }

        It 'rejects nics declared as a bare string instead of an array' {
            $config = Read-ServerSyncConfig -Path (Join-Path $script:FixturesDir 'config-valid-minimal.json')
            $config.network.nics = 'Ethernet'   # bare string, not array
            $result = Test-ServerSyncConfig -Config $config
            $result.Valid | Should -Be $false
            ($result.Errors -join ' ') | Should -Match 'nics must be an array'
        }

        It 'rejects email.to that is not a non-empty array of valid addresses when enabled' {
            $config = Read-ServerSyncConfig -Path (Join-Path $script:FixturesDir 'config-valid-minimal.json')
            $config.email.enabled = $true
            $config.email.smtp_server = 'mail.example.com'
            $config.email.to = @('not-an-email')
            $result = Test-ServerSyncConfig -Config $config
            $result.Valid | Should -Be $false
            ($result.Errors -join ' ') | Should -Match 'email.to.*invalid address'
        }

        It 'rejects garbage send_on even when email.enabled is false' {
            $config = Read-ServerSyncConfig -Path (Join-Path $script:FixturesDir 'config-valid-minimal.json')
            $config.email.send_on = 'whenever'
            $result = Test-ServerSyncConfig -Config $config
            $result.Valid | Should -Be $false
            ($result.Errors -join ' ') | Should -Match 'send_on'
        }

        It 'requires retention.default_mode' {
            $config = Read-ServerSyncConfig -Path (Join-Path $script:FixturesDir 'config-valid-minimal.json')
            $config.retention.PSObject.Properties.Remove('default_mode')
            $result = Test-ServerSyncConfig -Config $config
            $result.Valid | Should -Be $false
            ($result.Errors -join ' ') | Should -Match 'default_mode'
        }
    }
}
# SIG # Begin signature block
# MIIb+wYJKoZIhvcNAQcCoIIb7DCCG+gCAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQUKLbamkArm5pik3nSnFmEnXXy
# GfagghZeMIIDIDCCAgigAwIBAgIQLo8iz9yyer1NP2dUhiQqSDANBgkqhkiG9w0B
# AQsFADAoMSYwJAYDVQQDDB1EeWxhbiBQb3dlclNoZWxsIENvZGUgU2lnbmluZzAe
# Fw0yNjA0MjkxNTQ4NDlaFw0zMTA0MjkxNTU4NDlaMCgxJjAkBgNVBAMMHUR5bGFu
# IFBvd2VyU2hlbGwgQ29kZSBTaWduaW5nMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8A
# MIIBCgKCAQEA187btBBaXCyufe8zEYV/KrqJtV0ZJBJ6gxK/WHN51TUL6TRgFRyR
# uIsO/trCaIneAmgFr8YwxxJoRiMDYQod0sV9HtGvgggGcb/46ZCUq5USefFXLc+T
# D2mwYR5qIxovBTOOM+/YkKvS5AWa0f8QDndEgrUAhMk80OxurUNhxgRTevQ+aS+v
# e2J9Qms0QtvzADQWznixqqDGQvCNe36ZxsCfshlJ8LMtSdDsKnxPzOKF9lfEZxGh
# CN73z3jD+Mx8EGL3bwmSj1pGIga6IRF5Youb9P1uulc2S7oxZobcjGHG0/W3aInB
# MR7OSSoFbnqbcMSmTmqjKLkBKXLhWfy56QIDAQABo0YwRDAOBgNVHQ8BAf8EBAMC
# B4AwEwYDVR0lBAwwCgYIKwYBBQUHAwMwHQYDVR0OBBYEFAwu+b0hH5HVWlmafHj2
# 9akN2UJEMA0GCSqGSIb3DQEBCwUAA4IBAQBKZFg3pWpgLWeEMzhl4AcySBKbJNQW
# hoLwj58Mmaen7GQQd3q5pmrFtQmxpyF//tnYQ+Mdxr1YXtHoCxkNbPRKXg+Y7DM7
# xlr9sE/aUHTfY4WMbSD9iLxo0lv9EfKDa+0yGlwL24KUqqXwN1vaDk6JL/+6LX5z
# ln9LTEjgqQ7enUNKIcQlcuoPXYG7nUQlfOMG9BLpMMzYGaJJ2bKF35yK5Tho6O7a
# H0nC0sQ25NF/N4wxHF6qknb3Fn16mRfYZmOA3Qj3xI0SUZKAHcBVMN1cNAV6n+Hx
# AYDS1bcNrwM0hjSFPGkRUcJNPINYS/Y+wPNoTAf4I6sBlC3BJhkbkWQqMIIFjTCC
# BHWgAwIBAgIQDpsYjvnQLefv21DiCEAYWjANBgkqhkiG9w0BAQwFADBlMQswCQYD
# VQQGEwJVUzEVMBMGA1UEChMMRGlnaUNlcnQgSW5jMRkwFwYDVQQLExB3d3cuZGln
# aWNlcnQuY29tMSQwIgYDVQQDExtEaWdpQ2VydCBBc3N1cmVkIElEIFJvb3QgQ0Ew
# HhcNMjIwODAxMDAwMDAwWhcNMzExMTA5MjM1OTU5WjBiMQswCQYDVQQGEwJVUzEV
# MBMGA1UEChMMRGlnaUNlcnQgSW5jMRkwFwYDVQQLExB3d3cuZGlnaWNlcnQuY29t
# MSEwHwYDVQQDExhEaWdpQ2VydCBUcnVzdGVkIFJvb3QgRzQwggIiMA0GCSqGSIb3
# DQEBAQUAA4ICDwAwggIKAoICAQC/5pBzaN675F1KPDAiMGkz7MKnJS7JIT3yithZ
# wuEppz1Yq3aaza57G4QNxDAf8xukOBbrVsaXbR2rsnnyyhHS5F/WBTxSD1Ifxp4V
# pX6+n6lXFllVcq9ok3DCsrp1mWpzMpTREEQQLt+C8weE5nQ7bXHiLQwb7iDVySAd
# YyktzuxeTsiT+CFhmzTrBcZe7FsavOvJz82sNEBfsXpm7nfISKhmV1efVFiODCu3
# T6cw2Vbuyntd463JT17lNecxy9qTXtyOj4DatpGYQJB5w3jHtrHEtWoYOAMQjdjU
# N6QuBX2I9YI+EJFwq1WCQTLX2wRzKm6RAXwhTNS8rhsDdV14Ztk6MUSaM0C/CNda
# SaTC5qmgZ92kJ7yhTzm1EVgX9yRcRo9k98FpiHaYdj1ZXUJ2h4mXaXpI8OCiEhtm
# mnTK3kse5w5jrubU75KSOp493ADkRSWJtppEGSt+wJS00mFt6zPZxd9LBADMfRyV
# w4/3IbKyEbe7f/LVjHAsQWCqsWMYRJUadmJ+9oCw++hkpjPRiQfhvbfmQ6QYuKZ3
# AeEPlAwhHbJUKSWJbOUOUlFHdL4mrLZBdd56rF+NP8m800ERElvlEFDrMcXKchYi
# Cd98THU/Y+whX8QgUWtvsauGi0/C1kVfnSD8oR7FwI+isX4KJpn15GkvmB0t9dmp
# sh3lGwIDAQABo4IBOjCCATYwDwYDVR0TAQH/BAUwAwEB/zAdBgNVHQ4EFgQU7Nfj
# gtJxXWRM3y5nP+e6mK4cD08wHwYDVR0jBBgwFoAUReuir/SSy4IxLVGLp6chnfNt
# yA8wDgYDVR0PAQH/BAQDAgGGMHkGCCsGAQUFBwEBBG0wazAkBggrBgEFBQcwAYYY
# aHR0cDovL29jc3AuZGlnaWNlcnQuY29tMEMGCCsGAQUFBzAChjdodHRwOi8vY2Fj
# ZXJ0cy5kaWdpY2VydC5jb20vRGlnaUNlcnRBc3N1cmVkSURSb290Q0EuY3J0MEUG
# A1UdHwQ+MDwwOqA4oDaGNGh0dHA6Ly9jcmwzLmRpZ2ljZXJ0LmNvbS9EaWdpQ2Vy
# dEFzc3VyZWRJRFJvb3RDQS5jcmwwEQYDVR0gBAowCDAGBgRVHSAAMA0GCSqGSIb3
# DQEBDAUAA4IBAQBwoL9DXFXnOF+go3QbPbYW1/e/Vwe9mqyhhyzshV6pGrsi+Ica
# aVQi7aSId229GhT0E0p6Ly23OO/0/4C5+KH38nLeJLxSA8hO0Cre+i1Wz/n096ww
# epqLsl7Uz9FDRJtDIeuWcqFItJnLnU+nBgMTdydE1Od/6Fmo8L8vC6bp8jQ87PcD
# x4eo0kxAGTVGamlUsLihVo7spNU96LHc/RzY9HdaXFSMb++hUD38dglohJ9vytsg
# jTVgHAIDyyCwrFigDkBjxZgiwbJZ9VVrzyerbHbObyMt9H5xaiNrIv8SuFQtJ37Y
# OtnwtoeW/VvRXKwYw02fc7cBqZ9Xql4o4rmUMIIGtDCCBJygAwIBAgIQDcesVwX/
# IZkuQEMiDDpJhjANBgkqhkiG9w0BAQsFADBiMQswCQYDVQQGEwJVUzEVMBMGA1UE
# ChMMRGlnaUNlcnQgSW5jMRkwFwYDVQQLExB3d3cuZGlnaWNlcnQuY29tMSEwHwYD
# VQQDExhEaWdpQ2VydCBUcnVzdGVkIFJvb3QgRzQwHhcNMjUwNTA3MDAwMDAwWhcN
# MzgwMTE0MjM1OTU5WjBpMQswCQYDVQQGEwJVUzEXMBUGA1UEChMORGlnaUNlcnQs
# IEluYy4xQTA/BgNVBAMTOERpZ2lDZXJ0IFRydXN0ZWQgRzQgVGltZVN0YW1waW5n
# IFJTQTQwOTYgU0hBMjU2IDIwMjUgQ0ExMIICIjANBgkqhkiG9w0BAQEFAAOCAg8A
# MIICCgKCAgEAtHgx0wqYQXK+PEbAHKx126NGaHS0URedTa2NDZS1mZaDLFTtQ2oR
# jzUXMmxCqvkbsDpz4aH+qbxeLho8I6jY3xL1IusLopuW2qftJYJaDNs1+JH7Z+Qd
# SKWM06qchUP+AbdJgMQB3h2DZ0Mal5kYp77jYMVQXSZH++0trj6Ao+xh/AS7sQRu
# QL37QXbDhAktVJMQbzIBHYJBYgzWIjk8eDrYhXDEpKk7RdoX0M980EpLtlrNyHw0
# Xm+nt5pnYJU3Gmq6bNMI1I7Gb5IBZK4ivbVCiZv7PNBYqHEpNVWC2ZQ8BbfnFRQV
# ESYOszFI2Wv82wnJRfN20VRS3hpLgIR4hjzL0hpoYGk81coWJ+KdPvMvaB0WkE/2
# qHxJ0ucS638ZxqU14lDnki7CcoKCz6eum5A19WZQHkqUJfdkDjHkccpL6uoG8pbF
# 0LJAQQZxst7VvwDDjAmSFTUms+wV/FbWBqi7fTJnjq3hj0XbQcd8hjj/q8d6ylgx
# CZSKi17yVp2NL+cnT6Toy+rN+nM8M7LnLqCrO2JP3oW//1sfuZDKiDEb1AQ8es9X
# r/u6bDTnYCTKIsDq1BtmXUqEG1NqzJKS4kOmxkYp2WyODi7vQTCBZtVFJfVZ3j7O
# gWmnhFr4yUozZtqgPrHRVHhGNKlYzyjlroPxul+bgIspzOwbtmsgY1MCAwEAAaOC
# AV0wggFZMBIGA1UdEwEB/wQIMAYBAf8CAQAwHQYDVR0OBBYEFO9vU0rp5AZ8esri
# kFb2L9RJ7MtOMB8GA1UdIwQYMBaAFOzX44LScV1kTN8uZz/nupiuHA9PMA4GA1Ud
# DwEB/wQEAwIBhjATBgNVHSUEDDAKBggrBgEFBQcDCDB3BggrBgEFBQcBAQRrMGkw
# JAYIKwYBBQUHMAGGGGh0dHA6Ly9vY3NwLmRpZ2ljZXJ0LmNvbTBBBggrBgEFBQcw
# AoY1aHR0cDovL2NhY2VydHMuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0VHJ1c3RlZFJv
# b3RHNC5jcnQwQwYDVR0fBDwwOjA4oDagNIYyaHR0cDovL2NybDMuZGlnaWNlcnQu
# Y29tL0RpZ2lDZXJ0VHJ1c3RlZFJvb3RHNC5jcmwwIAYDVR0gBBkwFzAIBgZngQwB
# BAIwCwYJYIZIAYb9bAcBMA0GCSqGSIb3DQEBCwUAA4ICAQAXzvsWgBz+Bz0RdnEw
# vb4LyLU0pn/N0IfFiBowf0/Dm1wGc/Do7oVMY2mhXZXjDNJQa8j00DNqhCT3t+s8
# G0iP5kvN2n7Jd2E4/iEIUBO41P5F448rSYJ59Ib61eoalhnd6ywFLerycvZTAz40
# y8S4F3/a+Z1jEMK/DMm/axFSgoR8n6c3nuZB9BfBwAQYK9FHaoq2e26MHvVY9gCD
# A/JYsq7pGdogP8HRtrYfctSLANEBfHU16r3J05qX3kId+ZOczgj5kjatVB+NdADV
# ZKON/gnZruMvNYY2o1f4MXRJDMdTSlOLh0HCn2cQLwQCqjFbqrXuvTPSegOOzr4E
# Wj7PtspIHBldNE2K9i697cvaiIo2p61Ed2p8xMJb82Yosn0z4y25xUbI7GIN/TpV
# fHIqQ6Ku/qjTY6hc3hsXMrS+U0yy+GWqAXam4ToWd2UQ1KYT70kZjE4YtL8Pbzg0
# c1ugMZyZZd/BdHLiRu7hAWE6bTEm4XYRkA6Tl4KSFLFk43esaUeqGkH/wyW4N7Oi
# gizwJWeukcyIPbAvjSabnf7+Pu0VrFgoiovRDiyx3zEdmcif/sYQsfch28bZeUz2
# rtY/9TCA6TD8dC3JE3rYkrhLULy7Dc90G6e8BlqmyIjlgp2+VqsS9/wQD7yFylIz
# 0scmbKvFoW2jNrbM1pD2T7m3XDCCBu0wggTVoAMCAQICEAqA7xhLjfEFgtHEdqeV
# dGgwDQYJKoZIhvcNAQELBQAwaTELMAkGA1UEBhMCVVMxFzAVBgNVBAoTDkRpZ2lD
# ZXJ0LCBJbmMuMUEwPwYDVQQDEzhEaWdpQ2VydCBUcnVzdGVkIEc0IFRpbWVTdGFt
# cGluZyBSU0E0MDk2IFNIQTI1NiAyMDI1IENBMTAeFw0yNTA2MDQwMDAwMDBaFw0z
# NjA5MDMyMzU5NTlaMGMxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdpQ2VydCwg
# SW5jLjE7MDkGA1UEAxMyRGlnaUNlcnQgU0hBMjU2IFJTQTQwOTYgVGltZXN0YW1w
# IFJlc3BvbmRlciAyMDI1IDEwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoIC
# AQDQRqwtEsae0OquYFazK1e6b1H/hnAKAd/KN8wZQjBjMqiZ3xTWcfsLwOvRxUwX
# cGx8AUjni6bz52fGTfr6PHRNv6T7zsf1Y/E3IU8kgNkeECqVQ+3bzWYesFtkepEr
# vUSbf+EIYLkrLKd6qJnuzK8Vcn0DvbDMemQFoxQ2Dsw4vEjoT1FpS54dNApZfKY6
# 1HAldytxNM89PZXUP/5wWWURK+IfxiOg8W9lKMqzdIo7VA1R0V3Zp3DjjANwqAf4
# lEkTlCDQ0/fKJLKLkzGBTpx6EYevvOi7XOc4zyh1uSqgr6UnbksIcFJqLbkIXIPb
# cNmA98Oskkkrvt6lPAw/p4oDSRZreiwB7x9ykrjS6GS3NR39iTTFS+ENTqW8m6TH
# uOmHHjQNC3zbJ6nJ6SXiLSvw4Smz8U07hqF+8CTXaETkVWz0dVVZw7knh1WZXOLH
# gDvundrAtuvz0D3T+dYaNcwafsVCGZKUhQPL1naFKBy1p6llN3QgshRta6Eq4B40
# h5avMcpi54wm0i2ePZD5pPIssoszQyF4//3DoK2O65Uck5Wggn8O2klETsJ7u8xE
# ehGifgJYi+6I03UuT1j7FnrqVrOzaQoVJOeeStPeldYRNMmSF3voIgMFtNGh86w3
# ISHNm0IaadCKCkUe2LnwJKa8TIlwCUNVwppwn4D3/Pt5pwIDAQABo4IBlTCCAZEw
# DAYDVR0TAQH/BAIwADAdBgNVHQ4EFgQU5Dv88jHt/f3X85FxYxlQQ89hjOgwHwYD
# VR0jBBgwFoAU729TSunkBnx6yuKQVvYv1Ensy04wDgYDVR0PAQH/BAQDAgeAMBYG
# A1UdJQEB/wQMMAoGCCsGAQUFBwMIMIGVBggrBgEFBQcBAQSBiDCBhTAkBggrBgEF
# BQcwAYYYaHR0cDovL29jc3AuZGlnaWNlcnQuY29tMF0GCCsGAQUFBzAChlFodHRw
# Oi8vY2FjZXJ0cy5kaWdpY2VydC5jb20vRGlnaUNlcnRUcnVzdGVkRzRUaW1lU3Rh
# bXBpbmdSU0E0MDk2U0hBMjU2MjAyNUNBMS5jcnQwXwYDVR0fBFgwVjBUoFKgUIZO
# aHR0cDovL2NybDMuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0VHJ1c3RlZEc0VGltZVN0
# YW1waW5nUlNBNDA5NlNIQTI1NjIwMjVDQTEuY3JsMCAGA1UdIAQZMBcwCAYGZ4EM
# AQQCMAsGCWCGSAGG/WwHATANBgkqhkiG9w0BAQsFAAOCAgEAZSqt8RwnBLmuYEHs
# 0QhEnmNAciH45PYiT9s1i6UKtW+FERp8FgXRGQ/YAavXzWjZhY+hIfP2JkQ38U+w
# tJPBVBajYfrbIYG+Dui4I4PCvHpQuPqFgqp1PzC/ZRX4pvP/ciZmUnthfAEP1HSh
# TrY+2DE5qjzvZs7JIIgt0GCFD9ktx0LxxtRQ7vllKluHWiKk6FxRPyUPxAAYH2Vy
# 1lNM4kzekd8oEARzFAWgeW3az2xejEWLNN4eKGxDJ8WDl/FQUSntbjZ80FU3i54t
# px5F/0Kr15zW/mJAxZMVBrTE2oi0fcI8VMbtoRAmaaslNXdCG1+lqvP4FbrQ6IwS
# BXkZagHLhFU9HCrG/syTRLLhAezu/3Lr00GrJzPQFnCEH1Y58678IgmfORBPC1JK
# kYaEt2OdDh4GmO0/5cHelAK2/gTlQJINqDr6JfwyYHXSd+V08X1JUPvB4ILfJdmL
# +66Gp3CSBXG6IwXMZUXBhtCyIaehr0XkBoDIGMUG1dUtwq1qmcwbdUfcSYCn+Own
# cVUXf53VJUNOaMWMts0VlRYxe5nK+At+DI96HAlXHAL5SlfYxJ7La54i71McVWRP
# 66bW+yERNpbJCjyCYG2j+bdpxo/1Cy4uPcU3AWVPGrbn5PhDBf3Froguzzhk++am
# i+r3Qrx5bIbY3TVzgiFI7Gq3zWcxggUHMIIFAwIBATA8MCgxJjAkBgNVBAMMHUR5
# bGFuIFBvd2VyU2hlbGwgQ29kZSBTaWduaW5nAhAujyLP3LJ6vU0/Z1SGJCpIMAkG
# BSsOAwIaBQCgeDAYBgorBgEEAYI3AgEMMQowCKACgAChAoAAMBkGCSqGSIb3DQEJ
# AzEMBgorBgEEAYI3AgEEMBwGCisGAQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMCMG
# CSqGSIb3DQEJBDEWBBToahS0b7OmI3hPnWQ6xR1oGfBViTANBgkqhkiG9w0BAQEF
# AASCAQAwSCyiwIOjkUf3HVAjhk5lxiP4F8OVCLoPQ+QoweIc556IMN38Z8fX9spg
# keu7dXY0MgLu4UhyHnEJnTLA3jTtqQPY7mVlQIqche6dPOmCmd0WANSmkutBIFrp
# 77jruXmIFlyhfq6WagQuHV5hXvfH0Gq34E8r6x/f7EwLKtrAcUGUrmOJV/tMVKBI
# WX04HPfS41MwKOi1i3k1PDsgqFvDLSD0wSvDNOda93FLeiPFy7e6RaAwwVo9qWwl
# WFsTS/L/XBVgxfisBH3MBH65VlmtZJxGnWAmu87MOLAOvED1vC0kk97g3KSc4CcP
# UsdNTC2zmbfPIiCsqDGfUSMExRKOoYIDJjCCAyIGCSqGSIb3DQEJBjGCAxMwggMP
# AgEBMH0waTELMAkGA1UEBhMCVVMxFzAVBgNVBAoTDkRpZ2lDZXJ0LCBJbmMuMUEw
# PwYDVQQDEzhEaWdpQ2VydCBUcnVzdGVkIEc0IFRpbWVTdGFtcGluZyBSU0E0MDk2
# IFNIQTI1NiAyMDI1IENBMQIQCoDvGEuN8QWC0cR2p5V0aDANBglghkgBZQMEAgEF
# AKBpMBgGCSqGSIb3DQEJAzELBgkqhkiG9w0BBwEwHAYJKoZIhvcNAQkFMQ8XDTI2
# MDQyOTE3MTcxMFowLwYJKoZIhvcNAQkEMSIEIKrKETROv1S7Dp8iDG6zBla8vQo8
# SZOvRY2NWKJygStvMA0GCSqGSIb3DQEBAQUABIICAArHz6PXevoUP5WLlFui1V3U
# KMfIMTg++gLSy9tOpB8VjP2PDEUK+7QH+UiYb980xw7aoLhX3DDwYUtIImCmb4fA
# BGHJ0khbwC1UiFFh7ZKmpemlK7Ljwn6O4QJlDCTwMYYgZOVdHvuSMEYfBxFaTzxt
# FvKIxrCrYbnnyDUdzkj4+vSPJEXzgNgRhc2HaOdAGb/tFNl/CvB1WMzqJMGRgA+m
# im7vnPKD4Gg8h3oQx0ut3GpZig3lNBQIMk5EYKfKcD/E2I39faQnJFCNvTy0jlZh
# 7EfPIwoOa5yeVinBnqoBzhxuCO34DvU3qHhNORvuGnPW66gHzXlDEzbVymsXeJkR
# wWCtQDJlhGLwONhNwh7mjPKJqsUPGzBLMg9cs8YBC6LpZ6+K+EzWg45WspqvSwmV
# YVdbRkSgEaJG96xDJQ/dM7gTMVTnu+i61lQY7pklSBglIkfKe+WwYKsYY5UXpmR7
# ZoOzKfsfBwJ37/q7akRvMHOoSeCGvYkxyQim3zSBL7GaZEvqceVfOaoSP4037I4R
# bhmVxJgClw0TWLlnPCdtHo4Nt/TDbLgzRSlJ3lDUiGRQDAoTXM30+MtwSJgyS5Ii
# GcDBMs8kgjwf+XTRVSDGBjmiyMKXja0mRDp5jLolwmawx/Dm3lTlS/f0vqy0eOcu
# it6ddbzlVI6qY/opXIA8
# SIG # End signature block
