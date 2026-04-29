<#
.SYNOPSIS
    Admin-triggered git-based update of the ServerSync install with rollback safety.
.DESCRIPTION
    Reads the 'update' section from config.json. Captures a rollback tag, fetches
    and resets the install_root to the configured branch, runs a smoke test, and
    rolls back automatically if the smoke test fails.

    Same NIC enable/verify-disable safety contract as the orchestrator.

    Never runs unless update.enabled is true. Never invoked by the orchestrator
    or scheduled tasks - admin-triggered only.
.PARAMETER ConfigPath
    Path to config.json. Default: ..\config\config.json relative to this script.
.PARAMETER Force
    Skip the interactive confirmation prompt.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ConfigPath,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

if (-not $ConfigPath) {
    $ConfigPath = [IO.Path]::Combine($PSScriptRoot, '..', 'config', 'config.json')
}

# Load modules
$modulesDir = Join-Path $PSScriptRoot 'Modules'
. (Join-Path $modulesDir 'ConfigLoader.ps1')
. (Join-Path $modulesDir 'Logging.ps1')
. (Join-Path $modulesDir 'NetworkControl.ps1')

# Load + validate config
$config = Read-ServerSyncConfig -Path $ConfigPath
$validation = Test-ServerSyncConfig -Config $config
if (-not $validation.Valid) {
    [Console]::Error.WriteLine("Config invalid:")
    foreach ($e in $validation.Errors) { [Console]::Error.WriteLine("  $e") }
    exit 2
}

# Update must be enabled
if (-not $config.PSObject.Properties.Name -contains 'update' -or
    -not $config.update -or
    -not $config.update.enabled) {
    [Console]::Error.WriteLine("update.enabled is not set to true in config. Refusing to run.")
    exit 2
}

$installRoot = $config.update.install_root
$repoUrl     = $config.update.repo_url
$branch      = $config.update.branch
$tagCount    = if ($config.update.backup_tag_count) { [int]$config.update.backup_tag_count } else { 3 }

# install_root must exist and be a git working directory
if (-not (Test-Path -LiteralPath $installRoot -PathType Container)) {
    [Console]::Error.WriteLine("install_root does not exist: $installRoot")
    exit 2
}
$gitDir = Join-Path $installRoot '.git'
if (-not (Test-Path -LiteralPath $gitDir)) {
    [Console]::Error.WriteLine("install_root is not a git working directory: $installRoot")
    [Console]::Error.WriteLine("(no .git folder found)")
    exit 2
}

# Confirm unless -Force
if (-not $Force) {
    Write-Host ""
    Write-Host "About to update ServerSync at: $installRoot"
    Write-Host "  Repo:   $repoUrl"
    Write-Host "  Branch: $branch"
    Write-Host ""
    $answer = Read-Host "Type 'yes' to proceed"
    if ($answer -ne 'yes') {
        Write-Host "Aborted."
        exit 0
    }
}

# Initialize logging
$logger = New-ServerSyncLogger -LogDirectory $config.logging.log_directory `
                                -Prefix 'update' `
                                -EventLogSource $config.logging.event_log_source

Write-ServerSyncLog -Logger $logger -Level 'INFO' -Message "Update starting. install_root=$installRoot branch=$branch"

$nicsEnabled = $false
$rollbackTag = $null
$updateApplied = $false
$prevHead = $null

