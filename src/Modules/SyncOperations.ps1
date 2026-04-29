<#
.SYNOPSIS
    robocopy wrapper and exit code interpretation.
#>

# Allowlist for robocopy.extra_flags. Anything not on this list is rejected
# by Test-RobocopyFlag (used by config validation).
#
# Excluded by design:
#   /MIR /PURGE /MOVE /MOV    - destructive (mirror is opt-in via retention.mode='mirror')
#   /LOG /LOG+ /UNILOG /UNILOG+ - log redirection (could overwrite config or other files)
#   /JOB /SAVE                - reads/writes job files
#   /S /E /XO /COPY /COPYALL  - overrides core flags we set explicitly
$script:RobocopyAllowedExactFlags = @(
    '/COMPRESS', '/B', '/ZB',
    '/NS', '/NC', '/NFL', '/NDL', '/NJH', '/NJS',
    '/V', '/X', '/TS', '/FP'
)
$script:RobocopyAllowedPrefixedFlags = @(
    '/IPG:', '/MAXAGE:', '/MINAGE:', '/MAXSIZE:', '/MINSIZE:'
)

function Test-RobocopyFlag {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Flag
    )
    if ([string]::IsNullOrWhiteSpace($Flag)) { return $false }
    if (-not $Flag.StartsWith('/')) { return $false }

    $upper = $Flag.ToUpperInvariant()
    if ($script:RobocopyAllowedExactFlags -contains $upper) { return $true }
    foreach ($prefix in $script:RobocopyAllowedPrefixedFlags) {
        if ($upper.StartsWith($prefix)) { return $true }
    }
    return $false
}

function ConvertFrom-RobocopyExitCode {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$ExitCode
    )

    # Robocopy uses a bitmask:
    # 1 = files copied, 2 = extra files/dirs, 4 = mismatches, 8 = copy failures, 16 = fatal
    $description = switch ($ExitCode) {
        0  { 'no files copied, no failures' }
        1  { 'files copied successfully' }
        2  { 'extra files/dirs detected (not copied)' }
        3  { 'files copied + extras detected' }
        4  { 'mismatches detected' }
        5  { 'mismatches + files copied' }
        6  { 'mismatches + extras' }
        7  { 'mismatches + files copied + extras' }
        8  { 'copy errors occurred' }
        9  { 'copy errors + files copied' }
        16 { 'fatal error (robocopy did not run)' }
        default {
            if ($ExitCode -ge 8) { "failure (exit $ExitCode)" }
            else { "unknown exit $ExitCode" }
        }
    }

    return [PSCustomObject]@{
        ExitCode    = $ExitCode
        Success     = ($ExitCode -lt 8)
        HasWarnings = ($ExitCode -ge 4 -and $ExitCode -lt 8)
        Description = $description
    }
}

function Build-RobocopyArgs {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][int]$Threads,
        [Parameter(Mandatory)][int]$Retries,
        [Parameter(Mandatory)][int]$RetryWaitSeconds,
        [Parameter(Mandatory)][string]$LogFile,
        [string[]]$ExtraFlags = @(),
        [switch]$Mirror
    )

    # In mirror mode, /MIR replaces /E (and adds /PURGE).
    # /XO is dropped because mirror should overwrite older destination files.
    $copyMode = if ($Mirror) { @('/MIR') } else { @('/E', '/XO') }

    $robocopyArgs = @(
        $Source
        $Destination
    ) + $copyMode + @(
        '/Z'
        '/COPY:DAT'
        "/R:$Retries"
        "/W:$RetryWaitSeconds"
        "/MT:$Threads"
        '/NP'
        "/LOG+:$LogFile"
    )
    if ($ExtraFlags) { $robocopyArgs += $ExtraFlags }
    return ,$robocopyArgs
}

