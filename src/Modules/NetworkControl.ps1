<#
.SYNOPSIS
    Enable, disable, and verify network adapters. Verify network readiness.
#>

function Enable-ServerSyncNics {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Names
    )
    foreach ($n in $Names) {
        Enable-NetAdapter -Name $n -Confirm:$false -ErrorAction Stop
    }
}

function Disable-ServerSyncNics {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Names
    )
    $failures = @()
    foreach ($n in $Names) {
        try {
            Disable-NetAdapter -Name $n -Confirm:$false -ErrorAction Stop
        }
        catch {
            $failures += "$n : $($_.Exception.Message)"
        }
    }
    if ($failures.Count -gt 0) {
        throw "Failed to disable NICs: $($failures -join '; ')"
    }
}

function Test-AllNicsDisabled {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Names
    )
    foreach ($n in $Names) {
        $adapter = Get-NetAdapter -Name $n -ErrorAction SilentlyContinue
        # Missing adapter is a verification failure: a typo or rename in
        # config would otherwise silently pass and defeat the most
        # security-critical invariant of the system.
        if (-not $adapter) { return $false }
        if ($adapter.Status -ne 'Disabled') { return $false }
    }
    return $true
}

function Wait-NetworkReady {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TargetHost,
        [Parameter(Mandatory)][int]$TimeoutSeconds
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            if (Test-Connection -TargetName $TargetHost -Count 1 -Quiet -ErrorAction Stop) {
                return $true
            }
        }
        catch {
            # Test-Connection older param name on Windows PowerShell 5.1
            try {
                if (Test-Connection -ComputerName $TargetHost -Count 1 -Quiet -ErrorAction Stop) {
                    return $true
                }
            } catch {}
        }
        Start-Sleep -Seconds 1
    }
    return $false
}
