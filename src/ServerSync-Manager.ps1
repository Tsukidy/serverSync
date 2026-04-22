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
foreach ($tab in @($tabLogs,$tabCreds,$tabSched)) {
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = "$($tab.Text) tab (not yet implemented)"
    $lbl.Dock = 'Fill'
    $lbl.TextAlign = 'MiddleCenter'
    $tab.Controls.Add($lbl)
}

# ==================== Config tab ====================
$cfgPanel = New-Object System.Windows.Forms.TableLayoutPanel
$cfgPanel.Dock = 'Fill'
$cfgPanel.RowCount = 3
$cfgPanel.ColumnCount = 1
$cfgPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute',30))) | Out-Null
$cfgPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Percent',100))) | Out-Null
$cfgPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute',40))) | Out-Null

$cfgPathLabel = New-Object System.Windows.Forms.Label
$cfgPathLabel.Text = "Config: $ConfigPath"
$cfgPathLabel.Dock = 'Fill'
$cfgPanel.Controls.Add($cfgPathLabel, 0, 0)

$cfgGrid = New-Object System.Windows.Forms.DataGridView
$cfgGrid.Dock = 'Fill'
$cfgGrid.AutoGenerateColumns = $false
$cfgGrid.AllowUserToAddRows = $false
$cfgGrid.SelectionMode = 'FullRowSelect'
$cfgGrid.ReadOnly = $true

foreach ($colDef in @(
    @{ Name='name'; Header='Name'; Width=150 },
    @{ Name='source'; Header='Source'; Width=250 },
    @{ Name='destination'; Header='Destination'; Width=200 },
    @{ Name='credential_target'; Header='Cred Target'; Width=120 },
    @{ Name='tags'; Header='Tags'; Width=150 }
)) {
    $col = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $col.Name = $colDef.Name
    $col.HeaderText = $colDef.Header
    $col.Width = $colDef.Width
    $cfgGrid.Columns.Add($col) | Out-Null
}

$cfgPanel.Controls.Add($cfgGrid, 0, 1)

$cfgButtons = New-Object System.Windows.Forms.FlowLayoutPanel
$cfgButtons.Dock = 'Fill'
$cfgButtons.FlowDirection = 'LeftToRight'
$btnReload = New-Object System.Windows.Forms.Button -Property @{ Text = 'Reload'; Width = 100 }
$btnAdd    = New-Object System.Windows.Forms.Button -Property @{ Text = 'Add pair'; Width = 100 }
$btnEdit   = New-Object System.Windows.Forms.Button -Property @{ Text = 'Edit'; Width = 100 }
$btnDelete = New-Object System.Windows.Forms.Button -Property @{ Text = 'Delete'; Width = 100 }
$btnSave   = New-Object System.Windows.Forms.Button -Property @{ Text = 'Save'; Width = 100 }
$cfgButtons.Controls.AddRange(@($btnReload,$btnAdd,$btnEdit,$btnDelete,$btnSave))
$cfgPanel.Controls.Add($cfgButtons, 0, 2)

$tabConfig.Controls.Add($cfgPanel)

# In-memory working copy of config
$script:WorkingConfig = $null

function Refresh-ConfigGrid {
    $cfgGrid.Rows.Clear()
    if (-not $script:WorkingConfig) { return }
    foreach ($pair in $script:WorkingConfig.folder_pairs) {
        $tags = if ($pair.tags) { $pair.tags -join ',' } else { '' }
        [void]$cfgGrid.Rows.Add($pair.name,$pair.source,$pair.destination,$pair.credential_target,$tags)
    }
}

function Load-Config {
    if (-not (Test-Path $ConfigPath)) {
        [void][System.Windows.Forms.MessageBox]::Show("Config not found: $ConfigPath",'ServerSync',0,16)
        return
    }
    try {
        $script:WorkingConfig = Read-ServerSyncConfig -Path $ConfigPath
        Refresh-ConfigGrid
    }
    catch {
        [void][System.Windows.Forms.MessageBox]::Show("Failed to load config: $($_.Exception.Message)",'ServerSync',0,16)
    }
}

