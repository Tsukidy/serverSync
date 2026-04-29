<#
.SYNOPSIS
    ServerSync orchestrator. Enables NICs, runs configured sync pairs, disables NICs.
.DESCRIPTION
    Intended for Task Scheduler. Accepts -Tag to filter pairs. Supports -WhatIf and
    -ValidateConfig.
.PARAMETER ConfigPath
    Path to config.json. Default: ..\config\config.json relative to this script.
.PARAMETER Tag
    Optional. When provided, only pairs tagged with this value run.
.PARAMETER ValidateConfig
    Load and validate the config, then exit. No sync performed.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ConfigPath,
    [string]$Tag,
    [switch]$ValidateConfig
)

$ErrorActionPreference = 'Stop'

# Resolve default config path
if (-not $ConfigPath) {
    $ConfigPath = [IO.Path]::Combine($PSScriptRoot, '..', 'config', 'config.json')
}

# Load modules (dot-source)
$modulesDir = Join-Path $PSScriptRoot 'Modules'
. (Join-Path $modulesDir 'ConfigLoader.ps1')
. (Join-Path $modulesDir 'Logging.ps1')
. (Join-Path $modulesDir 'NetworkControl.ps1')
. (Join-Path $modulesDir 'SyncOperations.ps1')
. (Join-Path $modulesDir 'Retention.ps1')

# Load & validate config
$config = Read-ServerSyncConfig -Path $ConfigPath
$validation = Test-ServerSyncConfig -Config $config
if (-not $validation.Valid) {
    [Console]::Error.WriteLine("Config invalid:")
    foreach ($e in $validation.Errors) { [Console]::Error.WriteLine("  $e") }
    exit 2
}

if ($ValidateConfig) {
    Write-Host "Config OK: $ConfigPath"
    exit 0
}

# Initialize logging
$logger = New-ServerSyncLogger -LogDirectory $config.logging.log_directory `
                                -Prefix 'sync' `
                                -EventLogSource $config.logging.event_log_source

Write-ServerSyncLog -Logger $logger -Level 'INFO' -Message "ServerSync starting. Tag='$Tag'"

$selectedPairs = Select-ServerSyncPairs -Pairs $config.folder_pairs -Tag $Tag
Write-ServerSyncLog -Logger $logger -Level 'INFO' -Message "Matched $($selectedPairs.Count) pair(s)"

if ($selectedPairs.Count -eq 0) {
    Write-ServerSyncLog -Logger $logger -Level 'WARN' -Message 'No pairs matched, exiting'
    exit 0
}

$hasFailures = $false
$nicsEnabled = $false

