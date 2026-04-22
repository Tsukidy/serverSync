<#
.SYNOPSIS
    Store a named credential in Windows Credential Manager for ServerSync to use.
.PARAMETER Target
    The credential target name as referenced in config.json.
.PARAMETER UserName
    Optional: username to store. Prompted if omitted.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Target,
    [string]$UserName
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Command New-StoredCredential -ErrorAction SilentlyContinue)) {
    Write-Error "CredentialManager module not installed. Run: Install-Module CredentialManager -Scope AllUsers"
    exit 1
}

if (-not $UserName) { $UserName = Read-Host 'UserName' }
$secure = Read-Host 'Password' -AsSecureString

$existing = Get-StoredCredential -Target $Target
if ($existing) {
    $answer = Read-Host "Credential '$Target' exists. Overwrite? (y/N)"
    if ($answer -ne 'y') { exit 0 }
    Remove-StoredCredential -Target $Target
}

New-StoredCredential -Target $Target -UserName $UserName -SecurePassword $secure `
    -Persist LocalMachine -Type Generic | Out-Null

Write-Host "Stored credential '$Target' for user '$UserName'."
