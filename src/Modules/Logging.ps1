<#
.SYNOPSIS
    Logging primitives: file logger, Windows Event Log writer, SMTP email.
#>

function New-ServerSyncLogger {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$LogDirectory,
        [string]$Prefix = 'serversync',
        [string]$EventLogSource
    )

    if (-not (Test-Path -LiteralPath $LogDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
        # Lock the new directory down. The caller may have pointed log_directory
        # somewhere unexpected; inheriting the parent's ACLs (often Users:Read on
        # C:\) would leak operational data. We grant full control to
        # BUILTIN\Administrators, NT AUTHORITY\SYSTEM, and the current user only,
        # and disable inheritance. This only runs the FIRST time the directory is
        # created - existing directories are not modified.
        if ($IsWindows -or [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
            try {
                $acl = New-Object System.Security.AccessControl.DirectorySecurity
                $acl.SetAccessRuleProtection($true, $false)
                $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name
                foreach ($ident in @('BUILTIN\Administrators', 'NT AUTHORITY\SYSTEM', $currentUser)) {
                    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                        $ident, 'FullControl',
                        ([System.Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit'),
                        'None', 'Allow')
                    $acl.AddAccessRule($rule)
                }
                Set-Acl -LiteralPath $LogDirectory -AclObject $acl -ErrorAction Stop
            }
            catch {
                # Non-fatal but write the failure to a temp marker so it's
                # discoverable. We do not have a logger yet here.
                $marker = Join-Path $LogDirectory '.acl-warning.txt'
                Set-Content -LiteralPath $marker -Value "Failed to apply ACL on first creation: $($_.Exception.Message)" -ErrorAction SilentlyContinue
            }
        }
    }

    $date = (Get-Date).ToString('yyyy-MM-dd')
    $logPath = Join-Path $LogDirectory "$Prefix-$date.log"

    return [PSCustomObject]@{
        LogPath        = $logPath
        EventLogSource = $EventLogSource
    }
}

function ConvertTo-LogSafeText {
    <#
    .SYNOPSIS
        Escape characters that would let attacker-controlled values forge
        new log lines or break line-oriented log parsers.
    .DESCRIPTION
        CR and LF are replaced with literal '\r' and '\n' sequences. A NUL
        byte is replaced with '\0'. Anything else is passed through.

        This is single-message-per-line defense. Aggregators that key on
        regex like '^[\d-]+T[\d:]+(?:Z|[+-]\d{2}:\d{2}) \[(?:INFO|WARN|...)\] '
        will no longer match injected fakes from inside a message body.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text
    )
    return $Text -replace "`r", '\r' -replace "`n", '\n' -replace "`0", '\0'
}

function Write-ServerSyncLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][Object]$Logger,
        [Parameter(Mandatory)][ValidateSet('INFO','WARN','ERROR','DEBUG')][string]$Level,
        [Parameter(Mandatory)][string]$Message,
        [switch]$AlsoEventLog
    )

    $safeMessage = ConvertTo-LogSafeText -Text $Message
    $ts = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK')
    $line = "$ts [$Level] $safeMessage"
    Add-Content -Path $Logger.LogPath -Value $line -Encoding UTF8

    if ($AlsoEventLog -and $Logger.EventLogSource) {
        $eventType = switch ($Level) {
            'ERROR' { 'Error' }
            'WARN'  { 'Warning' }
            default { 'Information' }
        }
        try {
            Write-EventLog -LogName 'Application' -Source $Logger.EventLogSource `
                           -EventId 1000 -EntryType $eventType -Message $safeMessage -ErrorAction Stop
        }
        catch {
            # Event Log may not be available (non-Windows or source not registered) -- degrade silently.
            # The exception message is itself sanitized to prevent it being a re-injection vector.
            $safeErr = ConvertTo-LogSafeText -Text $_.Exception.Message
            Add-Content -Path $Logger.LogPath -Value "$ts [WARN] Event Log write failed: $safeErr" -Encoding UTF8
        }
    }
}

function Remove-OldLogFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$LogDirectory,
        [Parameter(Mandatory)][int]$RetentionDays
    )
    if (-not (Test-Path -LiteralPath $LogDirectory -PathType Container)) { return }
    $cutoff = (Get-Date).AddDays(-$RetentionDays)
    # Filter to *.log specifically. The log directory used to be assumed
    # log-only, but admins occasionally drop other artifacts there
    # (state.json, lastrun.txt, forensic captures). Refusing to touch
    # non-log files is safer.
    Get-ChildItem -LiteralPath $LogDirectory -File -Filter '*.log' |
        Where-Object { $_.LastWriteTime -lt $cutoff } |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force }
}

function Get-LogTail {
    <#
    .SYNOPSIS
        Read the tail of a log file safely with a hard size cap, for use
        in email bodies. Avoids attaching unbounded log content to
        outbound mail.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$MaxLines = 200,
        [int]$MaxBytes = 64KB
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    $info = Get-Item -LiteralPath $Path
    if ($info.Length -le $MaxBytes) {
        $lines = Get-Content -LiteralPath $Path -Tail $MaxLines
    }
    else {
        # File is large - read just the tail bytes.
        $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try {
            $start = [Math]::Max(0, $fs.Length - $MaxBytes)
            $fs.Seek($start, [IO.SeekOrigin]::Begin) | Out-Null
            $reader = New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8)
            $tailContent = $reader.ReadToEnd()
            $lines = $tailContent -split "`r?`n" | Select-Object -Last $MaxLines
        }
        finally {
            $fs.Dispose()
        }
    }
    $header = "(showing last $($lines.Count) line(s) of $($info.FullName); file size $($info.Length) bytes)"
    return ($header, '') + $lines -join [Environment]::NewLine
}

function Test-ShouldSendEmail {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('failure','always','never')][string]$SendOn,
        [Parameter(Mandatory)][bool]$HasFailures
    )
    switch ($SendOn) {
        'always'  { return $true }
        'failure' { return $HasFailures }
        'never'   { return $false }
    }
}

function Send-ServerSyncEmail {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][Object]$Config,
        [Parameter(Mandatory)][string]$Subject,
        [Parameter(Mandatory)][string]$Body,
        [PSCredential]$Credential,
        [bool]$HasFailures = $false
    )

    if (-not $Config.enabled) { return }
    if (-not (Test-ShouldSendEmail -SendOn $Config.send_on -HasFailures $HasFailures)) { return }

    $mailParams = @{
        SmtpServer = $Config.smtp_server
        Port       = $Config.smtp_port
        From       = $Config.from
        To         = $Config.to
        Subject    = $Subject
        Body       = $Body
        UseSsl     = [bool]$Config.use_ssl
    }
    if ($Credential) { $mailParams['Credential'] = $Credential }

    # Send-MailMessage is deprecated but still the best built-in option for Windows PowerShell
    # compatibility. On PS7, it still works. Mocked in tests.
    Send-MailMessage @mailParams -ErrorAction Stop
}
