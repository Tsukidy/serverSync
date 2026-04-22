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

    if (-not (Test-Path -Path $LogDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
    }

    $date = (Get-Date).ToString('yyyy-MM-dd')
    $logPath = Join-Path $LogDirectory "$Prefix-$date.log"

    return [PSCustomObject]@{
        LogPath        = $logPath
        EventLogSource = $EventLogSource
    }
}

function Write-ServerSyncLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][Object]$Logger,
        [Parameter(Mandatory)][ValidateSet('INFO','WARN','ERROR','DEBUG')][string]$Level,
        [Parameter(Mandatory)][string]$Message,
        [switch]$AlsoEventLog
    )

    $ts = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK')
    $line = "$ts [$Level] $Message"
    Add-Content -Path $Logger.LogPath -Value $line -Encoding UTF8

    if ($AlsoEventLog -and $Logger.EventLogSource) {
        $eventType = switch ($Level) {
            'ERROR' { 'Error' }
            'WARN'  { 'Warning' }
            default { 'Information' }
        }
        try {
            Write-EventLog -LogName 'Application' -Source $Logger.EventLogSource `
                           -EventId 1000 -EntryType $eventType -Message $Message -ErrorAction Stop
        }
        catch {
            # Event Log may not be available (non-Windows or source not registered) -- degrade silently
            Add-Content -Path $Logger.LogPath -Value "$ts [WARN] Event Log write failed: $($_.Exception.Message)" -Encoding UTF8
        }
    }
}

function Remove-OldLogFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$LogDirectory,
        [Parameter(Mandatory)][int]$RetentionDays
    )
    if (-not (Test-Path -Path $LogDirectory -PathType Container)) { return }
    $cutoff = (Get-Date).AddDays(-$RetentionDays)
    Get-ChildItem -Path $LogDirectory -File |
        Where-Object { $_.LastWriteTime -lt $cutoff } |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force }
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
