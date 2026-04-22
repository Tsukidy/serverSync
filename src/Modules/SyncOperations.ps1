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
