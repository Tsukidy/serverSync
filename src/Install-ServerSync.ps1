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

# 1. Create data directories
foreach ($dir in @($DataRoot, (Join-Path $DataRoot 'logs'))) {
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Write-Host "Created: $dir"
    }
}

# 2. Apply ACLs: service account + Administrators only
foreach ($dir in @($DataRoot, (Join-Path $DataRoot 'logs'))) {
    $acl = New-Object System.Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)  # disable inheritance, no copy
    foreach ($ident in @('BUILTIN\Administrators','NT AUTHORITY\SYSTEM',$ServiceAccount)) {
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $ident, 'FullControl',
            ([System.Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit'),
            'None', 'Allow')
        $acl.AddAccessRule($rule)
    }
    Set-Acl -Path $dir -AclObject $acl
    Write-Host "ACLs applied: $dir"
}

# 3. Register Event Log source
if (-not [System.Diagnostics.EventLog]::SourceExists($EventLogSource)) {
    New-EventLog -LogName 'Application' -Source $EventLogSource
    Write-Host "Event Log source registered: $EventLogSource"
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
