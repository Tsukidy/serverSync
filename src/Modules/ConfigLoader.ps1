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