function Save-Config {
    $validation = Test-ServerSyncConfig -Config $script:WorkingConfig
    if (-not $validation.Valid) {
        [void][System.Windows.Forms.MessageBox]::Show("Invalid:`n$($validation.Errors -join "`n")",'ServerSync',0,16)
        return
    }
    $tmp = "$ConfigPath.tmp"
    $script:WorkingConfig | ConvertTo-Json -Depth 10 | Set-Content -Path $tmp -Encoding UTF8
    Move-Item -Force $tmp $ConfigPath
    [void][System.Windows.Forms.MessageBox]::Show('Saved.','ServerSync',0,64)
}

function Edit-Pair {
    param($Pair)

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = if ($Pair) { "Edit: $($Pair.name)" } else { 'Add pair' }
    $dlg.Size = New-Object System.Drawing.Size(500, 400)
    $dlg.StartPosition = 'CenterParent'

    $y = 10
    $fields = @{}
    foreach ($fld in 'name','source','destination','credential_target','tags (comma)','retention_count','retention_mode','retention_extensions (comma)') {
        $lbl = New-Object System.Windows.Forms.Label
        $lbl.Text = $fld
        $lbl.Location = New-Object System.Drawing.Point(10,$y)
        $lbl.Size = New-Object System.Drawing.Size(180,20)
        $dlg.Controls.Add($lbl)

        $tb = New-Object System.Windows.Forms.TextBox
        $tb.Location = New-Object System.Drawing.Point(200,$y)
        $tb.Size = New-Object System.Drawing.Size(270,20)
        $dlg.Controls.Add($tb)
        $fields[$fld] = $tb
        $y += 30
    }

    if ($Pair) {
        $fields['name'].Text = $Pair.name
        $fields['source'].Text = $Pair.source
        $fields['destination'].Text = $Pair.destination
        $fields['credential_target'].Text = $Pair.credential_target
        if ($Pair.tags) { $fields['tags (comma)'].Text = ($Pair.tags -join ',') }
        if ($Pair.retention) {
            if ($Pair.retention.count) { $fields['retention_count'].Text = $Pair.retention.count }
            if ($Pair.retention.mode)  { $fields['retention_mode'].Text  = $Pair.retention.mode }
            if ($Pair.retention.extensions) { $fields['retention_extensions (comma)'].Text = ($Pair.retention.extensions -join ',') }
        }
    }
    else {
        $fields['tags (comma)'].Text = 'default'
    }

    $ok = New-Object System.Windows.Forms.Button -Property @{ Text='OK'; DialogResult='OK' }
    $ok.Location = New-Object System.Drawing.Point(300,$y)
    $cancel = New-Object System.Windows.Forms.Button -Property @{ Text='Cancel'; DialogResult='Cancel' }
    $cancel.Location = New-Object System.Drawing.Point(390,$y)
    $dlg.AcceptButton = $ok
    $dlg.CancelButton = $cancel
    $dlg.Controls.AddRange(@($ok,$cancel))

    if ($dlg.ShowDialog() -ne 'OK') { return $null }

    $retention = $null
    if ($fields['retention_count'].Text -or $fields['retention_mode'].Text -or $fields['retention_extensions (comma)'].Text) {
        $retention = [ordered]@{}
        if ($fields['retention_mode'].Text) { $retention['mode'] = $fields['retention_mode'].Text }
        if ($fields['retention_extensions (comma)'].Text) {
            $retention['extensions'] = @($fields['retention_extensions (comma)'].Text -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        }
        if ($fields['retention_count'].Text) { $retention['count'] = [int]$fields['retention_count'].Text }
    }

    $out = [ordered]@{
        name              = $fields['name'].Text
        source            = $fields['source'].Text
        destination       = $fields['destination'].Text
        credential_target = $fields['credential_target'].Text
    }
    if ($retention) { $out['retention'] = $retention }
    $out['tags'] = @($fields['tags (comma)'].Text -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })

    return [PSCustomObject]$out
}

$btnReload.Add_Click({ Load-Config })
$btnSave.Add_Click({ Save-Config })
$btnAdd.Add_Click({
    $newPair = Edit-Pair -Pair $null
    if ($newPair) {
        $script:WorkingConfig.folder_pairs = @($script:WorkingConfig.folder_pairs) + $newPair
        Refresh-ConfigGrid
    }
})
$btnEdit.Add_Click({
    if ($cfgGrid.SelectedRows.Count -eq 0) { return }
    $idx = $cfgGrid.SelectedRows[0].Index
    $updated = Edit-Pair -Pair $script:WorkingConfig.folder_pairs[$idx]
    if ($updated) {
        $script:WorkingConfig.folder_pairs[$idx] = $updated
        Refresh-ConfigGrid
    }
})
$btnDelete.Add_Click({
    if ($cfgGrid.SelectedRows.Count -eq 0) { return }
    $idx = $cfgGrid.SelectedRows[0].Index
    $script:WorkingConfig.folder_pairs = @($script:WorkingConfig.folder_pairs | Where-Object { $script:WorkingConfig.folder_pairs.IndexOf($_) -ne $idx })
    Refresh-ConfigGrid
})

# Initial load
Load-Config

[void]$form.ShowDialog()
