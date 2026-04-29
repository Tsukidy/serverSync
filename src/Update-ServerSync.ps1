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

# Resolve trusted absolute paths to git and powershell BEFORE doing anything
# else. Looking these up via $PATH is a supply-chain risk: an attacker who
# can drop a same-named binary earlier in PATH (e.g., into a user-writable
# Chocolatey/scoop directory) would intercept every git/powershell call we
# make, defeating the rollback contract.
function Resolve-TrustedExecutable {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string[]]$AcceptedRoots
    )
    $cmd = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue
    if (-not $cmd) {
        throw "$Name not found on PATH"
    }
    $resolved = $cmd | Select-Object -First 1 -ExpandProperty Source
    foreach ($root in $AcceptedRoots) {
        if ($resolved.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
            return $resolved
        }
    }
    throw "$Name resolved to an untrusted path: $resolved (must be under one of: $($AcceptedRoots -join '; '))"
}

$gitExe        = Resolve-TrustedExecutable -Name 'git' -AcceptedRoots @(
    "${env:ProgramFiles}\Git\",
    "${env:ProgramFiles(x86)}\Git\",
    "${env:ProgramW6432}\Git\"
)
# powershell.exe and pwsh.exe both have stable absolute homes; do NOT trust PATH.
$psExe = if (Test-Path -LiteralPath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe") {
    "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
}
elseif (Test-Path -LiteralPath "$env:ProgramFiles\PowerShell\7\pwsh.exe") {
    "$env:ProgramFiles\PowerShell\7\pwsh.exe"
}
else {
    throw "No trusted PowerShell executable found at the expected absolute paths."
}

# Load modules
$modulesDir = Join-Path $PSScriptRoot 'Modules'
. (Join-Path $modulesDir 'ConfigLoader.ps1')
. (Join-Path $modulesDir 'Logging.ps1')
. (Join-Path $modulesDir 'NetworkControl.ps1')
. (Join-Path $modulesDir 'SyncOperations.ps1')

# Load + validate config (extra_flags allowlist requires SyncOperations be loaded)
$config = Read-ServerSyncConfig -Path $ConfigPath
$validation = Test-ServerSyncConfig -Config $config
if (-not $validation.Valid) {
    [Console]::Error.WriteLine("Config invalid:")
    foreach ($e in $validation.Errors) { [Console]::Error.WriteLine("  $e") }
    exit 2
}

# Update must be enabled
if (-not ($config.PSObject.Properties.Name -contains 'update') -or
    -not $config.update -or
    -not $config.update.enabled) {
    [Console]::Error.WriteLine("update.enabled is not set to true in config. Refusing to run.")
    exit 2
}

$installRoot = $config.update.install_root
$repoUrl     = $config.update.repo_url
$branch      = $config.update.branch
$tagCount    = if ($config.update.backup_tag_count) { [int]$config.update.backup_tag_count } else { 3 }

# Allowed-repos whitelist: if update.allowed_repos is present, repo_url must
# match one of those exact strings. Defends against config-write-to-malicious-
# upstream supply-chain attack.
if ($config.update.allowed_repos) {
    $allowed = @($config.update.allowed_repos)
    if ($allowed.Count -gt 0 -and $allowed -notcontains $repoUrl) {
        [Console]::Error.WriteLine("update.repo_url '$repoUrl' is not in update.allowed_repos. Refusing to run.")
        exit 2
    }
}

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
Write-ServerSyncLog -Logger $logger -Level 'INFO' -Message "Trusted git: $gitExe"
Write-ServerSyncLog -Logger $logger -Level 'INFO' -Message "Trusted ps:  $psExe"

$nicsEnabled = $false
$rollbackTag = $null
$updateApplied = $false
$prevHead = $null
$newHead = $null