function Invoke-RobocopySync {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][int]$Threads,
        [Parameter(Mandatory)][int]$Retries,
        [Parameter(Mandatory)][int]$RetryWaitSeconds,
        [Parameter(Mandatory)][string]$LogFile,
        [string[]]$ExtraFlags = @(),
        [switch]$Mirror
    )

    if (-not (Test-Path -Path $Destination -PathType Container)) {
        if ($PSCmdlet.ShouldProcess($Destination, 'Create destination directory')) {
            New-Item -ItemType Directory -Path $Destination -Force | Out-Null
        }
    }

    $robocopyArgs = Build-RobocopyArgs -Source $Source -Destination $Destination `
        -Threads $Threads -Retries $Retries -RetryWaitSeconds $RetryWaitSeconds `
        -LogFile $LogFile -ExtraFlags $ExtraFlags -Mirror:$Mirror

    $action = if ($Mirror) { 'robocopy /MIR' } else { 'robocopy' }
    if ($PSCmdlet.ShouldProcess("$Source -> $Destination", $action)) {
        $process = Start-Process -FilePath 'robocopy' -ArgumentList $robocopyArgs -Wait -PassThru -NoNewWindow
        return (ConvertFrom-RobocopyExitCode -ExitCode $process.ExitCode)
    }
    else {
        return [PSCustomObject]@{ ExitCode = 0; Success = $true; HasWarnings = $false; Description = '[WhatIf] skipped' }
    }
}
# SIG # Begin signature block
# MIIb+wYJKoZIhvcNAQcCoIIb7DCCG+gCAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQUdKhl0eAgq3ZT02kLn7fwaFU/
# rBegghZeMIIDIDCCAgigAwIBAgIQLo8iz9yyer1NP2dUhiQqSDANBgkqhkiG9w0B
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
# CSqGSIb3DQEJBDEWBBQ+hn8l96YcoxwnhMQ0DyWNocm6LzANBgkqhkiG9w0BAQEF
# AASCAQBd8HYF8AG8nIE5S/AfdA3wWqifAMKoC3H18YVZfUXtOMPOpByscM2FZPYU
# q5dmUpnet5CHoaH3zYMBnu97y4DS584rxwBKjAn1UhBxpaVCDtJKH7DyL0kmF/Tx
# fXF41BcbsKoJkV0lX6PlXq3/Fcy16ooVlBKaEwUuNWy8/tuessFMSbCewMToMXCR
# F7AmkdeG1EGRYIMmYDLBxw9cRVHYgs2ASnwRWgszG1k/S9p857n0VwKkTQz1DYto
# sUR6KdbKsI65pmaeRl3GGfhwxpvfHbXKU5CxLJ0NmnPnV+U/Vo3fTHsm1Ob9V7dh
# w87QoWfTpCY9xhaVk+dn0gtGJOZaoYIDJjCCAyIGCSqGSIb3DQEJBjGCAxMwggMP
# AgEBMH0waTELMAkGA1UEBhMCVVMxFzAVBgNVBAoTDkRpZ2lDZXJ0LCBJbmMuMUEw
# PwYDVQQDEzhEaWdpQ2VydCBUcnVzdGVkIEc0IFRpbWVTdGFtcGluZyBSU0E0MDk2
# IFNIQTI1NiAyMDI1IENBMQIQCoDvGEuN8QWC0cR2p5V0aDANBglghkgBZQMEAgEF
# AKBpMBgGCSqGSIb3DQEJAzELBgkqhkiG9w0BBwEwHAYJKoZIhvcNAQkFMQ8XDTI2
# MDQyOTE3MTcxMFowLwYJKoZIhvcNAQkEMSIEIC+lR4EnssXK175XOZ9Oj30pFr/s
# eO9Hi+rigdFYfstXMA0GCSqGSIb3DQEBAQUABIICAIM2Ah5nb6Zue5I2ILqVrtT+
# pbH1i+aRY3nsetnHe4IStCw8p0pC5KkpSxYsCGLjiurBiYvGbgONcagBIyWFc4ed
# z+IjSakP06m++9wztoOYq8ycI/rNUT/S2Cp+K6nPwm8m3Bt7EHsYeln4asuAVIGY
# Qrpc9dZiAIdyLWThZL4pFOMqh1Yv51wJpizxcmBNl9GXEiexodfL1yGHwhD/wmt3
# EvJwlYIdE7st4Z11K0jMOn4N5sKGE0ckq7M0sFu3/6/Qqu1V8QBjUA3P9ZALXgHD
# UPTlQrEQeLaaWetX3X/hfdjFzKfZRKfw73vN1/1wABrzf7GzHfoEoAHczboJWfDd
# 7Djkebb+UC7ssPlInryWGWl90Rgblz506vtRpQOCZ9aeHRRFAAHX0lW1Pp/D2Qli
# PnNBmIATXQpLX7omoV8a0cIZk0WSoRX8E/yDerrP9UclxAvM2DfhLgI0GDvcsOmF
# zQ+Vh0YItRDeZY8i3vgbrhdys9BcqMMoEPTrkvA5a+EHs7HiK/qHqIS9guZw/lpt
# 1eLNdUwhQZscoPp4m7zRbUjjWHBeDOU0TVofxRk56GER5GyJ2QpV1cTzVK5CbzSk
# 7OQMemMxKT5X5Nsm/Bx4XgMVGzEazNbidfwqn+a7jPxN+T71Mq2iErO6p8mnOlUw
# 75LGfheOL531pKm+k3gq
# SIG # End signature block
