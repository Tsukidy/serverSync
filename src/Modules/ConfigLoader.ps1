<#
.SYNOPSIS
    Load and validate ServerSync config files.
#>

function Read-ServerSyncConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -Path $Path -PathType Leaf)) {
        throw "Config file not found: $Path"
    }

    $raw = Get-Content -Path $Path -Raw -Encoding UTF8
    try {
        $config = $raw | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "Config file is not valid JSON: $Path. $($_.Exception.Message)"
    }

    return $config
}

function Test-ServerSyncConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [Object]$Config
    )

    $errors = New-Object System.Collections.Generic.List[string]

    # Top-level sections
    foreach ($section in @('network','robocopy','retention','logging','email','folder_pairs')) {
        if (-not ($Config.PSObject.Properties.Name -contains $section)) {
            $errors.Add("Missing required section: $section")
        }
    }

    if ($Config.network) {
        # nics must be a non-empty array of strings, NOT a bare string. PowerShell
        # promotes [string[]] from a string, but we want explicit arrays in
        # config to avoid surprises and to make typos visible.
        if (-not ($Config.network.nics -is [Array])) {
            $errors.Add("network.nics must be an array (e.g., [`"Ethernet`"]) - bare strings not accepted")
        }
        elseif ($Config.network.nics.Count -eq 0) {
            $errors.Add("network.nics must be a non-empty array")
        }
        else {
            foreach ($n in $Config.network.nics) {
                if ([string]::IsNullOrWhiteSpace($n)) {
                    $errors.Add("network.nics contains an empty/whitespace entry")
                }
            }
        }
        if (-not $Config.network.ready_check_host) {
            $errors.Add("network.ready_check_host is required")
        }
        # ready_check_port is optional. If present must be a valid TCP port.
        if ($null -ne $Config.network.ready_check_port) {
            $p = $Config.network.ready_check_port
            if ($p -lt 1 -or $p -gt 65535) {
                $errors.Add("network.ready_check_port must be 1-65535")
            }
        }
    }

    if ($Config.retention) {
        # default_mode is required so Resolve-RetentionPolicy never returns Mode=null.
        if (-not $Config.retention.default_mode) {
            $errors.Add("retention.default_mode is required ('files', 'folders', or 'mirror')")
        }
        elseif (@('files','folders','mirror') -notcontains $Config.retention.default_mode) {
            $errors.Add("retention.default_mode must be 'files', 'folders', or 'mirror'")
        }
        if ($null -ne $Config.retention.default_count -and $Config.retention.default_count -lt 1) {
            $errors.Add("retention.default_count must be >= 1")
        }
    }

    # send_on is validated regardless of whether email.enabled is true, so a
    # config with garbage send_on doesn't silently drift through GUI saves
    # only to fail when enabled is later flipped.
    if ($Config.email -and $Config.email.send_on -and
        @('failure','always','never') -notcontains $Config.email.send_on) {
        $errors.Add("email.send_on must be 'failure', 'always', or 'never'")
    }
    if ($Config.email -and $Config.email.enabled) {
        # to must be a non-empty array of email-like strings
        if (-not $Config.email.to) {
            $errors.Add("email.to is required when email.enabled is true")
        }
        else {
            $toList = @($Config.email.to)
            if ($toList.Count -eq 0) {
                $errors.Add("email.to must be a non-empty array when email.enabled is true")
            }
            foreach ($addr in $toList) {
                if (-not $addr -or $addr -notmatch '^[^\s@]+@[^\s@]+\.[^\s@]+$') {
                    $errors.Add("email.to contains an invalid address: '$addr'")
                }
            }
        }
        if (-not $Config.email.smtp_server -or $Config.email.smtp_server -match '\s') {
            $errors.Add("email.smtp_server is required and must not contain whitespace when email.enabled is true")
        }
    }

    # Validate robocopy.extra_flags against the allowlist if available.
    # Test-RobocopyFlag is defined in SyncOperations.ps1 - if SyncOperations
    # is not loaded (e.g. ConfigLoader-only test fixtures), this check is
    # skipped. The orchestrator and Update-ServerSync load both modules, so
    # production paths always validate.
    if ($Config.robocopy -and $Config.robocopy.extra_flags) {
        if (Get-Command -Name Test-RobocopyFlag -ErrorAction SilentlyContinue) {
            foreach ($flag in @($Config.robocopy.extra_flags)) {
                if (-not (Test-RobocopyFlag -Flag $flag)) {
                    $errors.Add("robocopy.extra_flags contains disallowed flag: '$flag' (see SyncOperations.ps1 for the allowlist)")
                }
            }
        }
    }

    # Update section is optional; only validate fields if present
    if ($Config.PSObject.Properties.Name -contains 'update' -and $null -ne $Config.update) {
        if ($Config.update.enabled) {
            if (-not $Config.update.repo_url) {
                $errors.Add("update.repo_url is required when update.enabled is true")
            }
            elseif ($Config.update.repo_url -notmatch '^[A-Za-z][A-Za-z0-9+.-]*://' -and
                    $Config.update.repo_url -notmatch '^git@') {
                $errors.Add("update.repo_url must be a URL (https://...) or SSH form (git@...)")
            }
            if (-not $Config.update.branch) {
                $errors.Add("update.branch is required when update.enabled is true")
            }
            elseif ($Config.update.branch -match '\s') {
                $errors.Add("update.branch must not contain whitespace")
            }
            if (-not $Config.update.install_root) {
                $errors.Add("update.install_root is required when update.enabled is true")
            }
            if ($Config.update.backup_tag_count -and $Config.update.backup_tag_count -lt 1) {
                $errors.Add("update.backup_tag_count must be >= 1")
            }
            # If allowed_repos is present (whitelist mode), it must be a non-empty
            # array and the configured repo_url must be exactly one of those.
            # Defends against a config-write-to-malicious-upstream supply-chain
            # attack on Update-ServerSync.
            if ($Config.update.PSObject.Properties.Name -contains 'allowed_repos' -and
                $null -ne $Config.update.allowed_repos) {
                $allowed = @($Config.update.allowed_repos)
                if ($allowed.Count -eq 0) {
                    $errors.Add("update.allowed_repos, if present, must be a non-empty array")
                }
                foreach ($r in $allowed) {
                    if (-not $r -or
                        ($r -notmatch '^[A-Za-z][A-Za-z0-9+.-]*://' -and $r -notmatch '^git@')) {
                        $errors.Add("update.allowed_repos contains a non-URL entry: '$r'")
                    }
                }
                if ($Config.update.repo_url -and $allowed.Count -gt 0 -and
                    $allowed -notcontains $Config.update.repo_url) {
                    $errors.Add("update.repo_url '$($Config.update.repo_url)' is not in update.allowed_repos")
                }
            }
        }
    }

    if ($Config.folder_pairs) {
        $names = @{}
        foreach ($pair in $Config.folder_pairs) {
            $n = $pair.name
            if (-not $n) { $errors.Add("folder_pair missing 'name'"); continue }
            if ($names.ContainsKey($n)) { $errors.Add("duplicate folder_pair name: '$n'") }
            $names[$n] = $true

            foreach ($required in @('source','destination','credential_target')) {
                if (-not $pair.$required) {
                    $errors.Add("pair '$n' missing '$required'")
                }
            }

            # Shape-validate source: UNC path \\server\share\... or local
            # absolute path C:\... - reject wildcards and parent-traversal.
            if ($pair.source) {
                if ($pair.source -match '[\*\?<>\|"]') {
                    $errors.Add("pair '$n' source contains wildcard or invalid path char: '$($pair.source)'")
                }
                elseif ($pair.source -match '(^|[\\/])\.\.([\\/]|$)') {
                    $errors.Add("pair '$n' source contains parent-traversal '..': '$($pair.source)'")
                }
                elseif ($pair.source -notmatch '^(\\\\[^\\]+\\.+|[A-Za-z]:\\.+)') {
                    $errors.Add("pair '$n' source must be a UNC path (\\\\server\\share\\...) or a drive-letter path (C:\\...)")
                }
            }

            # Shape-validate destination: drive-letter local path only. Reject
            # UNC (writes to remote shares cross the air gap), wildcards, parent-traversal.
            if ($pair.destination) {
                if ($pair.destination -match '[\*\?<>\|"]') {
                    $errors.Add("pair '$n' destination contains wildcard or invalid path char: '$($pair.destination)'")
                }
                elseif ($pair.destination -match '(^|[\\/])\.\.([\\/]|$)') {
                    $errors.Add("pair '$n' destination contains parent-traversal '..': '$($pair.destination)'")
                }
                elseif ($pair.destination -notmatch '^[A-Za-z]:\\') {
                    $errors.Add("pair '$n' destination must be a local drive-letter path (e.g., D:\\AirgappedBackups\\X)")
                }
            }

            # credential_target shape - simple ASCII identifier.
            if ($pair.credential_target -and $pair.credential_target -notmatch '^[A-Za-z0-9_.\-]{1,64}$') {
                $errors.Add("pair '$n' credential_target must be alphanumeric/_/-/./, max 64 chars")
            }

            # Tags shape - alphanumeric, dot, dash, underscore only.
            if ($pair.tags) {
                foreach ($t in @($pair.tags)) {
                    if ($t -notmatch '^[A-Za-z0-9_.\-]{1,40}$') {
                        $errors.Add("pair '$n' tag '$t' contains invalid characters or is too long (allowed: A-Z a-z 0-9 _ . - max 40)")
                    }
                }
            }

            if ($pair.retention) {
                if ($pair.retention.mode -and @('files','folders','mirror') -notcontains $pair.retention.mode) {
                    $errors.Add("pair '$n' retention.mode must be 'files', 'folders', or 'mirror'")
                }
                # Use $null -ne instead of truthiness so count: 0 is properly
                # rejected (truthiness check on 0 short-circuits).
                if ($null -ne $pair.retention.count -and $pair.retention.count -lt 1) {
                    $errors.Add("pair '$n' retention.count must be >= 1")
                }
                if ($pair.retention.extensions) {
                    foreach ($ext in @($pair.retention.extensions)) {
                        if ($ext -notmatch '^\.?[A-Za-z0-9]{1,16}$') {
                            $errors.Add("pair '$n' retention.extensions contains invalid extension: '$ext'")
                        }
                    }
                }
            }
        }
    }

    return [PSCustomObject]@{
        Valid  = ($errors.Count -eq 0)
        Errors = $errors.ToArray()
    }
}

function Select-ServerSyncPairs {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [Object[]]$Pairs,

        [string]$Tag
    )

    $results = foreach ($pair in $Pairs) {
        $tags = @()
        if ($pair.PSObject.Properties.Name -contains 'tags' -and $null -ne $pair.tags) {
            $tags = @($pair.tags)
        }
        if ($tags.Count -eq 0) { continue }  # no tags means disabled

        if ($Tag) {
            if ($tags -contains $Tag) { $pair }
        }
        else {
            if ($tags -contains 'default') { $pair }
        }
    }
    # Ensure we always return an array, even for 0 or 1 matches
    return ,@($results)
}

function Resolve-RetentionPolicy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [Object]$Pair,

        [Parameter(Mandatory)]
        [Object]$Defaults
    )

    $pairRetention = $null
    if ($Pair.PSObject.Properties.Name -contains 'retention' -and $null -ne $Pair.retention) {
        $pairRetention = $Pair.retention
    }

    $mode = if ($pairRetention -and $pairRetention.mode) { $pairRetention.mode }
            else { $Defaults.default_mode }

    # Use $null -ne checks so count: 0 is preserved as user intent (validator
    # already rejects count < 1, so 0 cannot reach here in production - but
    # the explicit null-check is the right pattern for falsy-zero values).
    $count = if ($pairRetention -and $null -ne $pairRetention.count) { $pairRetention.count }
             else { $Defaults.default_count }

    $extensions = @()
    if ($mode -eq 'files') {
        if ($pairRetention -and $pairRetention.extensions) {
            $extensions = @($pairRetention.extensions)
        }
        else {
            $extensions = @($Defaults.default_extensions)
        }
    }

    return [PSCustomObject]@{
        Mode       = $mode
        Count      = $count
        Extensions = $extensions
    }
}

function Get-ServerSyncCredential {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TargetName
    )

    # On Windows, use the CredentialManager module (install: Install-Module CredentialManager -Scope AllUsers)
    # Offline install: extract the module to $env:PSModulePath on the air-gapped server.
    if (-not (Get-Command Get-StoredCredential -ErrorAction SilentlyContinue)) {
        throw "CredentialManager module not available. Install it (Install-Module CredentialManager) or copy it to PSModulePath."
    }

    $cred = Get-StoredCredential -Target $TargetName
    if (-not $cred) {
        throw "Credential not found in Credential Manager: $TargetName"
    }
    return $cred
}
# SIG # Begin signature block
# MIIcIAYJKoZIhvcNAQcCoIIcETCCHA0CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDb329Ta4pV7Dm7
# tp7EqgSG6yAU7X4zviraLLaLJagvWKCCFl4wggMgMIICCKADAgECAhAujyLP3LJ6
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
# AYI3AgELMQ4wDAYKKwYBBAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQg1F9xvyjvucSb
# BTPLiSEcmalU9Sndj6oGrug0zBsxzyIwDQYJKoZIhvcNAQEBBQAEggEAfHlOYjgy
# wbIVf41W/z0FyWvgMz5ZSBUL61HRrBR0aOsZ0ft2HFj+80/zlsCIFIqQDBrwi/VF
# 1hL7ADFnQ3UxAOwm5ziblRZ6fYIi6zug4KPnjcLMBp+1pMmlLxMKCRojEp31Smut
# u5bTDuYW9bSjd1hrk2Si5yzmc+pLwnIwtUYfGlJPtRX4zIhwdeNfszAQd+QzXgbn
# yamPWniBghu414pp7lUWJzRCLcApwAZer24X0miTSNgYR9ufvVPNA4WMGaUw2ySv
# 9qoozO0a24gpglCouXnhNkQGgynib8HGpa0bvxpnOuVFcbcQ0fMrXrxuhsZg689k
# dKYi0JfxflFgAKGCAyYwggMiBgkqhkiG9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJ
# BgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGln
# aUNlcnQgVHJ1c3RlZCBHNCBUaW1lU3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAy
# NSBDQTECEAqA7xhLjfEFgtHEdqeVdGgwDQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG
# 9w0BCQMxCwYJKoZIhvcNAQcBMBwGCSqGSIb3DQEJBTEPFw0yNjA0MjkyMTQ5NTRa
# MC8GCSqGSIb3DQEJBDEiBCD1yIj1rQrEwTDZapf782HD7xus4ODyrApZ9SlnG+hS
# 4zANBgkqhkiG9w0BAQEFAASCAgBCgwEG8wWd/JvHrsEvqTpj5ItD4GKoN0HJrOb0
# j59RwuOpjGEoSb5J0BLCdKmGXgPiqPgadYW5FvWI2G0kld7kth4iqisqabJkMdZw
# XMeRCukmnvc3ylIJfgULMgFjP1JOxWVffnsITp5dfYFbepZZ4YUbJdYbeN8GAU+J
# U6nEFl9m11wiGXwMq+am9PfhWW3Fjs0MrPf9Xh7s0/zr6ApigAsmetq0ct2rOA+m
# slkGMcGDSGbyAQfyQi3aMYnwW66uLwTZ1sgMMI7F7nov2MPc2Z0wI4ZzZby6YLXM
# DhSpsgKJp8fpL0+YpNVk6llJFZqLRl96F2RO7JLLPPgg5unH4nxStTNOK92WABN5
# FykyvriXKxpUqfPkcc0rTzPq179c4Z4SCdSw4kAd1f8NKb626LP9kE4DXwyu5Pu2
# FJ/0ccdcxnOihv18cNJZCsZI3zKCI2/WZUWyNT2fsS0qw7n8NrdPQbO9Qe2QpCiz
# 9jWMLxYO5utbSyYSw1igKuomgQNs0BCGCcrUbzNKJb1o5GabVc6gTCziX+94naEW
# pzhKyt4j/nv7vSq7h+JbEP/S7SP0Vs+2bL1jJx4SKmE5tVXnh+zCK8PuN/mq2tHP
# XYHpxU/uTfvQBrEHjORBWxSVjcHkVRv2KJEtIpijopBt1t0gvV7P1QKoMEp3RKQT
# +UB9Cw==
# SIG # End signature block
