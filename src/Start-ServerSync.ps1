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

        if (-not (Wait-NetworkReady -TargetHost $config.network.ready_check_host -TimeoutSeconds $config.network.ready_timeout_seconds)) {
            throw "Network not ready after $($config.network.ready_timeout_seconds)s (host: $($config.network.ready_check_host))"
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
