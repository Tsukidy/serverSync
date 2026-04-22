<#
.SYNOPSIS
    ServerSync admin GUI (WinForms): config editor, log viewer, credentials, schedule.
#>

[CmdletBinding()]
param(
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'

# Self-elevate for Task Scheduler modifications
$isAdmin = ([Security.Principal.WindowsPrincipal]`
    [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName  = (Get-Process -Id $PID).Path
    $psi.Arguments = "-NoProfile -File `"$PSCommandPath`""
    if ($ConfigPath) { $psi.Arguments += " -ConfigPath `"$ConfigPath`"" }
    $psi.Verb = 'runas'
    try { [System.Diagnostics.Process]::Start($psi) | Out-Null } catch {}
    exit 0
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Load modules
$modulesDir = Join-Path $PSScriptRoot 'Modules'
. (Join-Path $modulesDir 'ConfigLoader.ps1')

# Default config path
if (-not $ConfigPath) {
    $ConfigPath = 'C:\ProgramData\ServerSync\config.json'
}

$form = New-Object System.Windows.Forms.Form
$form.Text = 'ServerSync Manager'
$form.Size = New-Object System.Drawing.Size(900, 650)
$form.StartPosition = 'CenterScreen'

$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Dock = 'Fill'

$tabConfig  = New-Object System.Windows.Forms.TabPage -Property @{ Text = 'Config' }
$tabLogs    = New-Object System.Windows.Forms.TabPage -Property @{ Text = 'Logs' }
$tabCreds   = New-Object System.Windows.Forms.TabPage -Property @{ Text = 'Credentials' }
$tabSched   = New-Object System.Windows.Forms.TabPage -Property @{ Text = 'Schedule' }

$tabs.TabPages.AddRange(@($tabConfig, $tabLogs, $tabCreds, $tabSched))
$form.Controls.Add($tabs)

# Placeholder labels per tab — filled by subsequent tasks
foreach ($tab in @($tabConfig,$tabLogs,$tabCreds,$tabSched)) {
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = "$($tab.Text) tab (not yet implemented)"
    $lbl.Dock = 'Fill'
    $lbl.TextAlign = 'MiddleCenter'
    $tab.Controls.Add($lbl)
}

[void]$form.ShowDialog()
