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
        if (-not $Config.network.nics -or $Config.network.nics.Count -eq 0) {
            $errors.Add("network.nics must be a non-empty array")
        }
        if (-not $Config.network.ready_check_host) {
            $errors.Add("network.ready_check_host is required")
        }
    }

    if ($Config.retention) {
        if ($Config.retention.default_mode -and
            @('files','folders') -notcontains $Config.retention.default_mode) {
            $errors.Add("retention.default_mode must be 'files' or 'folders'")
        }
        if ($Config.retention.default_count -lt 1) {
            $errors.Add("retention.default_count must be >= 1")
        }
    }

    if ($Config.email -and $Config.email.enabled -and
        @('failure','always','never') -notcontains $Config.email.send_on) {
        $errors.Add("email.send_on must be 'failure', 'always', or 'never'")
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

            if ($pair.retention) {
                if ($pair.retention.mode -and @('files','folders') -notcontains $pair.retention.mode) {
                    $errors.Add("pair '$n' retention.mode must be 'files' or 'folders'")
                }
                if ($pair.retention.count -and $pair.retention.count -lt 1) {
                    $errors.Add("pair '$n' retention.count must be >= 1")
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

    $count = if ($pairRetention -and $pairRetention.count) { $pairRetention.count }
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
