<#
.SYNOPSIS
    Install ServerSync: create data directories with restricted ACLs, register
    Event Log source, create Task Scheduler folder. Idempotent.
.PARAMETER InstallRoot
    Where the scripts live. Default: C:\Program Files\ServerSync
.PARAMETER DataRoot
    Where config and logs live. Default: C:\ProgramData\ServerSync
.PARAMETER ServiceAccount
    Account that Task Scheduler tasks will run as. Grants it rights to data dirs.
#>

[CmdletBinding()]
param(
    [string]$InstallRoot = 'C:\Program Files\ServerSync',
    [string]$DataRoot = 'C:\ProgramData\ServerSync',
    [Parameter(Mandatory)][string]$ServiceAccount,
    [string]$EventLogSource = 'ServerSync'
)

$ErrorActionPreference = 'Stop'

# Must run elevated
$isAdmin = ([Security.Principal.WindowsPrincipal]`
    [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Error "Must run as Administrator."
    exit 1
}

# Validate that the ServiceAccount actually exists before we Set-Acl. A
# typo'd account name silently strips ACLs in some PowerShell versions, or
# gets translated to a SID-with-no-name that confuses later operations.
try {
    $svcSid = (New-Object Security.Principal.NTAccount($ServiceAccount)).Translate([Security.Principal.SecurityIdentifier])
    Write-Host "ServiceAccount resolved: $ServiceAccount -> $($svcSid.Value)"
}
catch {
    Write-Error "ServiceAccount '$ServiceAccount' could not be resolved. Create the account first, then re-run."
    exit 1
}

# 1. Create install + data directories
if (-not (Test-Path -LiteralPath $InstallRoot)) {
    New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null
    Write-Host "Created: $InstallRoot"
}
foreach ($dir in @($DataRoot, (Join-Path $DataRoot 'logs'))) {
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Write-Host "Created: $dir"
    }
}

# 2a. ACL the install root: Admins + SYSTEM Full Control, ServiceAccount
# Read & Execute only (no Write). This prevents the run-as account from
# tampering with its own scripts at runtime - a defense-in-depth control
# even though that account is a Local Admin (administrators retain Write
# via the Admins group entry; the ServiceAccount-specific entry is RX-only).
$acl = New-Object System.Security.AccessControl.DirectorySecurity
$acl.SetAccessRuleProtection($true, $false)
$acl.SetOwner((New-Object Security.Principal.NTAccount('BUILTIN\Administrators')))
foreach ($ident in @('BUILTIN\Administrators', 'NT AUTHORITY\SYSTEM')) {
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $ident, 'FullControl',
        ([System.Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit'),
        'None', 'Allow')
    $acl.AddAccessRule($rule)
}
# ServiceAccount: ReadAndExecute only on InstallRoot.
$svcRxRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
    $ServiceAccount, 'ReadAndExecute',
    ([System.Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit'),
    'None', 'Allow')
$acl.AddAccessRule($svcRxRule)
Set-Acl -LiteralPath $InstallRoot -AclObject $acl
Write-Host "ACLs applied (Admins/SYSTEM FullControl, ${ServiceAccount}: ReadAndExecute): $InstallRoot"

# 2b. ACL the data root + logs: Admins + SYSTEM + ServiceAccount Full Control
foreach ($dir in @($DataRoot, (Join-Path $DataRoot 'logs'))) {
    $acl = New-Object System.Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    $acl.SetOwner((New-Object Security.Principal.NTAccount('BUILTIN\Administrators')))
    foreach ($ident in @('BUILTIN\Administrators','NT AUTHORITY\SYSTEM',$ServiceAccount)) {
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $ident, 'FullControl',
            ([System.Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit'),
            'None', 'Allow')
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $dir -AclObject $acl
    Write-Host "ACLs applied: $dir"
}

# 3. Register Event Log source. SourceExists returns true if the source is
# registered to ANY log, which masks the case where it was previously
# bound to a different log. Detect that and re-register cleanly.
$existingLog = [System.Diagnostics.EventLog]::LogNameFromSourceName($EventLogSource, '.')
if ($existingLog -and $existingLog -ne 'Application') {
    Write-Warning "Event Log source '$EventLogSource' is currently registered to log '$existingLog' instead of 'Application'. Removing and re-registering."
    [System.Diagnostics.EventLog]::DeleteEventSource($EventLogSource)
    $existingLog = $null
}
if (-not $existingLog) {
    New-EventLog -LogName 'Application' -Source $EventLogSource
    Write-Host "Event Log source registered: $EventLogSource"
}
else {
    Write-Host "Event Log source already registered: $EventLogSource"
}

# 4. Create Task Scheduler folder
$ts = New-Object -ComObject 'Schedule.Service'
$ts.Connect()
$root = $ts.GetFolder('\')
try {
    $root.GetFolder('ServerSync') | Out-Null
    Write-Host "Task Scheduler folder already exists: \ServerSync"
} catch {
    $root.CreateFolder('ServerSync') | Out-Null
    Write-Host "Task Scheduler folder created: \ServerSync"
}

Write-Host ''
Write-Host 'Install steps complete. Next:'
Write-Host "  1. Copy config.sample.json to $DataRoot\config.json and edit it."
Write-Host '  2. Register credentials with Setup-Credentials.ps1 for each credential_target.'
Write-Host '  3. Use ServerSync-Manager.ps1 Schedule tab (or schtasks) to create scheduled tasks.'