try {
    # Capture pre-update HEAD for diagnostic logging (independent of tag)
    Push-Location -LiteralPath $installRoot
    try {
        $prevHead = (& git rev-parse HEAD 2>$null).Trim()
        if ($LASTEXITCODE -ne 0 -or -not $prevHead) {
            throw "git rev-parse HEAD failed in $installRoot"
        }
        Write-ServerSyncLog -Logger $logger -Level 'INFO' -Message "Pre-update HEAD: $prevHead"
    } finally {
        Pop-Location
    }

    # Enable NICs
    if ($PSCmdlet.ShouldProcess('NICs', "Enable $($config.network.nics -join ', ')")) {
        Enable-ServerSyncNics -Names $config.network.nics
        $nicsEnabled = $true
        Write-ServerSyncLog -Logger $logger -Level 'INFO' -Message "NICs enabled"

        if (-not (Wait-NetworkReady -TargetHost $config.network.ready_check_host -TimeoutSeconds $config.network.ready_timeout_seconds)) {
            throw "Network not ready after $($config.network.ready_timeout_seconds)s (host: $($config.network.ready_check_host))"
        }
        Write-ServerSyncLog -Logger $logger -Level 'INFO' -Message "Network ready"
    }

    Push-Location -LiteralPath $installRoot
    try {
        # Rollback point
        $rollbackTag = "serversync-pre-update-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        & git tag --force $rollbackTag $prevHead 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "git tag failed" }
        Write-ServerSyncLog -Logger $logger -Level 'INFO' -Message "Rollback tag created: $rollbackTag"

        # Update remote URL (handles repo URL changes)
        & git remote set-url origin $repoUrl 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "git remote set-url failed" }

        # Fetch + reset
        & git fetch origin --tags --prune 2>&1 | ForEach-Object {
            Write-ServerSyncLog -Logger $logger -Level 'INFO' -Message "  git: $_"
        }
        if ($LASTEXITCODE -ne 0) { throw "git fetch failed" }

        & git checkout $branch 2>&1 | ForEach-Object {
            Write-ServerSyncLog -Logger $logger -Level 'INFO' -Message "  git: $_"
        }
        if ($LASTEXITCODE -ne 0) { throw "git checkout $branch failed" }

        & git reset --hard "origin/$branch" 2>&1 | ForEach-Object {
            Write-ServerSyncLog -Logger $logger -Level 'INFO' -Message "  git: $_"
        }
        if ($LASTEXITCODE -ne 0) { throw "git reset --hard origin/$branch failed" }

        $newHead = (& git rev-parse HEAD).Trim()
        Write-ServerSyncLog -Logger $logger -Level 'INFO' -Message "Post-update HEAD: $newHead"
        $updateApplied = ($newHead -ne $prevHead)
        if (-not $updateApplied) {
            Write-ServerSyncLog -Logger $logger -Level 'INFO' -Message "No change - already at latest commit"
        }

        # Rotate old rollback tags (keep newest $tagCount including the new one)
        $allTags = & git tag --list 'serversync-pre-update-*' | Sort-Object -Descending
        if ($allTags.Count -gt $tagCount) {
            $toDelete = $allTags | Select-Object -Skip $tagCount
            foreach ($t in $toDelete) {
                & git tag -d $t 2>&1 | Out-Null
                Write-ServerSyncLog -Logger $logger -Level 'INFO' -Message "Pruned old rollback tag: $t"
            }
        }
    } finally {
        Pop-Location
    }
}
catch {
    Write-ServerSyncLog -Logger $logger -Level 'ERROR' -Message "FATAL during update: $($_.Exception.Message)" -AlsoEventLog
    # NICs disabled in finally below; rollback handled below if $updateApplied
    $script:fatalError = $_.Exception.Message
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

        $allDown = $true
        if (-not $WhatIfPreference) {
            $allDown = Test-AllNicsDisabled -Names $config.network.nics
        }
        if (-not $allDown) {
            Write-ServerSyncLog -Logger $logger -Level 'ERROR' -Message 'CRITICAL: NIC disable could not be verified after update' -AlsoEventLog
            try {
                $smtpCred = $null
                if ($config.email.enabled -and $config.email.credential_target) {
                    $smtpCred = Get-ServerSyncCredential -TargetName $config.email.credential_target
                }
                Send-ServerSyncEmail -Config $config.email `
                    -Subject '[URGENT] ServerSync Update: NIC DISABLE VERIFICATION FAILED' `
                    -Body "Host: $env:COMPUTERNAME`nNICs may still be active after update. Investigate immediately." `
                    -Credential $smtpCred -HasFailures $true
            } catch {
                Write-ServerSyncLog -Logger $logger -Level 'ERROR' -Message "Urgent email send failed: $($_.Exception.Message)"
            }
            exit 3
        }
        Write-ServerSyncLog -Logger $logger -Level 'INFO' -Message 'NICs verified disabled'
    }
}

# If a fatal error happened during the update phase, we have not yet
# applied any new code (or we partially applied it). Best effort: roll
# back if a tag was created and an update was applied.
if ($script:fatalError) {
    if ($updateApplied -and $rollbackTag -and $prevHead) {
        Write-ServerSyncLog -Logger $logger -Level 'WARN' -Message "Attempting rollback to $prevHead due to fatal error"
        Push-Location -LiteralPath $installRoot
        try {
            & git reset --hard $prevHead 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Write-ServerSyncLog -Logger $logger -Level 'INFO' -Message "Rollback complete"
                exit 4
            }
            else {
                Write-ServerSyncLog -Logger $logger -Level 'ERROR' -Message "Rollback FAILED - install state unknown" -AlsoEventLog
                exit 5
            }
        } finally {
            Pop-Location
        }
    }
    exit 4
}

# Smoke test the new install
$smokeScript = Join-Path $installRoot 'src\Start-ServerSync.ps1'
if (-not (Test-Path -LiteralPath $smokeScript)) {
    Write-ServerSyncLog -Logger $logger -Level 'ERROR' -Message "Smoke test script not found post-update: $smokeScript" -AlsoEventLog
    # Roll back
    Push-Location -LiteralPath $installRoot
    try {
        & git reset --hard $prevHead 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-ServerSyncLog -Logger $logger -Level 'INFO' -Message "Rollback complete"
            exit 4
        } else {
            exit 5
        }
    } finally { Pop-Location }
}

Write-ServerSyncLog -Logger $logger -Level 'INFO' -Message "Running smoke test: -ValidateConfig"
& powershell -NoProfile -File $smokeScript -ValidateConfig -ConfigPath $ConfigPath 2>&1 |
    ForEach-Object { Write-ServerSyncLog -Logger $logger -Level 'INFO' -Message "  smoke: $_" }
$smokeExit = $LASTEXITCODE

if ($smokeExit -ne 0) {
    Write-ServerSyncLog -Logger $logger -Level 'ERROR' -Message "Smoke test FAILED (exit $smokeExit). Rolling back to $prevHead." -AlsoEventLog

    Push-Location -LiteralPath $installRoot
    $rollbackOk = $false
    try {
        & git reset --hard $prevHead 2>&1 | Out-Null
        $rollbackOk = ($LASTEXITCODE -eq 0)
    } finally {
        Pop-Location
    }

    # Send urgent email
    try {
        $smtpCred = $null
        if ($config.email.enabled -and $config.email.credential_target) {
            $smtpCred = Get-ServerSyncCredential -TargetName $config.email.credential_target
        }
        $bodyStatus = if ($rollbackOk) { 'rolled back to ' + $prevHead } else { 'ROLLBACK ALSO FAILED - install state unknown' }
        Send-ServerSyncEmail -Config $config.email `
            -Subject "[ServerSync] Update failed smoke test on $env:COMPUTERNAME" `
            -Body "Update from $repoUrl branch $branch failed smoke test (exit $smokeExit). $bodyStatus.`nSee log: $($logger.LogPath)" `
            -Credential $smtpCred -HasFailures $true
    } catch {
        Write-ServerSyncLog -Logger $logger -Level 'WARN' -Message "Email send failed: $($_.Exception.Message)"
    }

    if ($rollbackOk) {
        Write-ServerSyncLog -Logger $logger -Level 'INFO' -Message "Rollback complete - exit 4"
        exit 4
    }
    else {
        Write-ServerSyncLog -Logger $logger -Level 'ERROR' -Message "Rollback FAILED - exit 5" -AlsoEventLog
        exit 5
    }
}

Write-ServerSyncLog -Logger $logger -Level 'INFO' -Message "Smoke test passed"

# Optional summary email
try {
    if ($config.email.enabled) {
        $smtpCred = $null
        if ($config.email.credential_target) {
            $smtpCred = Get-ServerSyncCredential -TargetName $config.email.credential_target
        }
        Send-ServerSyncEmail -Config $config.email `
            -Subject "[ServerSync] Update applied successfully on $env:COMPUTERNAME" `
            -Body "Update from $repoUrl branch $branch applied successfully.`nPrevious: $prevHead`nSee log: $($logger.LogPath)" `
            -Credential $smtpCred -HasFailures $false
    }
} catch {
    Write-ServerSyncLog -Logger $logger -Level 'WARN' -Message "Email send failed: $($_.Exception.Message)"
}

Write-ServerSyncLog -Logger $logger -Level 'INFO' -Message "Update complete - exit 0"
exit 0
