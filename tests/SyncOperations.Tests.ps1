BeforeAll {
    $script:ModulePath = [IO.Path]::Combine($PSScriptRoot, '..', 'src', 'Modules', 'SyncOperations.ps1')
    . $script:ModulePath
}

Describe 'SyncOperations - robocopy exit code interpretation' -Tag 'Unit' {
    It 'treats 0-3 as success' {
        foreach ($code in 0..3) {
            $r = ConvertFrom-RobocopyExitCode -ExitCode $code
            $r.Success | Should -Be $true
            $r.HasWarnings | Should -Be $false
        }
    }

    It 'treats 4-7 as success with warnings' {
        foreach ($code in 4..7) {
            $r = ConvertFrom-RobocopyExitCode -ExitCode $code
            $r.Success | Should -Be $true
            $r.HasWarnings | Should -Be $true
        }
    }

    It 'treats 8-16 as failure' {
        foreach ($code in 8..16) {
            $r = ConvertFrom-RobocopyExitCode -ExitCode $code
            $r.Success | Should -Be $false
        }
    }

    It 'returns a human-readable description' {
        (ConvertFrom-RobocopyExitCode -ExitCode 0).Description | Should -Match 'no'
        (ConvertFrom-RobocopyExitCode -ExitCode 1).Description | Should -Match 'copied'
        (ConvertFrom-RobocopyExitCode -ExitCode 8).Description | Should -Not -Match 'success'
    }
}

Describe 'SyncOperations - argument building' -Tag 'Unit' {
    It 'Build-RobocopyArgs uses the spec flags' {
        $args = Build-RobocopyArgs -Source '\\src\s' -Destination 'D:\d' `
            -Threads 6 -Retries 3 -RetryWaitSeconds 10 -LogFile 'C:\l.log'
        $argString = $args -join ' '
        $argString | Should -Match '/E'
        $argString | Should -Match '/Z'
        $argString | Should -Match '/COPY:DAT'
        $argString | Should -Match '/XO'
        $argString | Should -Match '/R:3'
        $argString | Should -Match '/W:10'
        $argString | Should -Match '/MT:6'
        $argString | Should -Match '/NP'
        $argString | Should -Match '/LOG\+:C:\\l\.log'
    }

    It 'Build-RobocopyArgs includes extra_flags verbatim' {
        $args = Build-RobocopyArgs -Source '\\s\s' -Destination 'D:\d' `
            -Threads 4 -Retries 1 -RetryWaitSeconds 5 -LogFile 'C:\l.log' `
            -ExtraFlags @('/COMPRESS','/IPG:50')
        $argString = $args -join ' '
        $argString | Should -Match '/COMPRESS'
        $argString | Should -Match '/IPG:50'
    }

    It 'Build-RobocopyArgs puts source and destination first' {
        $args = Build-RobocopyArgs -Source '\\src\s' -Destination 'D:\d' `
            -Threads 6 -Retries 3 -RetryWaitSeconds 10 -LogFile 'C:\l.log'
        $args[0] | Should -Be '\\src\s'
        $args[1] | Should -Be 'D:\d'
    }
}

