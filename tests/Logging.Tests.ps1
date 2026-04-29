BeforeAll {
    $script:ModulePath = [IO.Path]::Combine($PSScriptRoot, '..', 'src', 'Modules', 'Logging.ps1')
    . $script:ModulePath
}

Describe 'Logging - file logger' -Tag 'Unit' {
    BeforeEach {
        $script:TmpDir = Join-Path ([IO.Path]::GetTempPath()) ("logging-test-" + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:TmpDir | Out-Null
    }
    AfterEach {
        if (Test-Path $script:TmpDir) { Remove-Item -Recurse -Force $script:TmpDir }
    }

    It 'New-ServerSyncLogger returns a logger object with path' {
        $logger = New-ServerSyncLogger -LogDirectory $script:TmpDir -Prefix 'sync'
        $logger.LogPath | Should -Not -BeNullOrEmpty
        $logger.LogPath | Should -Match 'sync-\d{4}-\d{2}-\d{2}'
    }

    It 'Write-ServerSyncLog appends a timestamped line' {
        $logger = New-ServerSyncLogger -LogDirectory $script:TmpDir -Prefix 'sync'
        Write-ServerSyncLog -Logger $logger -Level 'INFO' -Message 'hello'
        $content = Get-Content -Raw $logger.LogPath
        $content | Should -Match 'INFO'
        $content | Should -Match 'hello'
        $content | Should -Match '\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}'
    }

    It 'Write-ServerSyncLog supports multiple levels' {
        $logger = New-ServerSyncLogger -LogDirectory $script:TmpDir -Prefix 'sync'
        Write-ServerSyncLog -Logger $logger -Level 'ERROR' -Message 'bang'
        Write-ServerSyncLog -Logger $logger -Level 'WARN'  -Message 'hmm'
        $content = Get-Content -Raw $logger.LogPath
        $content | Should -Match 'ERROR.*bang'
        $content | Should -Match 'WARN.*hmm'
    }

    It 'Remove-OldLogFiles deletes files older than retention' {
        $old = New-Item -ItemType File -Path (Join-Path $script:TmpDir 'old.log')
        $old.LastWriteTime = (Get-Date).AddDays(-100)
        $new = New-Item -ItemType File -Path (Join-Path $script:TmpDir 'new.log')
        Remove-OldLogFiles -LogDirectory $script:TmpDir -RetentionDays 90
        Test-Path $old.FullName | Should -Be $false
        Test-Path $new.FullName | Should -Be $true
    }
}

Describe 'Logging - email' -Tag 'Unit' {
    It 'Send-ServerSyncEmail returns early when email.enabled is false' {
        $emailConfig = [PSCustomObject]@{ enabled=$false }
        # Should not throw and should not call Send-MailMessage
        { Send-ServerSyncEmail -Config $emailConfig -Subject 'x' -Body 'y' -Credential $null } |
            Should -Not -Throw
    }

    It 'Send-ServerSyncEmail returns early when send_on is "failure" and no failures' {
        $emailConfig = [PSCustomObject]@{ enabled=$true; send_on='failure' }
        { Send-ServerSyncEmail -Config $emailConfig -Subject 'x' -Body 'y' -Credential $null -HasFailures $false } |
            Should -Not -Throw
    }

    It 'Test-ShouldSendEmail matches send_on logic' {
        (Test-ShouldSendEmail -SendOn 'always'  -HasFailures $true)  | Should -Be $true
        (Test-ShouldSendEmail -SendOn 'always'  -HasFailures $false) | Should -Be $true
        (Test-ShouldSendEmail -SendOn 'failure' -HasFailures $true)  | Should -Be $true
        (Test-ShouldSendEmail -SendOn 'failure' -HasFailures $false) | Should -Be $false
        (Test-ShouldSendEmail -SendOn 'never'   -HasFailures $true)  | Should -Be $false
    }
}
# SIG # Begin signature block
# MIIb+wYJKoZIhvcNAQcCoIIb7DCCG+gCAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQUMLn0HSQkLmtjTRl9of8DxB5f
# AxGgghZeMIIDIDCCAgigAwIBAgIQLo8iz9yyer1NP2dUhiQqSDANBgkqhkiG9w0B
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
# CSqGSIb3DQEJBDEWBBTVL4YUqecV9f1XUyGlhDFALfFx4DANBgkqhkiG9w0BAQEF
# AASCAQAcuuVgOxP8WyU2vmOZbyKO8at6YCFstPplI3IBJFaevETjO87J/LGMpez2
# ThQd0P4ZChXdHulRdrzyzzs7pSUM6FLjHAecTVdXPyZ0XdWL5FU7WwPzW0Stt+Gs
# y9iySy2+LDKYkc3k+d9AI6PgtCWqpvm8NQX6Z7+eeg33sczVvdU+gQXaxUNQda65
# WY/QVsN428mPqLV8s2H+zMSO0pNhBMZjPezAWZGzY0V08wN0ncpzK1e3ANWUnCGI
# bb0vX4qHmO07rlb6mam3ZvBLn9uD+kdzKzfjP0cwxtFckHVuPI+W2QHF0eAmeUzT
# H3EbvfL/PMg4lct7fwSB/n2s5AcYoYIDJjCCAyIGCSqGSIb3DQEJBjGCAxMwggMP
# AgEBMH0waTELMAkGA1UEBhMCVVMxFzAVBgNVBAoTDkRpZ2lDZXJ0LCBJbmMuMUEw
# PwYDVQQDEzhEaWdpQ2VydCBUcnVzdGVkIEc0IFRpbWVTdGFtcGluZyBSU0E0MDk2
# IFNIQTI1NiAyMDI1IENBMQIQCoDvGEuN8QWC0cR2p5V0aDANBglghkgBZQMEAgEF
# AKBpMBgGCSqGSIb3DQEJAzELBgkqhkiG9w0BBwEwHAYJKoZIhvcNAQkFMQ8XDTI2
# MDQyOTE3MTcxMFowLwYJKoZIhvcNAQkEMSIEIB0eCEmg7XFKM1McuCzfI13o/cEE
# pujxJI26G5+xJMLsMA0GCSqGSIb3DQEBAQUABIICAHeMhd++4DYVywlW76bwhhVb
# SA3O3W7LP0L4bm5CJFcWsTPK9nok885u/sVqa7sWWEdROg1R5SM/pfI4rp8hjBsf
# TtrEGDl1x5aK8dnyP2yY0Q//6ylEYqX4wKp9QB69/47aW2ZEiaGXmg41H/x4jAOF
# ekBfpkiqoDPkudOggznYRx/1CjsxyMf/fJHFvLe4lqhND1UOc2gTmG9aehkrO1WG
# 4AAYi+WzdMWr9aUR0K2uYLYnzOG3+hAvVt8C4ZsIAxyE7sBstQCIAoVdP/TIqf0R
# XWV5OA4VfQ5tBwM2oPCORyBVpKDMgqZisXpBG6rTCp1lqI3iI9FwaX/iX+DCytX5
# 5+HSVDn5zH7FYN1joQ6w4cgmudp9ToMlFp7KLKJCxphIhU5b1HG0fmolN8UqV1CT
# YshGvjXsLfSmN9aW1mTDUmD5GH1EZaTdQiyPsSmvMdpiDJ6FH5E1TJehdEb9NqpD
# NBYGeApSD03Di/1qwyzvBkjl1QMLkHc71opngzZEMbVrtdGVjoh2zoI1aXXZqQ0g
# kfztsS6VMYmeF5mEOoX7HziFUcHbAXJQGq0AhhNZifc+1JtX6DKFLgWo7DQNyzQu
# QoBdhdl73albqg4HBEjCbJOWtjI23t52IdCQU2gLWuIR85m/oo/Jh/3+xQ6DDVa3
# z51JbqGa56MNWP9AlFna
# SIG # End signature block
