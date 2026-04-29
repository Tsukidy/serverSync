<#
.SYNOPSIS
    Logging primitives: file logger, Windows Event Log writer, SMTP email.
#>

function New-ServerSyncLogger {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$LogDirectory,
        [string]$Prefix = 'serversync',
        [string]$EventLogSource
    )

    if (-not (Test-Path -LiteralPath $LogDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
        # Lock the new directory down. The caller may have pointed log_directory
        # somewhere unexpected; inheriting the parent's ACLs (often Users:Read on
        # C:\) would leak operational data. We grant full control to
        # BUILTIN\Administrators, NT AUTHORITY\SYSTEM, and the current user only,
        # and disable inheritance. This only runs the FIRST time the directory is
        # created - existing directories are not modified.
        if ($IsWindows -or [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
            try {
                $acl = New-Object System.Security.AccessControl.DirectorySecurity
                $acl.SetAccessRuleProtection($true, $false)
                $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name
                foreach ($ident in @('BUILTIN\Administrators', 'NT AUTHORITY\SYSTEM', $currentUser)) {
                    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                        $ident, 'FullControl',
                        ([System.Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit'),
                        'None', 'Allow')
                    $acl.AddAccessRule($rule)
                }
                Set-Acl -LiteralPath $LogDirectory -AclObject $acl -ErrorAction Stop
            }
            catch {
                # Non-fatal but write the failure to a temp marker so it's
                # discoverable. We do not have a logger yet here.
                $marker = Join-Path $LogDirectory '.acl-warning.txt'
                Set-Content -LiteralPath $marker -Value "Failed to apply ACL on first creation: $($_.Exception.Message)" -ErrorAction SilentlyContinue
            }
        }
    }

    $date = (Get-Date).ToString('yyyy-MM-dd')
    $logPath = Join-Path $LogDirectory "$Prefix-$date.log"

    return [PSCustomObject]@{
        LogPath        = $logPath
        EventLogSource = $EventLogSource
    }
}

function ConvertTo-LogSafeText {
    <#
    .SYNOPSIS
        Escape characters that would let attacker-controlled values forge
        new log lines or break line-oriented log parsers.
    .DESCRIPTION
        CR and LF are replaced with literal '\r' and '\n' sequences. A NUL
        byte is replaced with '\0'. Anything else is passed through.

        This is single-message-per-line defense. Aggregators that key on
        regex like '^[\d-]+T[\d:]+(?:Z|[+-]\d{2}:\d{2}) \[(?:INFO|WARN|...)\] '
        will no longer match injected fakes from inside a message body.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text
    )
    return $Text -replace "`r", '\r' -replace "`n", '\n' -replace "`0", '\0'
}

function Write-ServerSyncLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][Object]$Logger,
        [Parameter(Mandatory)][ValidateSet('INFO','WARN','ERROR','DEBUG')][string]$Level,
        [Parameter(Mandatory)][string]$Message,
        [switch]$AlsoEventLog
    )

    $safeMessage = ConvertTo-LogSafeText -Text $Message
    $ts = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK')
    $line = "$ts [$Level] $safeMessage"
    Add-Content -Path $Logger.LogPath -Value $line -Encoding UTF8

    if ($AlsoEventLog -and $Logger.EventLogSource) {
        $eventType = switch ($Level) {
            'ERROR' { 'Error' }
            'WARN'  { 'Warning' }
            default { 'Information' }
        }
        try {
            Write-EventLog -LogName 'Application' -Source $Logger.EventLogSource `
                           -EventId 1000 -EntryType $eventType -Message $safeMessage -ErrorAction Stop
        }
        catch {
            # Event Log may not be available (non-Windows or source not registered) -- degrade silently.
            # The exception message is itself sanitized to prevent it being a re-injection vector.
            $safeErr = ConvertTo-LogSafeText -Text $_.Exception.Message
            Add-Content -Path $Logger.LogPath -Value "$ts [WARN] Event Log write failed: $safeErr" -Encoding UTF8
        }
    }
}

function Remove-OldLogFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$LogDirectory,
        [Parameter(Mandatory)][int]$RetentionDays
    )
    if (-not (Test-Path -LiteralPath $LogDirectory -PathType Container)) { return }
    $cutoff = (Get-Date).AddDays(-$RetentionDays)
    # Filter to *.log specifically. The log directory used to be assumed
    # log-only, but admins occasionally drop other artifacts there
    # (state.json, lastrun.txt, forensic captures). Refusing to touch
    # non-log files is safer.
    Get-ChildItem -LiteralPath $LogDirectory -File -Filter '*.log' |
        Where-Object { $_.LastWriteTime -lt $cutoff } |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force }
}

function Get-LogTail {
    <#
    .SYNOPSIS
        Read the tail of a log file safely with a hard size cap, for use
        in email bodies. Avoids attaching unbounded log content to
        outbound mail.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$MaxLines = 200,
        [int]$MaxBytes = 64KB
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    $info = Get-Item -LiteralPath $Path
    if ($info.Length -le $MaxBytes) {
        $lines = Get-Content -LiteralPath $Path -Tail $MaxLines
    }
    else {
        # File is large - read just the tail bytes.
        $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try {
            $start = [Math]::Max(0, $fs.Length - $MaxBytes)
            $fs.Seek($start, [IO.SeekOrigin]::Begin) | Out-Null
            $reader = New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8)
            $tailContent = $reader.ReadToEnd()
            $lines = $tailContent -split "`r?`n" | Select-Object -Last $MaxLines
        }
        finally {
            $fs.Dispose()
        }
    }
    $header = "(showing last $($lines.Count) line(s) of $($info.FullName); file size $($info.Length) bytes)"
    return ($header, '') + $lines -join [Environment]::NewLine
}

function Test-ShouldSendEmail {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('failure','always','never')][string]$SendOn,
        [Parameter(Mandatory)][bool]$HasFailures
    )
    switch ($SendOn) {
        'always'  { return $true }
        'failure' { return $HasFailures }
        'never'   { return $false }
    }
}

function Send-ServerSyncEmail {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][Object]$Config,
        [Parameter(Mandatory)][string]$Subject,
        [Parameter(Mandatory)][string]$Body,
        [PSCredential]$Credential,
        [bool]$HasFailures = $false
    )

    if (-not $Config.enabled) { return }
    if (-not (Test-ShouldSendEmail -SendOn $Config.send_on -HasFailures $HasFailures)) { return }

    $mailParams = @{
        SmtpServer = $Config.smtp_server
        Port       = $Config.smtp_port
        From       = $Config.from
        To         = $Config.to
        Subject    = $Subject
        Body       = $Body
        UseSsl     = [bool]$Config.use_ssl
    }
    if ($Credential) { $mailParams['Credential'] = $Credential }

    # Send-MailMessage is deprecated but still the best built-in option for Windows PowerShell
    # compatibility. On PS7, it still works. Mocked in tests.
    Send-MailMessage @mailParams -ErrorAction Stop
}
# SIG # Begin signature block
# MIIcIAYJKoZIhvcNAQcCoIIcETCCHA0CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDaHHupoWGQNUPz
# 6dWDUjK4Z9xsD4gKFKrPEpXtmhwUY6CCFl4wggMgMIICCKADAgECAhAujyLP3LJ6
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
# AYI3AgELMQ4wDAYKKwYBBAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgCq8fNwF5GjM2
# C33izS6mOkU2cC75r0pTLndD51eU+UcwDQYJKoZIhvcNAQEBBQAEggEAlnUJ3Utq
# g8cZpoYhuW9Ip/5T/No+VTE0c/Ib+GV9JGyjt6ihJMt4OmqHLIOFXBxrd/jkkpyL
# 2G3Ws+/5ct06wlVf8S6FlpcTPs4TvpD4G9Nd6kewTzbYKF8D2KpJthiqchRpySvO
# ynL/Xdqr/16MCI7pr6pec2GzZtPVTpuZ9oVK8H+4Y54Ga90jYoLY9Tl1nAL2RYsz
# QoAlLXM2RdpeztKRz55lAwSHL796/EQiobSCObjHA0L2+5/G8009+zStMiz1HFXi
# xtFDzg9yg84TBdiCWeBp9Gd78HMffKpdKTgrewfMAr4wx0slkTWxSY3g4Rudw2C5
# bmjxQ69wa06LjKGCAyYwggMiBgkqhkiG9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJ
# BgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGln
# aUNlcnQgVHJ1c3RlZCBHNCBUaW1lU3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAy
# NSBDQTECEAqA7xhLjfEFgtHEdqeVdGgwDQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG
# 9w0BCQMxCwYJKoZIhvcNAQcBMBwGCSqGSIb3DQEJBTEPFw0yNjA0MjkyMTQ5NTVa
# MC8GCSqGSIb3DQEJBDEiBCDwDG1+S2P42uwZJiwmolTsm85l7I6H+V6qJFG97z8w
# GTANBgkqhkiG9w0BAQEFAASCAgA1kES4v0DL9KG75bRZriGZkuXdDLP6BkYnPhf8
# VWbMIlkOLr3bjMcky8PCSvPxOr8T8gI+mG2IYoN2b+0FN5/WmRR/4mrgcjBNNdvY
# Lrpni/aVsMmraBAFrzguW0ST475xb9QHbzUYrvPYlF9VCAysh04El9K3+7Iqba7H
# HhlKDs0jJnc6ekIEk6pYnTtx17PliiTJ/qCAcQNykASgLfWEbCRih/4REUEUx0Aq
# v8mtbZYY/nk+HafYyK37tEnlThHf+tp0NVcJBPsvOjhqC89kNjCnqoFZAgPNLich
# tKnoQ2x39FCN62QxHEGRwlPRHYAbyankRMoeEWok6CExj5NXolOJhZYb81LkeLcn
# RQYDjRyZsu+H3WiVNG/fT6wF96C6HwqV5e2bsEenkvtafpccwWRxv71NFuhDAxU3
# nbT2JX2UvFjzPWFBbxbO7ZXFKpxGi60LUMU/yKyxPRzkxyqQ/qBUVoPzxvVNElKw
# JBqg4w0LhzDZYNL7mdWJ1K68BAh6Qk7YFVho5tcMLPNU6rHxJCiQHoOvwrYRURXJ
# OQFqz9foIkCiTyysodMjnaDqBVp0/TvRtfZFFIVnX018tPReeQr9Wv59v8Y94LUz
# S8SJKUXyeQl28Ehn50WFvZ4gS9V68zpfp5Qd8/5n0FYQZMOLSfa+syR3xwbpwJj1
# Qm+x4Q==
# SIG # End signature block