try {
    if ($PSCmdlet.ShouldProcess('NICs', "Enable $($config.network.nics -join ', ')")) {
        Enable-ServerSyncNics -Names $config.network.nics
        $nicsEnabled = $true
        Write-ServerSyncLog -Logger $logger -Level 'INFO' -Message "NICs enabled"

        if (-not (Wait-NetworkReady -TargetHost $config.network.ready_check_host -TimeoutSeconds $config.network.ready_timeout_seconds)) {
            throw "Network not ready after $($config.network.ready_timeout_seconds)s (host: $($config.network.ready_check_host))"
        }
        Write-ServerSyncLog -Logger $logger -Level 'INFO' -Message "Network ready"
    }

    foreach ($pair in $selectedPairs) {
        Write-ServerSyncLog -Logger $logger -Level 'INFO' -Message "=== Pair: $($pair.name) ==="
        try {
            $cred = Get-ServerSyncCredential -TargetName $pair.credential_target

            # Map SMB drive temporarily for this pair
            $useDrive = $false
            try {
                if ($PSCmdlet.ShouldProcess($pair.source, 'New-SmbMapping')) {
                    New-SmbMapping -RemotePath $pair.source `
                        -UserName $cred.UserName `
                        -Password $cred.GetNetworkCredential().Password `
                        -Persistent $false -ErrorAction Stop | Out-Null
                    $useDrive = $true
                }

                $result = Invoke-RobocopySync -Source $pair.source `
                    -Destination $pair.destination `
                    -Threads $config.robocopy.threads `
                    -Retries $config.robocopy.retries `
                    -RetryWaitSeconds $config.robocopy.retry_wait_seconds `
                    -LogFile $logger.LogPath `
                    -ExtraFlags $config.robocopy.extra_flags `
                    -WhatIf:$WhatIfPreference

                Write-ServerSyncLog -Logger $logger -Level 'INFO' -Message "  robocopy exit $($result.ExitCode): $($result.Description)"

                if (-not $result.Success) {
                    $hasFailures = $true
                    Write-ServerSyncLog -Logger $logger -Level 'ERROR' -Message "  SYNC FAILED for '$($pair.name)'" -AlsoEventLog
                    continue
                }

                # Retention
                $policy = Resolve-RetentionPolicy -Pair $pair -Defaults $config.retention
                Write-ServerSyncLog -Logger $logger -Level 'INFO' -Message "  retention: mode=$($policy.Mode) count=$($policy.Count)"
                $cb = { param($msg) Write-ServerSyncLog -Logger $logger -Level 'INFO' -Message "  $msg" }
                Invoke-Retention -DestinationRoot $pair.destination -Policy $policy `
                    -LogCallback $cb -WhatIf:$WhatIfPreference
            }
            finally {
                if ($useDrive -and (Get-SmbMapping -RemotePath $pair.source -ErrorAction SilentlyContinue)) {
                    Remove-SmbMapping -RemotePath $pair.source -Force -ErrorAction SilentlyContinue
                }
            }
        }
        catch {
            $hasFailures = $true
            Write-ServerSyncLog -Logger $logger -Level 'ERROR' -Message "  PAIR ERROR '$($pair.name)': $($_.Exception.Message)" -AlsoEventLog
            # continue to next pair
        }
    }
}
catch {
    Write-ServerSyncLog -Logger $logger -Level 'ERROR' -Message "FATAL: $($_.Exception.Message)" -AlsoEventLog
    $hasFailures = $true
}
finally {
    if ($nicsEnabled) {
        try {
            if ($PSCmdlet.ShouldProcess('NICs', "Disable $($config.network.nics -join ', ')")) {
                Disable-ServerSyncNics -Names $config.network.nics
            }
        }
        catch {
            Write-ServerSyncLog -Logger $logger -Level 'ERROR' -Message "Failed to disable NICs: $($_.Exception.Message)" -AlsoEventLog
        }

        # Verify
        $allDown = $true
        if (-not $WhatIfPreference) {
            $allDown = Test-AllNicsDisabled -Names $config.network.nics
        }
        if (-not $allDown) {
            Write-ServerSyncLog -Logger $logger -Level 'ERROR' -Message 'CRITICAL: NIC disable could not be verified' -AlsoEventLog
            # Urgent email
            try {
                $smtpCred = $null
                if ($config.email.enabled -and $config.email.credential_target) {
                    $smtpCred = Get-ServerSyncCredential -TargetName $config.email.credential_target
                }
                Send-ServerSyncEmail -Config $config.email `
                    -Subject '[URGENT] ServerSync: NIC DISABLE VERIFICATION FAILED' `
                    -Body "Host: $env:COMPUTERNAME`nNICs may still be active. Investigate immediately." `
                    -Credential $smtpCred -HasFailures $true
            } catch {}
            exit 3
        }
        Write-ServerSyncLog -Logger $logger -Level 'INFO' -Message 'NICs verified disabled'
    }

    Remove-OldLogFiles -LogDirectory $config.logging.log_directory -RetentionDays $config.logging.log_retention_days
}

# Summary email
try {
    if ($config.email.enabled) {
        $smtpCred = $null
        if ($config.email.credential_target) {
            $smtpCred = Get-ServerSyncCredential -TargetName $config.email.credential_target
        }
        $status = if ($hasFailures) { 'FAILURES' } else { 'OK' }
        Send-ServerSyncEmail -Config $config.email `
            -Subject "[ServerSync] $status on $env:COMPUTERNAME" `
            -Body (Get-Content -Raw $logger.LogPath) `
            -Credential $smtpCred -HasFailures $hasFailures
    }
} catch {
    Write-ServerSyncLog -Logger $logger -Level 'WARN' -Message "Email send failed: $($_.Exception.Message)"
}

if ($hasFailures) { exit 1 } else { exit 0 }

# SIG # Begin signature block
# MIIb+wYJKoZIhvcNAQcCoIIb7DCCG+gCAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQU+fwzPleEOBk8bAvItf4b/CMh
# g3egghZeMIIDIDCCAgigAwIBAgIQLo8iz9yyer1NP2dUhiQqSDANBgkqhkiG9w0B
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
# CSqGSIb3DQEJBDEWBBQdQAqKKOFv9nnV5FQ/wCUn3QKqXjANBgkqhkiG9w0BAQEF
# AASCAQDXXOA7R79gsCI6bXa42WvsvGjdmdiVreLskiDPMG0rpR/y01TnKIsEJQOf
# +1ObtLy9YjnffQ7yCbXe59THTWyehKNiZjF2Rp65Hk5wz/xGyazM2xgEyUK45df4
# VM/yfe9RdLzF3U8vKkd2JI2rCIPzJgIU+IyOIG+qZF8eZfgOZCKCzDwUFLguFPes
# u2O/dQqRMQWF1d5wO6xM6IB1r3NGGgUPpRMnHSdrnKZUjwIcaNufffAugyf84KId
# 2oGRNJKfactJcERkIwv1p9Cwm+t3+5/1eRoIuz2HyG/9a+WqOoZlaU3467qdX4Pp
# bYmPevNspJ7qqdRPN1+jRRoIRhUXoYIDJjCCAyIGCSqGSIb3DQEJBjGCAxMwggMP
# AgEBMH0waTELMAkGA1UEBhMCVVMxFzAVBgNVBAoTDkRpZ2lDZXJ0LCBJbmMuMUEw
# PwYDVQQDEzhEaWdpQ2VydCBUcnVzdGVkIEc0IFRpbWVTdGFtcGluZyBSU0E0MDk2
# IFNIQTI1NiAyMDI1IENBMQIQCoDvGEuN8QWC0cR2p5V0aDANBglghkgBZQMEAgEF
# AKBpMBgGCSqGSIb3DQEJAzELBgkqhkiG9w0BBwEwHAYJKoZIhvcNAQkFMQ8XDTI2
# MDQyOTE2MDQ1MVowLwYJKoZIhvcNAQkEMSIEIKYWqrmFeSPeD7BYB8so/TA2IufB
# iqNV9zIIlJP+wK6lMA0GCSqGSIb3DQEBAQUABIICAEEXHXhiyBsuB4/ByhedAIEl
# GKpvnsy27oTWj4cf3BHYL4cZrlLzVxXPEv+XFCOajcWLTx4n2OKnjHC2VQBvoPKG
# URR2zpuAzCY60NylrZjaqNKJC8qEIzb5jLMlry9OQjodPT4pAoKnpBREJic/QH9g
# +if12am5LHjLaD3VxmIcCd+hRHVgoYnsdUSBSDIFK/KCXzNJ491HcGKqskdil/DH
# 3NOgcuxUNl7PHGWYUm5JaNLCKzBi0JIH1BFjpFmxH/Ily34n0yamLP15cbpBcZwa
# Llv1m8CN5LC5XILf5I1UJYnd9sbyl69JdybIY/6B+PqJjNfjqU5NuX2FOh0FJqSQ
# s62khvmtIwvf+2B81UBKeFfC0/szZKT1EoQqjlISF10+vNZ0EEh7ZobmdN3BliQ9
# FblMcH244V1iWxPri3A89VnBgiLD4cL0De8qJ9Oj4m3xDMXqpRMz9xUa5UrzqIJx
# sfCumG40MVmcXq8uOwETaU3o8WWw9P+67D+Y7IJuNnnDR4RpKxJQowwP88mB2v+3
# ko60ncwb6MPuEsLZ2HyekfjcnJEhYjYi/QTlw9eRGXHc/g0cwDwqbdoMdzpHM3HO
# sB97wtwssCfEN09SWY1tWMeaKN+xojej8EP88f8gY6nEUPEjIPpkYlBvqKWJIpaT
# ni0w05A1ewjmBpSVN4Vw
# SIG # End signature block
