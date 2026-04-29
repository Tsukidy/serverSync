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
        # Set $nicsEnabled BEFORE calling Enable-ServerSyncNics. If Enable
        # partially succeeds (some NICs up, then one throws on Group Policy),
        # the finally block must still run the disable + verify - otherwise
        # a partially-enabled state would never be torn down.
        $nicsEnabled = $true
        Enable-ServerSyncNics -Names $config.network.nics
        Write-ServerSyncLog -Logger $logger -Level 'INFO' -Message "NICs enabled"

        $readyArgs = @{
            TargetHost = $config.network.ready_check_host
            TimeoutSeconds = $config.network.ready_timeout_seconds
        }
        if ($config.network.ready_check_port) { $readyArgs['Port'] = [int]$config.network.ready_check_port }
        if (-not (Wait-NetworkReady @readyArgs)) {
            $portMsg = if ($readyArgs.Port) { ":$($readyArgs.Port)" } else { '' }
            throw "Network not ready after $($config.network.ready_timeout_seconds)s (host: $($config.network.ready_check_host)$portMsg)"
        }
        Write-ServerSyncLog -Logger $logger -Level 'INFO' -Message "Network ready"
    }

    foreach ($pair in $selectedPairs) {
        Write-ServerSyncLog -Logger $logger -Level 'INFO' -Message "=== Pair: $($pair.name) ==="
        try {
            $cred = Get-ServerSyncCredential -TargetName $pair.credential_target

            # Establish the SMB session via New-PSDrive -Credential. This passes
            # the password through the SecureString in the PSCredential to the
            # underlying Win32 logon API - it is NEVER materialized as a plain
            # string command-line argument, so it does not appear in
            # PowerShell ScriptBlock/Module logging, ETW, or process listings.
            #
            # The drive name is unique-per-pair (random suffix) so concurrent
            # or back-to-back pairs cannot collide.
            $driveName = "sssync_$([Guid]::NewGuid().ToString('N').Substring(0,8))"
            $drive = $null
            try {
                if ($PSCmdlet.ShouldProcess($pair.source, 'Establish SMB session via New-PSDrive')) {
                    $drive = New-PSDrive -Name $driveName -PSProvider FileSystem `
                        -Root $pair.source -Credential $cred -Scope Script `
                        -ErrorAction Stop
                }

                # Resolve retention policy first so we know whether this is a mirror pair
                $policy = Resolve-RetentionPolicy -Pair $pair -Defaults $config.retention
                $isMirror = ($policy.Mode -eq 'mirror')

                if ($isMirror) {
                    Write-ServerSyncLog -Logger $logger -Level 'INFO' -Message "  robocopy MIRROR mode - destination will match source exactly, including any deletions on source side"
                }

                $result = Invoke-RobocopySync -Source $pair.source `
                    -Destination $pair.destination `
                    -Threads $config.robocopy.threads `
                    -Retries $config.robocopy.retries `
                    -RetryWaitSeconds $config.robocopy.retry_wait_seconds `
                    -LogFile $logger.LogPath `
                    -ExtraFlags $config.robocopy.extra_flags `
                    -Mirror:$isMirror `
                    -WhatIf:$WhatIfPreference

                Write-ServerSyncLog -Logger $logger -Level 'INFO' -Message "  robocopy exit $($result.ExitCode): $($result.Description)"

                if (-not $result.Success) {
                    $hasFailures = $true
                    Write-ServerSyncLog -Logger $logger -Level 'ERROR' -Message "  SYNC FAILED for '$($pair.name)'" -AlsoEventLog
                    continue
                }

                # Retention (skipped for mirror — robocopy /PURGE already handled deletion)
                if ($isMirror) {
                    Write-ServerSyncLog -Logger $logger -Level 'INFO' -Message "  retention: skipped (mirror mode - robocopy /PURGE handled deletion)"
                }
                else {
                    Write-ServerSyncLog -Logger $logger -Level 'INFO' -Message "  retention: mode=$($policy.Mode) count=$($policy.Count)"
                    $cb = { param($msg) Write-ServerSyncLog -Logger $logger -Level 'INFO' -Message "  $msg" }
                    Invoke-Retention -DestinationRoot $pair.destination -Policy $policy `
                        -LogCallback $cb -WhatIf:$WhatIfPreference
                }
            }
            finally {
                if ($drive) {
                    Remove-PSDrive -Name $driveName -Force -ErrorAction SilentlyContinue
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
            # Urgent email - include adapter status snapshot and log tail so
            # responders have actionable diagnostics rather than just
            # 'investigate immediately'.
            try {
                $smtpCred = $null
                if ($config.email.enabled -and $config.email.credential_target) {
                    $smtpCred = Get-ServerSyncCredential -TargetName $config.email.credential_target
                }
                $adapterReport = ''
                try {
                    $adapterReport = (Get-NetAdapter | Format-Table Name, Status, InterfaceDescription -AutoSize | Out-String)
                } catch {}
                $tail = Get-LogTail -Path $logger.LogPath -MaxLines 50 -MaxBytes 16KB
                $urgentBody = @(
                    "Host: $env:COMPUTERNAME"
                    "NICs may still be active. Investigate IMMEDIATELY."
                    ""
                    "--- Get-NetAdapter ---"
                    $adapterReport
                    "--- log tail ---"
                    $tail
                ) -join [Environment]::NewLine
                Send-ServerSyncEmail -Config $config.email `
                    -Subject '[URGENT] ServerSync: NIC DISABLE VERIFICATION FAILED' `
                    -Body $urgentBody `
                    -Credential $smtpCred -HasFailures $true
            }
            catch {
                Write-ServerSyncLog -Logger $logger -Level 'ERROR' -Message "Urgent email send failed: $($_.Exception.Message)"
            }
            exit 3
        }
        Write-ServerSyncLog -Logger $logger -Level 'INFO' -Message 'NICs verified disabled'
    }

    # Belt-and-suspenders: clean up any per-pair PSDrives that escaped their
    # inner finally (e.g., a robocopy child that held a handle when we tried
    # to remove). Logged so we know if it ever happens.
    Get-PSDrive -Name 'sssync_*' -ErrorAction SilentlyContinue | ForEach-Object {
        Write-ServerSyncLog -Logger $logger -Level 'WARN' -Message "Stranded PSDrive removed: $($_.Name)"
        Remove-PSDrive -Name $_.Name -Force -ErrorAction SilentlyContinue
    }

    Remove-OldLogFiles -LogDirectory $config.logging.log_directory -RetentionDays $config.logging.log_retention_days
}

