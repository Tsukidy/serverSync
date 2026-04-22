<#
.SYNOPSIS
    robocopy wrapper and exit code interpretation.
#>

function ConvertFrom-RobocopyExitCode {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$ExitCode
    )

    # Robocopy uses a bitmask:
    # 1 = files copied, 2 = extra files/dirs, 4 = mismatches, 8 = copy failures, 16 = fatal
    $description = switch ($ExitCode) {
        0  { 'no files copied, no failures' }
        1  { 'files copied successfully' }
        2  { 'extra files/dirs detected (not copied)' }
        3  { 'files copied + extras detected' }
        4  { 'mismatches detected' }
        5  { 'mismatches + files copied' }
        6  { 'mismatches + extras' }
        7  { 'mismatches + files copied + extras' }
        8  { 'copy errors occurred' }
        9  { 'copy errors + files copied' }
        16 { 'fatal error (robocopy did not run)' }
        default {
            if ($ExitCode -ge 8) { "failure (exit $ExitCode)" }
            else { "unknown exit $ExitCode" }
        }
    }

    return [PSCustomObject]@{
        ExitCode    = $ExitCode
        Success     = ($ExitCode -lt 8)
        HasWarnings = ($ExitCode -ge 4 -and $ExitCode -lt 8)
        Description = $description
    }
}

function Build-RobocopyArgs {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][int]$Threads,
        [Parameter(Mandatory)][int]$Retries,
        [Parameter(Mandatory)][int]$RetryWaitSeconds,
        [Parameter(Mandatory)][string]$LogFile,
        [string[]]$ExtraFlags = @()
    )

    $robocopyArgs = @(
        $Source
        $Destination
        '/E'
        '/Z'
        '/COPY:DAT'
        '/XO'
        "/R:$Retries"
        "/W:$RetryWaitSeconds"
        "/MT:$Threads"
        '/NP'
        "/LOG+:$LogFile"
    )
    if ($ExtraFlags) { $robocopyArgs += $ExtraFlags }
    return ,$robocopyArgs
}

function Invoke-RobocopySync {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][int]$Threads,
        [Parameter(Mandatory)][int]$Retries,
        [Parameter(Mandatory)][int]$RetryWaitSeconds,
        [Parameter(Mandatory)][string]$LogFile,
        [string[]]$ExtraFlags = @()
    )

    if (-not (Test-Path -Path $Destination -PathType Container)) {
        if ($PSCmdlet.ShouldProcess($Destination, 'Create destination directory')) {
            New-Item -ItemType Directory -Path $Destination -Force | Out-Null
        }
    }

    $robocopyArgs = Build-RobocopyArgs -Source $Source -Destination $Destination `
        -Threads $Threads -Retries $Retries -RetryWaitSeconds $RetryWaitSeconds `
        -LogFile $LogFile -ExtraFlags $ExtraFlags

    if ($PSCmdlet.ShouldProcess("$Source -> $Destination", 'robocopy')) {
        $process = Start-Process -FilePath 'robocopy' -ArgumentList $robocopyArgs -Wait -PassThru -NoNewWindow
        return (ConvertFrom-RobocopyExitCode -ExitCode $process.ExitCode)
    }
    else {
        return [PSCustomObject]@{ ExitCode = 0; Success = $true; HasWarnings = $false; Description = '[WhatIf] skipped' }
    }
}
