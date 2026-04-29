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
# MIIcIAYJKoZIhvcNAQcCoIIcETCCHA0CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDiAjgFa+D6G2PS
# 5q7RTzTLA4Xe4lzGlObWWW9Y7A91/6CCFl4wggMgMIICCKADAgECAhAujyLP3LJ6
# vU0/Z1SGJCpIMA0GCSqGSIb3DQEBCwUAMCgxJjAkBgNVBAMMHUR5bGFuIFBvd2Vy
# U2hlbGwgQ29kZSBTaWduaW5nMB4XDTI2MDQyOTE1NDg0OVoXDTMxMDQyOTE1NTg0
# OVowKDEmMCQGA1UEAwwdRHlsYW4gUG93ZXJTaGVsbCBDb2RlIFNpZ25pbmcwggEi
# MA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQDXztu0EFpcLK597zMRhX8quom1
# XRkkEnqDEr9Yc3nVNQvpNGAVHJG4iw7+2sJoid4CaAWvxjDHEmhGIwNhCh3SxX0e
# 0a+CCAZxv/jpkJSrlRJ58Vctz5MPabBhHmojGi8FM44z79iQq9LkBZrR/xAOd0SC
# tQCEyTzQ7G6tQ2HGBFN69D5pL697Yn1CazRC2/MANBbOeLGqoMZC8I17fpnGwJ+y
# GUnwsy1J0OwqfE/M4oX2V8RnEaEI3vfPeMP4zHwQYvdvCZKPWkYiBrohEXlii5v0
# /W66VzZLujFmhtyMYcbT9bdoicExHs5JKgVueptwxKZOaqMouQEpcuFZ/LnpAgMB
# AAGjRjBEMA4GA1UdDwEB/wQEAwIHgDATBgNVHSUEDDAKBggrBgEFBQcDAzAdBgNV
# HQ4EFgQUDC75vSEfkdVaWZp8ePb1qQ3ZQkQwDQYJKoZIhvcNAQELBQADggEBAEpk
# WDelamAtZ4QzOGXgBzJIEpsk1BaGgvCPnwyZp6fsZBB3ermmasW1CbGnIX/+2dhD
# 4x3GvVhe0egLGQ1s9EpeD5jsMzvGWv2wT9pQdN9jhYxtIP2IvGjSW/0R8oNr7TIa
# XAvbgpSqpfA3W9oOTokv/7otfnOWf0tMSOCpDt6dQ0ohxCVy6g9dgbudRCV84wb0
# EukwzNgZoknZsoXfnIrlOGjo7tofScLSxDbk0X83jDEcXqqSdvcWfXqZF9hmY4Dd
# CPfEjRJRkoAdwFUw3Vw0BXqf4fEBgNLVtw2vAzSGNIU8aRFRwk08g1hL9j7A82hM
# B/gjqwGULcEmGRuRZCowggWNMIIEdaADAgECAhAOmxiO+dAt5+/bUOIIQBhaMA0G
# CSqGSIb3DQEBDAUAMGUxCzAJBgNVBAYTAlVTMRUwEwYDVQQKEwxEaWdpQ2VydCBJ
# bmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xJDAiBgNVBAMTG0RpZ2lDZXJ0
# IEFzc3VyZWQgSUQgUm9vdCBDQTAeFw0yMjA4MDEwMDAwMDBaFw0zMTExMDkyMzU5
# NTlaMGIxCzAJBgNVBAYTAlVTMRUwEwYDVQQKEwxEaWdpQ2VydCBJbmMxGTAXBgNV
# BAsTEHd3dy5kaWdpY2VydC5jb20xITAfBgNVBAMTGERpZ2lDZXJ0IFRydXN0ZWQg
# Um9vdCBHNDCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAL/mkHNo3rvk
# XUo8MCIwaTPswqclLskhPfKK2FnC4SmnPVirdprNrnsbhA3EMB/zG6Q4FutWxpdt
# HauyefLKEdLkX9YFPFIPUh/GnhWlfr6fqVcWWVVyr2iTcMKyunWZanMylNEQRBAu
# 34LzB4TmdDttceItDBvuINXJIB1jKS3O7F5OyJP4IWGbNOsFxl7sWxq868nPzaw0
# QF+xembud8hIqGZXV59UWI4MK7dPpzDZVu7Ke13jrclPXuU15zHL2pNe3I6PgNq2
# kZhAkHnDeMe2scS1ahg4AxCN2NQ3pC4FfYj1gj4QkXCrVYJBMtfbBHMqbpEBfCFM
# 1LyuGwN1XXhm2ToxRJozQL8I11pJpMLmqaBn3aQnvKFPObURWBf3JFxGj2T3wWmI
# dph2PVldQnaHiZdpekjw4KISG2aadMreSx7nDmOu5tTvkpI6nj3cAORFJYm2mkQZ
# K37AlLTSYW3rM9nF30sEAMx9HJXDj/chsrIRt7t/8tWMcCxBYKqxYxhElRp2Yn72
# gLD76GSmM9GJB+G9t+ZDpBi4pncB4Q+UDCEdslQpJYls5Q5SUUd0viastkF13nqs
# X40/ybzTQRESW+UQUOsxxcpyFiIJ33xMdT9j7CFfxCBRa2+xq4aLT8LWRV+dIPyh
# HsXAj6KxfgommfXkaS+YHS312amyHeUbAgMBAAGjggE6MIIBNjAPBgNVHRMBAf8E
# BTADAQH/MB0GA1UdDgQWBBTs1+OC0nFdZEzfLmc/57qYrhwPTzAfBgNVHSMEGDAW
# gBRF66Kv9JLLgjEtUYunpyGd823IDzAOBgNVHQ8BAf8EBAMCAYYweQYIKwYBBQUH
# AQEEbTBrMCQGCCsGAQUFBzABhhhodHRwOi8vb2NzcC5kaWdpY2VydC5jb20wQwYI
# KwYBBQUHMAKGN2h0dHA6Ly9jYWNlcnRzLmRpZ2ljZXJ0LmNvbS9EaWdpQ2VydEFz
# c3VyZWRJRFJvb3RDQS5jcnQwRQYDVR0fBD4wPDA6oDigNoY0aHR0cDovL2NybDMu
# ZGlnaWNlcnQuY29tL0RpZ2lDZXJ0QXNzdXJlZElEUm9vdENBLmNybDARBgNVHSAE
# CjAIMAYGBFUdIAAwDQYJKoZIhvcNAQEMBQADggEBAHCgv0NcVec4X6CjdBs9thbX
# 979XB72arKGHLOyFXqkauyL4hxppVCLtpIh3bb0aFPQTSnovLbc47/T/gLn4offy
# ct4kvFIDyE7QKt76LVbP+fT3rDB6mouyXtTP0UNEm0Mh65ZyoUi0mcudT6cGAxN3
# J0TU53/oWajwvy8LpunyNDzs9wPHh6jSTEAZNUZqaVSwuKFWjuyk1T3osdz9HNj0
# d1pcVIxv76FQPfx2CWiEn2/K2yCNNWAcAgPLILCsWKAOQGPFmCLBsln1VWvPJ6ts
# ds5vIy30fnFqI2si/xK4VC0nftg62fC2h5b9W9FcrBjDTZ9ztwGpn1eqXijiuZQw
# gga0MIIEnKADAgECAhANx6xXBf8hmS5AQyIMOkmGMA0GCSqGSIb3DQEBCwUAMGIx
# CzAJBgNVBAYTAlVTMRUwEwYDVQQKEwxEaWdpQ2VydCBJbmMxGTAXBgNVBAsTEHd3
# dy5kaWdpY2VydC5jb20xITAfBgNVBAMTGERpZ2lDZXJ0IFRydXN0ZWQgUm9vdCBH
# NDAeFw0yNTA1MDcwMDAwMDBaFw0zODAxMTQyMzU5NTlaMGkxCzAJBgNVBAYTAlVT
# MRcwFQYDVQQKEw5EaWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1
# c3RlZCBHNCBUaW1lU3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTEwggIi
# MA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQC0eDHTCphBcr48RsAcrHXbo0Zo
# dLRRF51NrY0NlLWZloMsVO1DahGPNRcybEKq+RuwOnPhof6pvF4uGjwjqNjfEvUi
# 6wuim5bap+0lgloM2zX4kftn5B1IpYzTqpyFQ/4Bt0mAxAHeHYNnQxqXmRinvuNg
# xVBdJkf77S2uPoCj7GH8BLuxBG5AvftBdsOECS1UkxBvMgEdgkFiDNYiOTx4OtiF
# cMSkqTtF2hfQz3zQSku2Ws3IfDReb6e3mmdglTcaarps0wjUjsZvkgFkriK9tUKJ
# m/s80FiocSk1VYLZlDwFt+cVFBURJg6zMUjZa/zbCclF83bRVFLeGkuAhHiGPMvS
# GmhgaTzVyhYn4p0+8y9oHRaQT/aofEnS5xLrfxnGpTXiUOeSLsJygoLPp66bkDX1
# ZlAeSpQl92QOMeRxykvq6gbylsXQskBBBnGy3tW/AMOMCZIVNSaz7BX8VtYGqLt9
# MmeOreGPRdtBx3yGOP+rx3rKWDEJlIqLXvJWnY0v5ydPpOjL6s36czwzsucuoKs7
# Yk/ehb//Wx+5kMqIMRvUBDx6z1ev+7psNOdgJMoiwOrUG2ZdSoQbU2rMkpLiQ6bG
# RinZbI4OLu9BMIFm1UUl9VnePs6BaaeEWvjJSjNm2qA+sdFUeEY0qVjPKOWug/G6
# X5uAiynM7Bu2ayBjUwIDAQABo4IBXTCCAVkwEgYDVR0TAQH/BAgwBgEB/wIBADAd
# BgNVHQ4EFgQU729TSunkBnx6yuKQVvYv1Ensy04wHwYDVR0jBBgwFoAU7NfjgtJx
# XWRM3y5nP+e6mK4cD08wDgYDVR0PAQH/BAQDAgGGMBMGA1UdJQQMMAoGCCsGAQUF
# BwMIMHcGCCsGAQUFBwEBBGswaTAkBggrBgEFBQcwAYYYaHR0cDovL29jc3AuZGln
# aWNlcnQuY29tMEEGCCsGAQUFBzAChjVodHRwOi8vY2FjZXJ0cy5kaWdpY2VydC5j
# b20vRGlnaUNlcnRUcnVzdGVkUm9vdEc0LmNydDBDBgNVHR8EPDA6MDigNqA0hjJo
# dHRwOi8vY3JsMy5kaWdpY2VydC5jb20vRGlnaUNlcnRUcnVzdGVkUm9vdEc0LmNy
# bDAgBgNVHSAEGTAXMAgGBmeBDAEEAjALBglghkgBhv1sBwEwDQYJKoZIhvcNAQEL
# BQADggIBABfO+xaAHP4HPRF2cTC9vgvItTSmf83Qh8WIGjB/T8ObXAZz8OjuhUxj
# aaFdleMM0lBryPTQM2qEJPe36zwbSI/mS83afsl3YTj+IQhQE7jU/kXjjytJgnn0
# hvrV6hqWGd3rLAUt6vJy9lMDPjTLxLgXf9r5nWMQwr8Myb9rEVKChHyfpzee5kH0
# F8HABBgr0UdqirZ7bowe9Vj2AIMD8liyrukZ2iA/wdG2th9y1IsA0QF8dTXqvcnT
# mpfeQh35k5zOCPmSNq1UH410ANVko43+Cdmu4y81hjajV/gxdEkMx1NKU4uHQcKf
# ZxAvBAKqMVuqte69M9J6A47OvgRaPs+2ykgcGV00TYr2Lr3ty9qIijanrUR3anzE
# wlvzZiiyfTPjLbnFRsjsYg39OlV8cipDoq7+qNNjqFzeGxcytL5TTLL4ZaoBdqbh
# OhZ3ZRDUphPvSRmMThi0vw9vODRzW6AxnJll38F0cuJG7uEBYTptMSbhdhGQDpOX
# gpIUsWTjd6xpR6oaQf/DJbg3s6KCLPAlZ66RzIg9sC+NJpud/v4+7RWsWCiKi9EO
# LLHfMR2ZyJ/+xhCx9yHbxtl5TPau1j/1MIDpMPx0LckTetiSuEtQvLsNz3Qbp7wG
# WqbIiOWCnb5WqxL3/BAPvIXKUjPSxyZsq8WhbaM2tszWkPZPubdcMIIG7TCCBNWg
# AwIBAgIQCoDvGEuN8QWC0cR2p5V0aDANBgkqhkiG9w0BAQsFADBpMQswCQYDVQQG
# EwJVUzEXMBUGA1UEChMORGlnaUNlcnQsIEluYy4xQTA/BgNVBAMTOERpZ2lDZXJ0
# IFRydXN0ZWQgRzQgVGltZVN0YW1waW5nIFJTQTQwOTYgU0hBMjU2IDIwMjUgQ0Ex
# MB4XDTI1MDYwNDAwMDAwMFoXDTM2MDkwMzIzNTk1OVowYzELMAkGA1UEBhMCVVMx
# FzAVBgNVBAoTDkRpZ2lDZXJ0LCBJbmMuMTswOQYDVQQDEzJEaWdpQ2VydCBTSEEy
# NTYgUlNBNDA5NiBUaW1lc3RhbXAgUmVzcG9uZGVyIDIwMjUgMTCCAiIwDQYJKoZI
# hvcNAQEBBQADggIPADCCAgoCggIBANBGrC0Sxp7Q6q5gVrMrV7pvUf+GcAoB38o3
# zBlCMGMyqJnfFNZx+wvA69HFTBdwbHwBSOeLpvPnZ8ZN+vo8dE2/pPvOx/Vj8Tch
# TySA2R4QKpVD7dvNZh6wW2R6kSu9RJt/4QhguSssp3qome7MrxVyfQO9sMx6ZAWj
# FDYOzDi8SOhPUWlLnh00Cll8pjrUcCV3K3E0zz09ldQ//nBZZREr4h/GI6Dxb2Uo
# yrN0ijtUDVHRXdmncOOMA3CoB/iUSROUINDT98oksouTMYFOnHoRh6+86Ltc5zjP
# KHW5KqCvpSduSwhwUmotuQhcg9tw2YD3w6ySSSu+3qU8DD+nigNJFmt6LAHvH3KS
# uNLoZLc1Hf2JNMVL4Q1OpbybpMe46YceNA0LfNsnqcnpJeItK/DhKbPxTTuGoX7w
# JNdoRORVbPR1VVnDuSeHVZlc4seAO+6d2sC26/PQPdP51ho1zBp+xUIZkpSFA8vW
# doUoHLWnqWU3dCCyFG1roSrgHjSHlq8xymLnjCbSLZ49kPmk8iyyizNDIXj//cOg
# rY7rlRyTlaCCfw7aSUROwnu7zER6EaJ+AliL7ojTdS5PWPsWeupWs7NpChUk555K
# 096V1hE0yZIXe+giAwW00aHzrDchIc2bQhpp0IoKRR7YufAkprxMiXAJQ1XCmnCf
# gPf8+3mnAgMBAAGjggGVMIIBkTAMBgNVHRMBAf8EAjAAMB0GA1UdDgQWBBTkO/zy
# Me39/dfzkXFjGVBDz2GM6DAfBgNVHSMEGDAWgBTvb1NK6eQGfHrK4pBW9i/USezL
# TjAOBgNVHQ8BAf8EBAMCB4AwFgYDVR0lAQH/BAwwCgYIKwYBBQUHAwgwgZUGCCsG
# AQUFBwEBBIGIMIGFMCQGCCsGAQUFBzABhhhodHRwOi8vb2NzcC5kaWdpY2VydC5j
# b20wXQYIKwYBBQUHMAKGUWh0dHA6Ly9jYWNlcnRzLmRpZ2ljZXJ0LmNvbS9EaWdp
# Q2VydFRydXN0ZWRHNFRpbWVTdGFtcGluZ1JTQTQwOTZTSEEyNTYyMDI1Q0ExLmNy
# dDBfBgNVHR8EWDBWMFSgUqBQhk5odHRwOi8vY3JsMy5kaWdpY2VydC5jb20vRGln
# aUNlcnRUcnVzdGVkRzRUaW1lU3RhbXBpbmdSU0E0MDk2U0hBMjU2MjAyNUNBMS5j
# cmwwIAYDVR0gBBkwFzAIBgZngQwBBAIwCwYJYIZIAYb9bAcBMA0GCSqGSIb3DQEB
# CwUAA4ICAQBlKq3xHCcEua5gQezRCESeY0ByIfjk9iJP2zWLpQq1b4URGnwWBdEZ
# D9gBq9fNaNmFj6Eh8/YmRDfxT7C0k8FUFqNh+tshgb4O6Lgjg8K8elC4+oWCqnU/
# ML9lFfim8/9yJmZSe2F8AQ/UdKFOtj7YMTmqPO9mzskgiC3QYIUP2S3HQvHG1FDu
# +WUqW4daIqToXFE/JQ/EABgfZXLWU0ziTN6R3ygQBHMUBaB5bdrPbF6MRYs03h4o
# bEMnxYOX8VBRKe1uNnzQVTeLni2nHkX/QqvXnNb+YkDFkxUGtMTaiLR9wjxUxu2h
# ECZpqyU1d0IbX6Wq8/gVutDojBIFeRlqAcuEVT0cKsb+zJNEsuEB7O7/cuvTQasn
# M9AWcIQfVjnzrvwiCZ85EE8LUkqRhoS3Y50OHgaY7T/lwd6UArb+BOVAkg2oOvol
# /DJgddJ35XTxfUlQ+8Hggt8l2Yv7roancJIFcbojBcxlRcGG0LIhp6GvReQGgMgY
# xQbV1S3CrWqZzBt1R9xJgKf47CdxVRd/ndUlQ05oxYy2zRWVFjF7mcr4C34Mj3oc
# CVccAvlKV9jEnstrniLvUxxVZE/rptb7IRE2lskKPIJgbaP5t2nGj/ULLi49xTcB
# ZU8atufk+EMF/cWuiC7POGT75qaL6vdCvHlshtjdNXOCIUjsarfNZzGCBRgwggUU
# AgEBMDwwKDEmMCQGA1UEAwwdRHlsYW4gUG93ZXJTaGVsbCBDb2RlIFNpZ25pbmcC
# EC6PIs/csnq9TT9nVIYkKkgwDQYJYIZIAWUDBAIBBQCggYQwGAYKKwYBBAGCNwIB
# DDEKMAigAoAAoQKAADAZBgkqhkiG9w0BCQMxDAYKKwYBBAGCNwIBBDAcBgorBgEE
# AYI3AgELMQ4wDAYKKwYBBAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgFT3mAyNzZB8F
# uP/2pA+tizoMsLB/ys7EEHQcwvOk+aEwDQYJKoZIhvcNAQEBBQAEggEABETfh8BP
# qzOapCkjGCABPCKXxzcS1Gx9fkz85MUdWUxzX9ChrhOaa0qat2etuLVX+GWv2o/j
# mhGVQd5Jp4cNTPJaEcKxbhaoV/jKvRix0VlNdmoDZLAaGEcoa7EDcfYMp18ZqAo4
# uTzHGgRp0zhK5WeI+DwyDCbdMEtmMmdA0BFtqeZf4IJqCKuoWOXLxG+C6VThh0y5
# vsI4+PXodqs/xAlvJ6kCsLubdIc00RpW1NfanEZ9HyrYnIJnke87oaYy7HOmsnNS
# xr+E4vbH39SWuFICZeYMZnk45JtfUAS7XNYtBp/LUivyxbxSiWJYUgSwfEuLYeDL
# oAh8Hyl1EoRi3aGCAyYwggMiBgkqhkiG9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJ
# BgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGln
# aUNlcnQgVHJ1c3RlZCBHNCBUaW1lU3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAy
# NSBDQTECEAqA7xhLjfEFgtHEdqeVdGgwDQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG
# 9w0BCQMxCwYJKoZIhvcNAQcBMBwGCSqGSIb3DQEJBTEPFw0yNjA0MjkyMTQ5NTVa
# MC8GCSqGSIb3DQEJBDEiBCA/fAPsl/fUMViBWBJSZ2O/xZd0ZXTxwIiKh5Rqqfo+
# hzANBgkqhkiG9w0BAQEFAASCAgAcpVB3W9Aseq7omcL2d/4neELZqYeHcEK9B6IB
# OUnAOi00mJUiYjYOoD7KRCxMwRkWVPQPchgA26haLk9lwe855fSz35mr//Kh6dED
# mCJTbV/WJynMnNfX/+lYXTv4CslF25aF1KvzUgz4Om9b3EBvl3dqrhO/Tm51zKSe
# Y5YTht5+qEzYJ4cauBHh7LfCTBv1nYGG38ITZJEL+RFMTAlm23xrxoFnax1hiLqg
# vn8nkZRekoHXi8BFw+EXfbgK8pt6HhDKdEos9YkFgszSOD7cjWnlmnNm43GvHr2Z
# MviRIZbAqvMazoyAIERDwR092/vfBBxvsXNCgO+bOeZesP4PEbrot0VbqZn3Ym3F
# LUN6hezejiqe03RQJD5/NRjp2XWsipgtK9pdmjMv8GAccQdiSTPJ4ka6FqSq7k92
# qsTlGA/IAKoKQxdkSxQVgqLNyJO0LqInwuLx8dPrmeQG4pTiZ78IAKfr07cZ/0dE
# I3dIlDKpbQ7wUanu4u7fM7xvhRDJ60FMWqGj8xi6gPn8L1xHrEtTDW4po1WWb0UY
# 8z3luNFH7yRxqGj75H97PDN0Qia/928+Ho3HTLrGTeejUi56KWbE/hdTUYyI66Wi
# 1HTwiUcYE07TscoPYHPa9tSCXrLv1uQXTcEL+fTiujCuDiGFg2DsYvRwWGR7b6Wo
# Lc7MNw==
# SIG # End signature block
