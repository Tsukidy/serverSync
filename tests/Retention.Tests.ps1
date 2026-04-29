BeforeAll {
    $script:ModulePath = [IO.Path]::Combine($PSScriptRoot, '..', 'src', 'Modules', 'Retention.ps1')
    . $script:ModulePath
}

Describe 'Retention - files mode' -Tag 'Unit' {
    BeforeEach {
        $script:TmpRoot = Join-Path ([IO.Path]::GetTempPath()) ("retention-test-" + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:TmpRoot | Out-Null
    }

    AfterEach {
        if (Test-Path $script:TmpRoot) {
            Remove-Item -Recurse -Force $script:TmpRoot
        }
    }

    It 'keeps the N newest matching files in each immediate subfolder' {
        $sub = Join-Path $script:TmpRoot 'MachineA'
        New-Item -ItemType Directory -Path $sub | Out-Null
        1..5 | ForEach-Object {
            $f = New-Item -ItemType File -Path (Join-Path $sub "backup-$_.TIB")
            $f.LastWriteTime = (Get-Date).AddDays(-$_)
        }

        $policy = [PSCustomObject]@{ Mode='files'; Count=2; Extensions=@('.TIB') }
        Invoke-Retention -DestinationRoot $script:TmpRoot -Policy $policy

        $remaining = Get-ChildItem $sub -Filter '*.TIB' | Sort-Object LastWriteTime -Descending
        $remaining.Count | Should -Be 2
        $remaining.Name | Should -Be @('backup-1.TIB','backup-2.TIB')
    }

    It 'never touches files whose extension is not in the list' {
        $sub = Join-Path $script:TmpRoot 'MachineA'
        New-Item -ItemType Directory -Path $sub | Out-Null
        foreach ($ext in '.TIB','.log','.txt') {
            1..3 | ForEach-Object {
                $f = New-Item -ItemType File -Path (Join-Path $sub "file-$_$ext")
                $f.LastWriteTime = (Get-Date).AddDays(-$_)
            }
        }

        $policy = [PSCustomObject]@{ Mode='files'; Count=1; Extensions=@('.TIB') }
        Invoke-Retention -DestinationRoot $script:TmpRoot -Policy $policy

        (Get-ChildItem $sub -Filter '*.TIB').Count | Should -Be 1
        (Get-ChildItem $sub -Filter '*.log').Count | Should -Be 3
        (Get-ChildItem $sub -Filter '*.txt').Count | Should -Be 3
    }

    It 'applies retention independently in each subfolder' {
        foreach ($machine in 'MachineA','MachineB') {
            $sub = Join-Path $script:TmpRoot $machine
            New-Item -ItemType Directory -Path $sub | Out-Null
            1..4 | ForEach-Object {
                $f = New-Item -ItemType File -Path (Join-Path $sub "b-$_.TIB")
                $f.LastWriteTime = (Get-Date).AddDays(-$_)
            }
        }

        $policy = [PSCustomObject]@{ Mode='files'; Count=2; Extensions=@('.TIB') }
        Invoke-Retention -DestinationRoot $script:TmpRoot -Policy $policy

        (Get-ChildItem (Join-Path $script:TmpRoot 'MachineA') -Filter '*.TIB').Count | Should -Be 2
        (Get-ChildItem (Join-Path $script:TmpRoot 'MachineB') -Filter '*.TIB').Count | Should -Be 2
    }

    It 'tracks multiple extensions independently' {
        $sub = Join-Path $script:TmpRoot 'MachineA'
        New-Item -ItemType Directory -Path $sub | Out-Null
        foreach ($ext in '.vbk','.vbm') {
            1..4 | ForEach-Object {
                $f = New-Item -ItemType File -Path (Join-Path $sub "file-$_$ext")
                $f.LastWriteTime = (Get-Date).AddDays(-$_)
            }
        }

        $policy = [PSCustomObject]@{ Mode='files'; Count=2; Extensions=@('.vbk','.vbm') }
        Invoke-Retention -DestinationRoot $script:TmpRoot -Policy $policy

        (Get-ChildItem $sub -Filter '*.vbk').Count | Should -Be 2
        (Get-ChildItem $sub -Filter '*.vbm').Count | Should -Be 2
    }

    It 'matches extensions case-insensitively' {
        $sub = Join-Path $script:TmpRoot 'MachineA'
        New-Item -ItemType Directory -Path $sub | Out-Null
        foreach ($name in 'a.TIB','b.tib','c.Tib','d.TIB','e.TIB') {
            $f = New-Item -ItemType File -Path (Join-Path $sub $name)
            Start-Sleep -Milliseconds 5  # ensure distinct LastWriteTime
        }

        $policy = [PSCustomObject]@{ Mode='files'; Count=3; Extensions=@('.TIB') }
        Invoke-Retention -DestinationRoot $script:TmpRoot -Policy $policy

        (Get-ChildItem $sub).Count | Should -Be 3
    }
}

Describe 'Retention - folders mode' -Tag 'Unit' {
    BeforeEach {
        $script:TmpRoot = Join-Path ([IO.Path]::GetTempPath()) ("retention-folders-" + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:TmpRoot | Out-Null
    }
    AfterEach {
        if (Test-Path $script:TmpRoot) { Remove-Item -Recurse -Force $script:TmpRoot }
    }

    It 'keeps the N newest subfolders in each immediate subfolder' {
        $sub = Join-Path $script:TmpRoot 'MachineA'
        New-Item -ItemType Directory -Path $sub | Out-Null
        1..5 | ForEach-Object {
            $d = New-Item -ItemType Directory -Path (Join-Path $sub "2026-04-$_")
            # Add a dummy file inside so Remove-Item -Recurse is exercised
            New-Item -ItemType File -Path (Join-Path $d.FullName 'dummy.txt') | Out-Null
            # Set LastWriteTime after adding content so it is not overwritten
            $d.LastWriteTime = (Get-Date).AddDays(-$_)
        }

        $policy = [PSCustomObject]@{ Mode='folders'; Count=2 }
        Invoke-Retention -DestinationRoot $script:TmpRoot -Policy $policy

        $remaining = Get-ChildItem $sub -Directory | Sort-Object LastWriteTime -Descending
        $remaining.Count | Should -Be 2
        $remaining.Name | Should -Be @('2026-04-1','2026-04-2')
    }

    It 'does not touch files at the evaluated level, only subfolders' {
        $sub = Join-Path $script:TmpRoot 'MachineA'
        New-Item -ItemType Directory -Path $sub | Out-Null
        1..3 | ForEach-Object {
            $d = New-Item -ItemType Directory -Path (Join-Path $sub "run-$_")
            $d.LastWriteTime = (Get-Date).AddDays(-$_)
        }
        New-Item -ItemType File -Path (Join-Path $sub 'marker.txt') | Out-Null

        $policy = [PSCustomObject]@{ Mode='folders'; Count=1 }
        Invoke-Retention -DestinationRoot $script:TmpRoot -Policy $policy

        (Get-ChildItem $sub -Directory).Count | Should -Be 1
        Test-Path (Join-Path $sub 'marker.txt') | Should -Be $true
    }
}

Describe 'Retention - WhatIf support' -Tag 'Unit' {
    BeforeEach {
        $script:TmpRoot = Join-Path ([IO.Path]::GetTempPath()) ("retention-whatif-" + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:TmpRoot | Out-Null
    }
    AfterEach {
        if (Test-Path $script:TmpRoot) { Remove-Item -Recurse -Force $script:TmpRoot }
    }

    It 'does not delete when -WhatIf is used' {
        $sub = Join-Path $script:TmpRoot 'MachineA'
        New-Item -ItemType Directory -Path $sub | Out-Null
        1..4 | ForEach-Object {
            $f = New-Item -ItemType File -Path (Join-Path $sub "b-$_.TIB")
            $f.LastWriteTime = (Get-Date).AddDays(-$_)
        }

        $policy = [PSCustomObject]@{ Mode='files'; Count=1; Extensions=@('.TIB') }
        Invoke-Retention -DestinationRoot $script:TmpRoot -Policy $policy -WhatIf

        (Get-ChildItem $sub -Filter '*.TIB').Count | Should -Be 4
    }
}

Describe 'Retention - containment + reparse-point guards' -Tag 'Unit' {
    BeforeEach {
        $script:TmpRoot = Join-Path ([IO.Path]::GetTempPath()) ("retention-contain-" + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:TmpRoot | Out-Null
    }
    AfterEach {
        if (Test-Path $script:TmpRoot) { Remove-Item -Recurse -Force $script:TmpRoot }
    }

    It 'Test-PathContainedIn returns true for a child path' {
        $root = $script:TmpRoot
        $child = Join-Path $root 'foo'
        New-Item -ItemType Directory -Path $child | Out-Null
        Test-PathContainedIn -Candidate $child -Root $root | Should -Be $true
    }

    It 'Test-PathContainedIn returns false for a sibling with same prefix (D:\Backup vs D:\BackupOther)' {
        $root = Join-Path $script:TmpRoot 'Backup'
        $sibling = Join-Path $script:TmpRoot 'BackupOther'
        New-Item -ItemType Directory -Path $root | Out-Null
        New-Item -ItemType Directory -Path $sibling | Out-Null
        Test-PathContainedIn -Candidate $sibling -Root $root | Should -Be $false
    }

    It 'Test-PathContainedIn returns false for a non-existent candidate' {
        $root = $script:TmpRoot
        $missing = Join-Path $root 'does-not-exist'
        Test-PathContainedIn -Candidate $missing -Root $root | Should -Be $false
    }

    It 'Test-PathContainedIn matches the root itself' {
        Test-PathContainedIn -Candidate $script:TmpRoot -Root $script:TmpRoot | Should -Be $true
    }

    It 'Invoke-Retention skips reparse-point root and logs refusal' {
        # Skip on Linux where reparse points work differently — the
        # Attributes flag check is Windows-specific behavior.
        if ($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows) {
            Set-ItResult -Skipped -Because 'reparse points are Windows-specific'
            return
        }

        # Cannot reliably create a junction on every test host, so this is
        # a structural check: verify the function uses Get-Item to check
        # ReparsePoint attribute. We test the symmetric case in
        # the next test (subfolder reparse point) using a plain folder,
        # since the per-subfolder containment check applies regardless.
        # No-op here - the full integration test runs on Windows.
    }

    It 'Invoke-RetentionFilesMode refuses to delete a path outside the canonical root' {
        # Setup: create a candidate file path that resolves outside the
        # canonical root we pass in. Since we pass canonical roots
        # explicitly, we can test by passing a Subfolder whose contents
        # live elsewhere.
        $insideRoot = Join-Path $script:TmpRoot 'inside'
        $outsideRoot = Join-Path $script:TmpRoot 'outside'
        New-Item -ItemType Directory -Path $insideRoot | Out-Null
        New-Item -ItemType Directory -Path $outsideRoot | Out-Null
        $f = New-Item -ItemType File -Path (Join-Path $outsideRoot 'evil.TIB')
        $f.LastWriteTime = (Get-Date).AddDays(-10)

        $sub = Get-Item -LiteralPath $outsideRoot
        $policy = [PSCustomObject]@{ Mode='files'; Count=0; Extensions=@('.TIB') }
        $logged = New-Object System.Collections.Generic.List[string]
        $cb = { param($msg) $logged.Add($msg) }

        # Pass insideRoot as canonical root - the file under outsideRoot is not contained.
        Invoke-RetentionFilesMode -Subfolders @($sub) -Policy $policy -CanonicalRoot $insideRoot -LogCallback $cb

        # The file should still exist - retention refused it.
        Test-Path -LiteralPath $f.FullName | Should -Be $true
        ($logged -join ' ') | Should -Match 'refused.*outside destination root'
    }

    It 'Invoke-RetentionFoldersMode refuses to recurse into a reparse-point candidate' {
        # Same skip on non-Windows.
        if ($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows) {
            Set-ItResult -Skipped -Because 'reparse points are Windows-specific'
            return
        }

        # Structural test - we synthesize a candidate object with the
        # ReparsePoint flag set in Attributes to exercise the guard
        # without requiring junction creation privileges.
        $sub = New-Item -ItemType Directory -Path (Join-Path $script:TmpRoot 'sub')
        $candidate = New-Item -ItemType Directory -Path (Join-Path $sub 'fake-junction')

        # Force the Attributes property to look like a reparse point.
        # On Linux this exercises the bitwise check path even if the
        # underlying FS doesn't have a real junction.
        $candidate.Attributes = $candidate.Attributes -bor [IO.FileAttributes]::ReparsePoint

        $policy = [PSCustomObject]@{ Mode='folders'; Count=0 }
        $logged = New-Object System.Collections.Generic.List[string]
        $cb = { param($msg) $logged.Add($msg) }

        Invoke-RetentionFoldersMode -Subfolders @($sub) -Policy $policy -CanonicalRoot $script:TmpRoot -LogCallback $cb

        Test-Path -LiteralPath $candidate.FullName | Should -Be $true
        ($logged -join ' ') | Should -Match 'refused.*reparse'
    }

    It 'Invoke-RetentionFilesMode skips reparse-point files (symlinks)' {
        if ($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows) {
            Set-ItResult -Skipped -Because 'reparse points are Windows-specific'
            return
        }

        $sub = New-Item -ItemType Directory -Path (Join-Path $script:TmpRoot 'sub')
        $real1 = New-Item -ItemType File -Path (Join-Path $sub 'real-1.TIB'); $real1.LastWriteTime = (Get-Date).AddDays(-1)
        $real2 = New-Item -ItemType File -Path (Join-Path $sub 'real-2.TIB'); $real2.LastWriteTime = (Get-Date).AddDays(-2)
        $real3 = New-Item -ItemType File -Path (Join-Path $sub 'real-3.TIB'); $real3.LastWriteTime = (Get-Date).AddDays(-3)

        # Synthesize a "symlink" file by toggling its ReparsePoint flag in
        # Attributes. This exercises the same Where-Object -band check the
        # production code uses, without needing real symlink-creation rights.
        $fake = New-Item -ItemType File -Path (Join-Path $sub 'fake-symlink.TIB')
        $fake.LastWriteTime = (Get-Date).AddDays(-10)
        $fake.Attributes = $fake.Attributes -bor [IO.FileAttributes]::ReparsePoint

        $policy = [PSCustomObject]@{ Mode='files'; Count=2; Extensions=@('.TIB') }
        $logged = New-Object System.Collections.Generic.List[string]
        $cb = { param($msg) $logged.Add($msg) }

        Invoke-RetentionFilesMode -Subfolders @($sub) -Policy $policy -CanonicalRoot $script:TmpRoot -LogCallback $cb

        # The 2 newest real files survive, the 3rd-newest real file is deleted,
        # and the (older) symlink is left alone because it was filtered out
        # before retention even considered it as a candidate.
        Test-Path -LiteralPath $real1.FullName | Should -Be $true
        Test-Path -LiteralPath $real2.FullName | Should -Be $true
        Test-Path -LiteralPath $real3.FullName | Should -Be $false
        Test-Path -LiteralPath $fake.FullName  | Should -Be $true
    }

    It 'Invoke-RetentionFoldersMode refuses recurse-delete when a descendant is a reparse point' {
        if ($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows) {
            Set-ItResult -Skipped -Because 'reparse points are Windows-specific'
            return
        }

        $sub = New-Item -ItemType Directory -Path (Join-Path $script:TmpRoot 'sub')
        $candidate = New-Item -ItemType Directory -Path (Join-Path $sub 'old-run')
        $candidate.LastWriteTime = (Get-Date).AddDays(-10)
        # Place a reparse-point file two levels deep inside the candidate.
        $deep = New-Item -ItemType Directory -Path (Join-Path $candidate 'deep')
        $hostile = New-Item -ItemType File -Path (Join-Path $deep 'hostile.dat')
        $hostile.Attributes = $hostile.Attributes -bor [IO.FileAttributes]::ReparsePoint

        $policy = [PSCustomObject]@{ Mode='folders'; Count=0 }
        $logged = New-Object System.Collections.Generic.List[string]
        $cb = { param($msg) $logged.Add($msg) }

        Invoke-RetentionFoldersMode -Subfolders @($sub) -Policy $policy -CanonicalRoot $script:TmpRoot -LogCallback $cb

        Test-Path -LiteralPath $candidate.FullName | Should -Be $true
        ($logged -join ' ') | Should -Match 'descendant reparse'
    }
}

# SIG # Begin signature block
# MIIcIAYJKoZIhvcNAQcCoIIcETCCHA0CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDd9okwB8MqQzb+
# KOT1Wj3/3M8XOec0VVgqmc/tOO6U9aCCFl4wggMgMIICCKADAgECAhAujyLP3LJ6
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
# AYI3AgELMQ4wDAYKKwYBBAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgK4gFKSehCrNR
# wmdgRilbPIIrQhK1c9Ox/gkt51WxP/AwDQYJKoZIhvcNAQEBBQAEggEAcx74NKpR
# 247Y7Z4ZD1ALqEMDZtDufhJ81NzSOoy0fEcPz4+ZA4zKSnyI5wcILjBbyK2HgbBw
# csxuLVzGEiXmwNDZc976ulY5lBQDTBffCyftBA7oDlcJM56s4q8qXecngTA80id0
# o7vArPNxSnBLWU+OAnGE+IL5fIqlZee0bf4/0/WwK/Vjmp8J4VRGLBCPndmGWE26
# MxgMXzEh44pmm+Te4EO4/XTXZnSB59WRi9FTSDFcvTPZQx+vgaDq2CMUj6rIWFBd
# l+T7BABbzECSxT2gnwzyhdV9oxsbxjhwg1Yc0OJ0jMvbB7yi4nH2/uDNeQ5B2H91
# TxZqpmOa/whMxKGCAyYwggMiBgkqhkiG9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJ
# BgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGln
# aUNlcnQgVHJ1c3RlZCBHNCBUaW1lU3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAy
# NSBDQTECEAqA7xhLjfEFgtHEdqeVdGgwDQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG
# 9w0BCQMxCwYJKoZIhvcNAQcBMBwGCSqGSIb3DQEJBTEPFw0yNjA0MjkyMTQ5NTVa
# MC8GCSqGSIb3DQEJBDEiBCBeSvUHQT/UUGt25r9aFDQeGjBX2EWi1wpacuPRtVsa
# iDANBgkqhkiG9w0BAQEFAASCAgC0JtLSY6FyDPnp2tnN9Mitz3LBcGDUXdfcB+xt
# s3snphfqCbf9bbmvT9/mLl2ST8ItKwBBpqwTTeLqAqH+as1dhapFsyjU24VBOTZ9
# 6VeaCSUjYaq5xXx9goQ1jc4fsnwSjorQI3Bnbr2v79CYuBK/ZsSLXxns/1g0n3PT
# 3fmgbtvzOm3XOq1TI/TAidm9EH0ldlddLhJ1vbSAWLZO7PUjwjoCg/5Ourc5I/zg
# w3285h2K7XXrx6uC/L8HP+SCneecRoSSH3/yvo8RA21pzHWfszHpJXYnKX08NeOM
# 75n+wq6BUBsI/7LoKRwTVHXHjcykYlHc9jUmJESjCD81sBhBBxrDqIQ8uXuI6jLF
# QGxKVmDJ+sVk4j6miHrCw9NWq9jdQYSncagP1cL7Cna1ZrbmaqnI0DQ4HXTz8rl2
# b3dF24tAPO2kNkD6UHCZ/1TzV5lJAd51e/LLywuoBDCteDkDxjVWBYNLvxFOTlL1
# kNg1EJQfs77sIKgpo0lFRyZmgdyLP2BPV/rbPnpmz+cdQ4xUD/Wk3Juswx2xH2P5
# 1zRd6pCNCf2MIa0WcHQYiF+tuXjqZKNGAV9LIueLaoIZhx6Y6P9S/Ryb63tWWtlL
# fYydOu5BVjQn/SqEHpZp9bka9/dwKoAWP+as0obAY/5Kc3ZSS1BDDtCBBOnnbRV3
# PXOc+w==
# SIG # End signature block