# Summary email - send a tail of the log, not the entire file. Bounded body
# size keeps SMTP payloads reasonable and reduces accidental data exposure.
try {
    if ($config.email.enabled) {
        $smtpCred = $null
        if ($config.email.credential_target) {
            $smtpCred = Get-ServerSyncCredential -TargetName $config.email.credential_target
        }
        $status = if ($hasFailures) { 'FAILURES' } else { 'OK' }
        $body = Get-LogTail -Path $logger.LogPath -MaxLines 200 -MaxBytes 64KB
        Send-ServerSyncEmail -Config $config.email `
            -Subject "[ServerSync] $status on $env:COMPUTERNAME" `
            -Body $body `
            -Credential $smtpCred -HasFailures $hasFailures
    }
} catch {
    Write-ServerSyncLog -Logger $logger -Level 'WARN' -Message "Email send failed: $($_.Exception.Message)"
}

if ($hasFailures) { exit 1 } else { exit 0 }
# SIG # Begin signature block
# MIIcIAYJKoZIhvcNAQcCoIIcETCCHA0CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDAKQeY0aDe+bd0
# G6Pv9kmdcv2yNTUy+INXK1I4Z4XrAaCCFl4wggMgMIICCKADAgECAhAujyLP3LJ6
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
# AYI3AgELMQ4wDAYKKwYBBAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgzXm0s4Eo3cZn
# 5+EM5LnRsmIU/g/LjU5tGFPNm8kYBNUwDQYJKoZIhvcNAQEBBQAEggEA0BzH9E8g
# LDtjNkFa/I3+gJscxGD+ZYdP2CqvHEJkmYM34QanVNYwtTvH5M9eJFEJEPeXh4bl
# zR6dvIC0jEbMMtfgIOy+XWFgP2qQCBudOTvFLBja7hH/hAzauyPzPzjHiNt8CepE
# qTqYiJ1dNCZDew4Re3a8vUWN2qgHPh22sapwryrZZOyBllL0uiMSt1Dqjmc1HxMz
# kEj6hrJWrUSxG1giUCZbFf0sePzA3bO2SyUJ9SlRrPfBeWFQm2QU/W1t6T4xoOR+
# STOy2aWs4BOCShit9Is8DuqM0mmO7xRYWWhc2MvkA0EsxyKFy2wzuO84r4YDfmAG
# qpLsTykCOYZdxqGCAyYwggMiBgkqhkiG9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJ
# BgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGln
# aUNlcnQgVHJ1c3RlZCBHNCBUaW1lU3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAy
# NSBDQTECEAqA7xhLjfEFgtHEdqeVdGgwDQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG
# 9w0BCQMxCwYJKoZIhvcNAQcBMBwGCSqGSIb3DQEJBTEPFw0yNjA0MjkyMTQ5NTVa
# MC8GCSqGSIb3DQEJBDEiBCDPfwFy5vMxAXTdmtXPqycF4HWqyC05OdWt7wmRUzZ9
# IDANBgkqhkiG9w0BAQEFAASCAgB4wT7TRLv26T22nybLjKaG8oNVSjJiYMofEIzu
# IbIRN3n6gp0g4swyjdjCy0UW+mx0/kMISMtanOB+nAFFoNHMG/UUlrthKOW2ML0s
# a++hDz5FJAuye89RZIe00oVTKC/FNnWJsSNPuGdIk1vuJXpjuGnspkmIf9FMBRSC
# 1Eglksv4kFtJ81t55oiaB9Bih6T1EiaAiR6VCJc368xYp3dXnHjKk822Cizz0fQe
# 5kQOvau6FounllGqTrr8Re2/mJOm8RRRjQlsStsL41odhb/t/gos3yNd/sRB94z0
# U3aEieRmhMntjfUTLiqfbv4k8vK5Aw2TjcqT8aAdTAavvn8xGdVpa2DvNI7zRSsL
# +/DqKWS0tkTvEkwGl7J9a9hFuflKHVzhvK53zr6e0C/r5Zlk4jZepG3kvSuNXU7L
# iPMIphcHnr0sA2aLUUObVHhECXaqz2xF+qEdpGIjFADn7snY6cShvIJbcGrYykGj
# 57QV4RuL94i0NuTQJKdV+opcn/TT0JNI8yFDrbbsoiLyshmo+fyZVddp8kzL2u5c
# nOh32dJzePnbR+lNUx7eJUTcJHCPztFV/Lnoq3amMbhMpYcwslzrOo4SNXcVIuqu
# 9mtG1qo4t9Zhoq0mBy2jJDXAd8pl9jnDLdVp3fC70rWqmWODnFWSeJuCkTCeaOIE
# 6rmSPQ==
# SIG # End signature block