Describe 'SyncOperations - mirror mode' -Tag 'Unit' {
    It 'Build-RobocopyArgs -Mirror includes /MIR' {
        $args = Build-RobocopyArgs -Source '\\src\s' -Destination 'D:\d' `
            -Threads 6 -Retries 3 -RetryWaitSeconds 10 -LogFile 'C:\l.log' -Mirror
        ($args -join ' ') | Should -Match '/MIR'
    }

    It 'Build-RobocopyArgs -Mirror omits /E (redundant with /MIR)' {
        $args = Build-RobocopyArgs -Source '\\src\s' -Destination 'D:\d' `
            -Threads 6 -Retries 3 -RetryWaitSeconds 10 -LogFile 'C:\l.log' -Mirror
        # /E should not appear as a standalone arg (would be wrong; /MIR includes it)
        $args | Should -Not -Contain '/E'
    }

    It 'Build-RobocopyArgs -Mirror omits /XO' {
        $args = Build-RobocopyArgs -Source '\\src\s' -Destination 'D:\d' `
            -Threads 6 -Retries 3 -RetryWaitSeconds 10 -LogFile 'C:\l.log' -Mirror
        $args | Should -Not -Contain '/XO'
    }

    It 'Build-RobocopyArgs without -Mirror keeps /E and /XO and omits /MIR' {
        $args = Build-RobocopyArgs -Source '\\src\s' -Destination 'D:\d' `
            -Threads 6 -Retries 3 -RetryWaitSeconds 10 -LogFile 'C:\l.log'
        $args | Should -Contain '/E'
        $args | Should -Contain '/XO'
        $args | Should -Not -Contain '/MIR'
    }

    It 'Build-RobocopyArgs -Mirror still includes the standard non-copy-mode flags' {
        $args = Build-RobocopyArgs -Source '\\src\s' -Destination 'D:\d' `
            -Threads 6 -Retries 3 -RetryWaitSeconds 10 -LogFile 'C:\l.log' -Mirror
        $argString = $args -join ' '
        $argString | Should -Match '/Z'
        $argString | Should -Match '/COPY:DAT'
        $argString | Should -Match '/R:3'
        $argString | Should -Match '/W:10'
        $argString | Should -Match '/MT:6'
        $argString | Should -Match '/NP'
        $argString | Should -Match '/LOG\+:'
    }
}

Describe 'SyncOperations - Test-RobocopyFlag allowlist' -Tag 'Unit' {
    It 'allows benign flags like /COMPRESS' {
        Test-RobocopyFlag -Flag '/COMPRESS' | Should -Be $true
    }

    It 'allows prefixed flags like /IPG:50' {
        Test-RobocopyFlag -Flag '/IPG:50' | Should -Be $true
        Test-RobocopyFlag -Flag '/MAXAGE:30' | Should -Be $true
    }

    It 'is case-insensitive' {
        Test-RobocopyFlag -Flag '/compress' | Should -Be $true
        Test-RobocopyFlag -Flag '/ipg:50' | Should -Be $true
    }

    It 'rejects /MIR (mirror is opt-in via retention.mode)' {
        Test-RobocopyFlag -Flag '/MIR' | Should -Be $false
    }

    It 'rejects /PURGE' {
        Test-RobocopyFlag -Flag '/PURGE' | Should -Be $false
    }

    It 'rejects /MOVE and /MOV' {
        Test-RobocopyFlag -Flag '/MOVE' | Should -Be $false
        Test-RobocopyFlag -Flag '/MOV' | Should -Be $false
    }

    It 'rejects /LOG and /LOG+ (log redirection could overwrite files)' {
        Test-RobocopyFlag -Flag '/LOG:C:\evil.log' | Should -Be $false
        Test-RobocopyFlag -Flag '/LOG+:C:\evil.log' | Should -Be $false
    }

    It 'rejects /JOB and /SAVE' {
        Test-RobocopyFlag -Flag '/JOB:foo' | Should -Be $false
        Test-RobocopyFlag -Flag '/SAVE:bar' | Should -Be $false
    }

    It 'rejects core flags we set ourselves' {
        Test-RobocopyFlag -Flag '/E' | Should -Be $false
        Test-RobocopyFlag -Flag '/XO' | Should -Be $false
        Test-RobocopyFlag -Flag '/COPY:DATSO' | Should -Be $false
    }

    It 'rejects flags not starting with /' {
        Test-RobocopyFlag -Flag 'COMPRESS' | Should -Be $false
        Test-RobocopyFlag -Flag '\\evil' | Should -Be $false
    }

    It 'rejects empty / whitespace input' {
        Test-RobocopyFlag -Flag '' | Should -Be $false
        Test-RobocopyFlag -Flag '   ' | Should -Be $false
    }
}

# SIG # Begin signature block
# MIIcIAYJKoZIhvcNAQcCoIIcETCCHA0CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDzVwKpfI0onr5O
# d2j2gMpFctN8VrrYrVxmCb7c8Su4eaCCFl4wggMgMIICCKADAgECAhAujyLP3LJ6
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
# AYI3AgELMQ4wDAYKKwYBBAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgSCeohp1BgxAs
# Ch9mQg0GhmGgkzmnMc+g7OopANm6XOowDQYJKoZIhvcNAQEBBQAEggEAcXImpLJ/
# xCDlHBGVduKiAaGYNiBBt05hSE6DV5XVGAC26VKL0OMvKdnAgWsZH3cOGaT7Xlp8
# 5wHIE84/ypgRYF9cCuT+RnYd7ljkzNGcZy9sH75/UeV986VwG1wNNvWzWPwZtFgk
# xzEYeWuW0EblKbP7BxCnCv6X8beTY0f5MWe6hRNsRFIvx5GNPlhBxqHhD5pogumF
# C7NkUmwA0JRtyt6m54Bw39fwNQES9p1gYZsZO8V5eH/66OLRmBtV/DU7nalF0ucr
# bysC3rS+d9fVFvFC+NaOoTlMMrIIQ8GJPkwEk/rzatDeVit9ADRnD1//FgBc1Lyz
# RPbiqRUnHgr4P6GCAyYwggMiBgkqhkiG9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJ
# BgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGln
# aUNlcnQgVHJ1c3RlZCBHNCBUaW1lU3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAy
# NSBDQTECEAqA7xhLjfEFgtHEdqeVdGgwDQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG
# 9w0BCQMxCwYJKoZIhvcNAQcBMBwGCSqGSIb3DQEJBTEPFw0yNjA0MjkyMTQ5NTZa
# MC8GCSqGSIb3DQEJBDEiBCBdhKu5iH9E18ZGc8lwT5YRVuMLavrGRNtjEUUHW9J0
# CzANBgkqhkiG9w0BAQEFAASCAgA1sAfLbLVLz8J/4yA3W0uWPhVBuFmMIHgMZdAX
# 2qEvnjd2ilvL7PdqauHEq7zs6SuUlRqjDlZv8nHSmSIlV7ErlPowPSBW4pPuBzbC
# TO4cgpC7yqF9TdSXVZeZSli9hx++4lkgdwy0bhSfWqmj9xcutyZyQWcOrevI5ipw
# goBLd9JO2ycsUBFptSryokliWkCffLOre7YTP+PDvoj6IuHnFvQy9iepJ1+mA4mv
# nSwpzJH8C/aUFfW9dl/KnLgBu7zd6Ym6/l2+23YqWlgF5UN+dkOf3CrhLbcNXT7M
# +YFKwCwgMkdfK/X2tKE0hkrx5Xflv2f+Dlnm9GsLRtlEHNZWLt07nT5QtJq/d+vU
# J9OjwfDpUimShBa4O3O3FvxFT5K/3OowhnIcJI+7ZQ1A/svH57A+LyRjJlhe1nTk
# sqcOCiBTdETTu3D1caoqVCZUX6kaTpkPZul/7NNZH51l/71+mu31WyQq9aokM5JK
# MHcTp7Kt9OWDyHw3R3lCO5gGkJ1lO9u10OJ+1ytssyDYasftTyUiqyk1mrGIDFCO
# f9WOK4JAVB/wyF+xSvnElAvEMMGrarvyfPI3AySxpMS4Z9usTeTsCzwNMV4MWmS5
# tTkRCsMIYw/lPfsNXzazIS7S2Bmm3VuDjiqVbqijv5QOLIrD+eJiCeyrtgS+aMEu
# W0btzg==
# SIG # End signature block