try {
    # Capture pre-update HEAD for diagnostic logging (independent of tag)
    Push-Location -LiteralPath $installRoot
    try {
        $prevHead = (& $gitExe rev-parse HEAD 2>$null).Trim()
        if ($LASTEXITCODE -ne 0 -or -not $prevHead) {
            throw "git rev-parse HEAD failed in $installRoot"
        }
        Write-ServerSyncLog -Logger $logger -Level 'INFO' -Message "Pre-update HEAD: $prevHead"
    } finally {
        Pop-Location
    }

    # Enable NICs - set $nicsEnabled FIRST so the finally block always
    # disables and verifies, even if Enable-ServerSyncNics partially
    # succeeds and then throws.
    if ($PSCmdlet.ShouldProcess('NICs', "Enable $($config.network.nics -join ', ')")) {
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

    Push-Location -LiteralPath $installRoot
    try {
        # Rollback point. Append a short GUID so two updates within the same
        # second cannot collide and one cannot clobber the other.
        $tagSuffix = [Guid]::NewGuid().ToString('N').Substring(0,4)
        $rollbackTag = "serversync-pre-update-$(Get-Date -Format 'yyyyMMdd-HHmmss')-$tagSuffix"
        & $gitExe tag $rollbackTag $prevHead 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "git tag failed" }
        Write-ServerSyncLog -Logger $logger -Level 'INFO' -Message "Rollback tag created: $rollbackTag"

        # Update remote URL (handles repo URL changes within the allowlist)
        & $gitExe remote set-url origin $repoUrl 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "git remote set-url failed" }

        # Fetch branches only (NOT tags) - rollback tags are local-only and
        # we don't want a hostile upstream to be able to delete them via
        # --prune semantics.
        & $gitExe fetch origin --prune 2>&1 | ForEach-Object {
            Write-ServerSyncLog -Logger $logger -Level 'INFO' -Message "  git: $_"
        }
        if ($LASTEXITCODE -ne 0) { throw "git fetch failed" }

        & $gitExe checkout $branch 2>&1 | ForEach-Object {
            Write-ServerSyncLog -Logger $logger -Level 'INFO' -Message "  git: $_"
        }
        if ($LASTEXITCODE -ne 0) { throw "git checkout $branch failed" }

        & $gitExe reset --hard "origin/$branch" 2>&1 | ForEach-Object {
            Write-ServerSyncLog -Logger $logger -Level 'INFO' -Message "  git: $_"
        }
        if ($LASTEXITCODE -ne 0) { throw "git reset --hard origin/$branch failed" }

        $newHead = (& $gitExe rev-parse HEAD).Trim()
        Write-ServerSyncLog -Logger $logger -Level 'INFO' -Message "Post-update HEAD: $newHead"
        $updateApplied = ($newHead -ne $prevHead)
        if (-not $updateApplied) {
            Write-ServerSyncLog -Logger $logger -Level 'INFO' -Message "No change - already at latest commit"
        }

        # Rotate old rollback tags (keep newest $tagCount including the new one)
        $allTags = & $gitExe tag --list 'serversync-pre-update-*' | Sort-Object -Descending
        if ($allTags.Count -gt $tagCount) {
            $toDelete = $allTags | Select-Object -Skip $tagCount
            foreach ($t in $toDelete) {
                & $gitExe tag -d $t 2>&1 | Out-Null
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
                $adapterReport = ''
                try {
                    $adapterReport = (Get-NetAdapter | Format-Table Name, Status, InterfaceDescription -AutoSize | Out-String)
                } catch {}
                $tail = Get-LogTail -Path $logger.LogPath -MaxLines 50 -MaxBytes 16KB
                $urgentBody = @(
                    "Host: $env:COMPUTERNAME"
                    "NICs may still be active after update. Investigate IMMEDIATELY."
                    ""
                    "--- Get-NetAdapter ---"
                    $adapterReport
                    "--- log tail ---"
                    $tail
                ) -join [Environment]::NewLine
                Send-ServerSyncEmail -Config $config.email `
                    -Subject '[URGENT] ServerSync Update: NIC DISABLE VERIFICATION FAILED' `
                    -Body $urgentBody `
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
            & $gitExe reset --hard $prevHead 2>&1 | Out-Null
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
    Push-Location -LiteralPath $installRoot
    try {
        & $gitExe reset --hard $prevHead 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-ServerSyncLog -Logger $logger -Level 'INFO' -Message "Rollback complete"
            exit 4
        } else {
            exit 5
        }
    } finally { Pop-Location }
}

Write-ServerSyncLog -Logger $logger -Level 'INFO' -Message "Running smoke test: -ValidateConfig + module spot-checks"
# The smoke test is intentionally an inline script so we exercise more than
# just config parsing. Each module-level call below catches the case where a
# bad upstream commit broke a module without breaking config-only validation.
$smokeArgs = @(
    '-NoProfile'
    '-Command'
    @"
`$ErrorActionPreference = 'Stop'
try {
    & '$smokeScript' -ValidateConfig -ConfigPath '$ConfigPath'
    if (`$LASTEXITCODE -ne 0) { exit `$LASTEXITCODE }

    # Spot-check that key module functions still parse and execute. A
    # malformed function signature won't surface from -ValidateConfig.
    `$modDir = Join-Path '$installRoot' 'src\Modules'
    . (Join-Path `$modDir 'SyncOperations.ps1')
    . (Join-Path `$modDir 'Retention.ps1')
    . (Join-Path `$modDir 'NetworkControl.ps1')
    if (-not (Test-RobocopyFlag -Flag '/COMPRESS')) { throw 'Test-RobocopyFlag broken' }
    if ((ConvertFrom-RobocopyExitCode -ExitCode 0).Description -notmatch 'no') { throw 'ConvertFrom-RobocopyExitCode broken' }
    `$tmpRoot = Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path `$tmpRoot)
    try {
        if (-not (Test-PathContainedIn -Candidate `$tmpRoot -Root `$tmpRoot)) {
            throw 'Test-PathContainedIn broken'
        }
    } finally {
        Remove-Item -Recurse -Force -LiteralPath `$tmpRoot -ErrorAction SilentlyContinue
    }
    exit 0
}
catch {
    [Console]::Error.WriteLine("smoke: `$(`$_.Exception.Message)")
    exit 1
}
"@
)
& $psExe @smokeArgs 2>&1 | ForEach-Object { Write-ServerSyncLog -Logger $logger -Level 'INFO' -Message "  smoke: $_" }
$smokeExit = $LASTEXITCODE

if ($smokeExit -ne 0) {
    Write-ServerSyncLog -Logger $logger -Level 'ERROR' -Message "Smoke test FAILED (exit $smokeExit). Rolling back from $newHead to $prevHead." -AlsoEventLog

    Push-Location -LiteralPath $installRoot
    $rollbackOk = $false
    try {
        & $gitExe reset --hard $prevHead 2>&1 | Out-Null
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
            -Body "Update from $repoUrl branch $branch failed smoke test (exit $smokeExit).`nFailed commit: $newHead`nPrevious commit: $prevHead`n$bodyStatus.`nSee log: $($logger.LogPath)" `
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
            -Body "Update from $repoUrl branch $branch applied successfully.`nPrevious: $prevHead`nNew:      $newHead`nSee log: $($logger.LogPath)" `
            -Credential $smtpCred -HasFailures $false
    }
} catch {
    Write-ServerSyncLog -Logger $logger -Level 'WARN' -Message "Email send failed: $($_.Exception.Message)"
}

Write-ServerSyncLog -Logger $logger -Level 'INFO' -Message "Update complete - exit 0"
exit 0

# SIG # Begin signature block
# MIIcIAYJKoZIhvcNAQcCoIIcETCCHA0CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCYaOH0SdvYjPB+
# dnZH4IakzKlnLwwqO+RtBjYOYGuNiKCCFl4wggMgMIICCKADAgECAhAujyLP3LJ6
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
# AYI3AgELMQ4wDAYKKwYBBAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgfbc9OtgZ3gq/
# k4/VRcRmoKJ/O3Jdi7tR4Qs9KCBZ9zgwDQYJKoZIhvcNAQEBBQAEggEAmxQWGwxl
# tFVD7m6wQFEai2egBnqK3LXwt9DQcDDqXqXHJ3sG/PQbCPN2P/34ledCSNFsdd/N
# Hifzoz322wLg8bvCcjykaXEs2dvjT7Hs6Zwx+3BbEDevqGW3xfy/dc5mKaslfMaB
# Ejr3PZ0O8Elv5y09T2wLNobLeswvUqVHuplHajZu1ol4UI/ADZGvdYKUCg9ulJNQ
# th2+I+5/IRltVoIYbZ9go3N74tJ1Lvsa7qAxXSqQbF7TVl0k2Bu/C3y5FSLI7i9J
# 0s4AFHR8zDb8y4JjzXQh/2AJ+WZ4cMaeym4QJN3Hzp4u0eTVLomefYFBRxqKI/N5
# N1nFt9kAcVdUg6GCAyYwggMiBgkqhkiG9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJ
# BgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGln
# aUNlcnQgVHJ1c3RlZCBHNCBUaW1lU3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAy
# NSBDQTECEAqA7xhLjfEFgtHEdqeVdGgwDQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG
# 9w0BCQMxCwYJKoZIhvcNAQcBMBwGCSqGSIb3DQEJBTEPFw0yNjA0MjkyMTQ5NTVa
# MC8GCSqGSIb3DQEJBDEiBCDsU2yoPbr+fBHdmH1dbVios0T+LSuEyoo+NApiEcmk
# YzANBgkqhkiG9w0BAQEFAASCAgA7FUTX4QVZUQ6ks4Gbt7hr3a8ximbRkT3naOVW
# FEq7rnmhJr/0JhiHQSw3UDrpuMX19143RaYtcDGKCG/jtxCy84rpqsNH8LJhUQzN
# nCKMd0cufXLYXoj7n9YxFyhExvM90NErKyKeITA09hgoq5QdcwdNk5pTN+ZrPTiT
# iqYmYXMwuH07ZdBC66FYdtskY6J5YLNUJa2xMQhVuNGur/G+MJ7w3W/Ju2EEx4Yc
# 7PdDjD82h6WRoHh0hG3UK45IdmbqAwaijMfvOYklqpNwIfnIJUFDBrZ1EcV9Zy2P
# nxaLyLPKuDNR6YlHy2idzN6ppgbQiGCA+4sIiTfdG9UEOo06bfquejZvTilQ5IXF
# 78EM4nLLJQhBKD1LZ7XUeFyqzH3m54lzCtpD8E6rz+5Z/Q2YPxVq8VHgntev/L8C
# U7TbuXMb23aPRCwsMB5J9WTLI3C8ujvD7XME60AyNvyKmMtWXCJ77DwHgW4pthWS
# qyhMpII/K+sFWNBdp0kkBkdvHdkmPvtCwELpOAARmk/lGPYECB/kHS9b7Fjnn1iU
# q3NQ1YdkIkXXafdX6e0qAqIWEvg2Qh/DhCZDz4LpkKO895f4eIK4RMUVn97amCDm
# FhBewkrcT7WG3U/T0YZ9w4ow3zFenQdbsYZaRnODBZGiAcPXHjrhdIxJ18Xb8L8E
# 5xM74Q==
# SIG # End signature block
