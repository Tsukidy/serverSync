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
    <#
    .DESCRIPTION
        Wait for the configured ready_check_host to be reachable, ICMP first.
        If -Port is supplied, also verify a TCP connection to that port (e.g.,
        SMB 445) - a stronger check because some networks filter ICMP while
        allowing the actual sync protocol.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TargetHost,
        [Parameter(Mandatory)][int]$TimeoutSeconds,
        [int]$Port
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $icmpOk = $false
        try {
            if (Test-Connection -TargetName $TargetHost -Count 1 -Quiet -ErrorAction Stop) {
                $icmpOk = $true
            }
        }
        catch {
            # Test-Connection has different param names across PS versions.
            try {
                if (Test-Connection -ComputerName $TargetHost -Count 1 -Quiet -ErrorAction Stop) {
                    $icmpOk = $true
                }
            } catch {}
        }

        if ($icmpOk) {
            if (-not $Port) { return $true }
            # Verify TCP reachability too. A short connect timeout avoids
            # hanging the whole readiness window on a single port probe.
            $client = New-Object Net.Sockets.TcpClient
            try {
                $iar = $client.BeginConnect($TargetHost, $Port, $null, $null)
                if ($iar.AsyncWaitHandle.WaitOne(2000)) {
                    try {
                        $client.EndConnect($iar)
                        return $true
                    } catch {}
                }
            }
            finally {
                $client.Close()
            }
        }
        Start-Sleep -Seconds 1
    }
    return $false
}
