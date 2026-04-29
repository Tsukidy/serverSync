<#
.SYNOPSIS
    ServerSync admin GUI (WinForms): config editor, log viewer, credentials, schedule.
#>

[CmdletBinding()]
param(
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'

# Validate ConfigPath shape BEFORE doing anything else - the value flows
# into the elevated re-launch's command line, so a value containing quote
# characters would close the quoted region and let the rest be parsed as
# command-line tokens. Restrict to drive-letter paths ending in .json.
if ($ConfigPath -and $ConfigPath -notmatch '^[A-Za-z]:\\[^"<>|]+\.json$') {
    [Console]::Error.WriteLine("ConfigPath must be an absolute drive-letter path ending in .json with no quote/redirection characters.")
    exit 2
}

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
    # Write the new content into the EXISTING config file, preserving the
    # destination's NTFS object identity (and therefore its ACL). Move-Item
    # would replace the destination's NTFS object with the temp file's, which
    # inherits ACLs from the parent at that moment - any previously stricter
    # explicit ACL on the config file would be lost.
    $newJson = $script:WorkingConfig | ConvertTo-Json -Depth 10
    if (Test-Path -LiteralPath $ConfigPath -PathType Leaf) {
        Set-Content -LiteralPath $ConfigPath -Value $newJson -Encoding UTF8
    }
    else {
        # First-time create: write directly. ACLs will inherit from the
        # parent (which the installer locked down).
        Set-Content -LiteralPath $ConfigPath -Value $newJson -Encoding UTF8
    }
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
        # TryParse so a non-numeric retention_count value surfaces as a
        # readable error rather than crashing the dialog with an unhandled
        # InvalidCastException.
        if ($fields['retention_count'].Text) {
            $parsed = 0
            if ([int]::TryParse($fields['retention_count'].Text, [ref]$parsed)) {
                $retention['count'] = $parsed
            }
            else {
                [void][System.Windows.Forms.MessageBox]::Show(
                    "retention_count must be a positive integer (got '$($fields['retention_count'].Text)').",'Invalid retention_count',0,16)
                return $null
            }
        }
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

# ==================== Logs tab ====================
$logsPanel = New-Object System.Windows.Forms.SplitContainer
$logsPanel.Dock = 'Fill'
$logsPanel.SplitterDistance = 200

$logList = New-Object System.Windows.Forms.ListBox
$logList.Dock = 'Fill'

$logContentPanel = New-Object System.Windows.Forms.TableLayoutPanel
$logContentPanel.Dock = 'Fill'
$logContentPanel.RowCount = 2
$logContentPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute',30))) | Out-Null
$logContentPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Percent',100))) | Out-Null

$logTopPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$logTopPanel.Dock = 'Fill'
$lblFilter = New-Object System.Windows.Forms.Label -Property @{ Text='Filter:'; Width=50 }
$txtFilter = New-Object System.Windows.Forms.TextBox -Property @{ Width=200 }
$chkFailOnly = New-Object System.Windows.Forms.CheckBox -Property @{ Text='Failures only'; Width=120 }
$btnRefreshLog = New-Object System.Windows.Forms.Button -Property @{ Text='Refresh'; Width=80 }
$logTopPanel.Controls.AddRange(@($lblFilter,$txtFilter,$chkFailOnly,$btnRefreshLog))
$logContentPanel.Controls.Add($logTopPanel, 0, 0)

$logText = New-Object System.Windows.Forms.TextBox
$logText.Multiline = $true
$logText.ScrollBars = 'Vertical'
$logText.ReadOnly = $true
$logText.Dock = 'Fill'
$logText.Font = New-Object System.Drawing.Font('Consolas', 9)
$logContentPanel.Controls.Add($logText, 0, 1)

$logsPanel.Panel1.Controls.Add($logList)
$logsPanel.Panel2.Controls.Add($logContentPanel)
$tabLogs.Controls.Add($logsPanel)

function Get-LogDir {
    if ($script:WorkingConfig -and $script:WorkingConfig.logging.log_directory) {
        return $script:WorkingConfig.logging.log_directory
    }
    return 'C:\ProgramData\ServerSync\logs'
}

function Refresh-LogList {
    $logList.Items.Clear()
    $dir = Get-LogDir
    if (-not (Test-Path $dir)) { return }
    Get-ChildItem -Path $dir -File -Filter '*.log' |
        Sort-Object LastWriteTime -Descending |
        ForEach-Object { [void]$logList.Items.Add($_.Name) }
}

function Show-SelectedLog {
    if ($logList.SelectedItem -eq $null) { return }
    $dir = Get-LogDir
    $path = Join-Path $dir $logList.SelectedItem
    if (-not (Test-Path $path)) { return }
    $lines = Get-Content -Path $path
    if ($chkFailOnly.Checked) {
        $lines = $lines | Where-Object { $_ -match 'ERROR|FAIL' }
    }
    if ($txtFilter.Text) {
        $lines = $lines | Where-Object { $_ -like "*$($txtFilter.Text)*" }
    }
    $logText.Text = ($lines -join [Environment]::NewLine)
}

$logList.Add_SelectedIndexChanged({ Show-SelectedLog })
$txtFilter.Add_TextChanged({ Show-SelectedLog })
$chkFailOnly.Add_CheckedChanged({ Show-SelectedLog })
$btnRefreshLog.Add_Click({ Refresh-LogList; Show-SelectedLog })

Refresh-LogList

# ==================== Credentials tab ====================
$credsPanel = New-Object System.Windows.Forms.TableLayoutPanel
$credsPanel.Dock = 'Fill'
$credsPanel.RowCount = 2
$credsPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Percent',100))) | Out-Null
$credsPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute',40))) | Out-Null

$credGrid = New-Object System.Windows.Forms.DataGridView
$credGrid.Dock = 'Fill'
$credGrid.AutoGenerateColumns = $false
$credGrid.ReadOnly = $true
$credGrid.SelectionMode = 'FullRowSelect'
$credGrid.AllowUserToAddRows = $false

foreach ($colDef in @(
    @{ Name='target'; Header='Target'; Width=200 },
    @{ Name='status'; Header='Status'; Width=100 },
    @{ Name='username'; Header='UserName'; Width=200 }
)) {
    $col = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $col.Name = $colDef.Name; $col.HeaderText = $colDef.Header; $col.Width = $colDef.Width
    $credGrid.Columns.Add($col) | Out-Null
}
$credsPanel.Controls.Add($credGrid, 0, 0)

$credButtons = New-Object System.Windows.Forms.FlowLayoutPanel
$credButtons.Dock = 'Fill'
$btnAddCred = New-Object System.Windows.Forms.Button -Property @{ Text='Add/Update'; Width=120 }
$btnDelCred = New-Object System.Windows.Forms.Button -Property @{ Text='Delete'; Width=100 }
$btnRefCred = New-Object System.Windows.Forms.Button -Property @{ Text='Refresh'; Width=80 }
$credButtons.Controls.AddRange(@($btnAddCred,$btnDelCred,$btnRefCred))
$credsPanel.Controls.Add($credButtons, 0, 1)

$tabCreds.Controls.Add($credsPanel)

function Refresh-Credentials {
    $credGrid.Rows.Clear()
    if (-not $script:WorkingConfig) { return }
    $targets = @()
    foreach ($pair in $script:WorkingConfig.folder_pairs) {
        if ($pair.credential_target) { $targets += $pair.credential_target }
    }
    if ($script:WorkingConfig.email -and $script:WorkingConfig.email.credential_target) {
        $targets += $script:WorkingConfig.email.credential_target
    }
    $targets = $targets | Select-Object -Unique
    foreach ($t in $targets) {
        $status = 'MISSING'; $user = ''
        try {
            $c = Get-StoredCredential -Target $t -ErrorAction SilentlyContinue
            if ($c) { $status = 'OK'; $user = $c.UserName }
        } catch {}
        [void]$credGrid.Rows.Add($t,$status,$user)
    }
}

function Prompt-AddCredential {
    param($Target)
    # Use the built-in PowerShell Get-Credential dialog, which returns a
    # PSCredential whose Password is a SecureString. The cleartext password
    # is never materialized as a managed [string] (the previous WinForms
    # TextBox-based dialog left the password in $tbP.Text in the .NET String
    # interning table for the GC's pleasure - recoverable from a memory
    # dump, exactly the threat model the user called out).
    $cred = $Host.UI.PromptForCredential(
        "Set credential: $Target",
        "Enter the username and password to store under target name '$Target'.",
        '',
        ''
    )
    if (-not $cred) { return }

    try {
        if (Get-StoredCredential -Target $Target -ErrorAction SilentlyContinue) {
            Remove-StoredCredential -Target $Target
        }
        # New-StoredCredential -SecurePassword takes the SecureString directly.
        New-StoredCredential -Target $Target -UserName $cred.UserName -SecurePassword $cred.Password `
            -Persist LocalMachine -Type Generic | Out-Null
        Refresh-Credentials
    }
    catch {
        [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message,'Error',0,16)
    }
    finally {
        # Defensive disposal of the SecureString. The PSCredential's underlying
        # SecureString may be reused by the host; calling Dispose on a
        # detached copy would also help. Best-effort.
        if ($cred -and $cred.Password) { try { $cred.Password.Dispose() } catch {} }
    }
}

$btnRefCred.Add_Click({ Refresh-Credentials })
$btnAddCred.Add_Click({
    if ($credGrid.SelectedRows.Count -eq 0) { return }
    $target = $credGrid.SelectedRows[0].Cells['target'].Value
    Prompt-AddCredential -Target $target
})
$btnDelCred.Add_Click({
    if ($credGrid.SelectedRows.Count -eq 0) { return }
    $target = $credGrid.SelectedRows[0].Cells['target'].Value
    if ([System.Windows.Forms.MessageBox]::Show("Delete credential '$target'?",'Confirm',4,32) -eq 'Yes') {
        try { Remove-StoredCredential -Target $target } catch {}
        Refresh-Credentials
    }
})

Refresh-Credentials

# ==================== Schedule tab ====================
$schedPanel = New-Object System.Windows.Forms.TableLayoutPanel
$schedPanel.Dock = 'Fill'
$schedPanel.RowCount = 2
$schedPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Percent',100))) | Out-Null
$schedPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute',40))) | Out-Null

$schedGrid = New-Object System.Windows.Forms.DataGridView
$schedGrid.Dock = 'Fill'
$schedGrid.AutoGenerateColumns = $false
$schedGrid.ReadOnly = $true
$schedGrid.SelectionMode = 'FullRowSelect'
$schedGrid.AllowUserToAddRows = $false

foreach ($colDef in @(
    @{ Name='name'; Header='Task'; Width=160 },
    @{ Name='tag'; Header='Tag'; Width=80 },
    @{ Name='trigger'; Header='Trigger'; Width=200 },
    @{ Name='state'; Header='State'; Width=90 },
    @{ Name='lastRun'; Header='Last run'; Width=140 },
    @{ Name='lastResult'; Header='Last result'; Width=90 }
)) {
    $col = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $col.Name = $colDef.Name; $col.HeaderText = $colDef.Header; $col.Width = $colDef.Width
    $schedGrid.Columns.Add($col) | Out-Null
}
$schedPanel.Controls.Add($schedGrid, 0, 0)

$schedButtons = New-Object System.Windows.Forms.FlowLayoutPanel
$schedButtons.Dock = 'Fill'
$btnAddSched = New-Object System.Windows.Forms.Button -Property @{ Text='Add task'; Width=100 }
$btnDelSched = New-Object System.Windows.Forms.Button -Property @{ Text='Delete'; Width=80 }
$btnRunSched = New-Object System.Windows.Forms.Button -Property @{ Text='Run now'; Width=80 }
$btnRefSched = New-Object System.Windows.Forms.Button -Property @{ Text='Refresh'; Width=80 }
$schedButtons.Controls.AddRange(@($btnAddSched,$btnDelSched,$btnRunSched,$btnRefSched))
$schedPanel.Controls.Add($schedButtons, 0, 1)

$tabSched.Controls.Add($schedPanel)

$script:TaskFolder = '\ServerSync\'

function Refresh-ScheduledTasks {
    $schedGrid.Rows.Clear()
    try {
        $tasks = Get-ScheduledTask -TaskPath $script:TaskFolder -ErrorAction Stop
    } catch { return }
    foreach ($t in $tasks) {
        $info = $t | Get-ScheduledTaskInfo
        $tag = ''
        if ($t.Actions.Count -gt 0 -and $t.Actions[0].Arguments -match '-Tag\s+(\S+)') {
            $tag = $matches[1]
        }
        $trig = if ($t.Triggers.Count -gt 0) { $t.Triggers[0].StartBoundary } else { '' }
        [void]$schedGrid.Rows.Add($t.TaskName,$tag,$trig,$t.State,$info.LastRunTime,$info.LastTaskResult)
    }
}

function Get-AvailableTags {
    $tags = @()
    if ($script:WorkingConfig) {
        foreach ($p in $script:WorkingConfig.folder_pairs) {
            if ($p.tags) { $tags += $p.tags }
        }
    }
    return (,'(no filter — default run)') + ($tags | Select-Object -Unique | Sort-Object)
}

function Prompt-AddSchedule {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Add scheduled task'
    $dlg.Size = New-Object System.Drawing.Size(450, 330)
    $dlg.StartPosition = 'CenterParent'

    $y = 10
    function Add-Row([string]$label, [System.Windows.Forms.Control]$ctl) {
        $lbl = New-Object System.Windows.Forms.Label -Property @{ Text=$label; Location="10,$y"; Size='150,20' }
        $ctl.Location = New-Object System.Drawing.Point(170, $y)
        $ctl.Size = New-Object System.Drawing.Size(250, 20)
        $dlg.Controls.Add($lbl); $dlg.Controls.Add($ctl)
        $script:y = $y + 30
    }

    $tbName = New-Object System.Windows.Forms.TextBox
    Add-Row 'Task name:' $tbName; $y = $script:y

    $cbType = New-Object System.Windows.Forms.ComboBox -Property @{ DropDownStyle='DropDownList' }
    $cbType.Items.AddRange(@('Daily','Weekly','Once'))
    Add-Row 'Schedule:' $cbType; $y = $script:y

    $tbTime = New-Object System.Windows.Forms.TextBox -Property @{ Text = '02:00' }
    Add-Row 'Time (HH:mm):' $tbTime; $y = $script:y

    $cbDow = New-Object System.Windows.Forms.ComboBox -Property @{ DropDownStyle='DropDownList' }
    $cbDow.Items.AddRange(@('Monday','Tuesday','Wednesday','Thursday','Friday','Saturday','Sunday'))
    Add-Row 'Day (weekly):' $cbDow; $y = $script:y

    $cbTag = New-Object System.Windows.Forms.ComboBox -Property @{ DropDownStyle='DropDownList' }
    Get-AvailableTags | ForEach-Object { [void]$cbTag.Items.Add($_) }
    if ($cbTag.Items.Count -gt 0) { $cbTag.SelectedIndex = 0 }
    Add-Row 'Tag filter:' $cbTag; $y = $script:y

    $tbUser = New-Object System.Windows.Forms.TextBox
    Add-Row 'Run as (user):' $tbUser; $y = $script:y

    $ok = New-Object System.Windows.Forms.Button -Property @{ Text='OK'; DialogResult='OK'; Location="240,$y" }
    $cancel = New-Object System.Windows.Forms.Button -Property @{ Text='Cancel'; DialogResult='Cancel'; Location="330,$y" }
    $dlg.AcceptButton = $ok; $dlg.CancelButton = $cancel
    $dlg.Controls.AddRange(@($ok,$cancel))

    if ($dlg.ShowDialog() -ne 'OK') { return }

    # Strict input validation. Any of these strings flows into a command line
    # registered as a Task Scheduler action that runs as Local Admin (or the
    # supplied run-as account). Garbage characters could inject extra
    # parameters - e.g., a tag of 'daily; & C:\evil.ps1' would split when
    # Task Scheduler parses the arguments. Refuse before composing.
    $taskName = $tbName.Text
    if (-not $taskName -or $taskName -notmatch '^[A-Za-z0-9_. -]{1,80}$') {
        [void][System.Windows.Forms.MessageBox]::Show(
            'Task name must be 1-80 characters: A-Z a-z 0-9 _ . space and -.','Invalid task name',0,16)
        return
    }
    $runAsUser = $tbUser.Text
    if (-not $runAsUser -or $runAsUser -notmatch '^[A-Za-z0-9_.\-\\@]{1,128}$') {
        [void][System.Windows.Forms.MessageBox]::Show(
            'Run-as user must be 1-128 characters: A-Z a-z 0-9 _ . - \ @ (DOMAIN\user or user@domain).','Invalid user',0,16)
        return
    }
    if ($tbTime.Text -notmatch '^([01]?\d|2[0-3]):([0-5]\d)$') {
        [void][System.Windows.Forms.MessageBox]::Show(
            'Time must be in HH:mm 24-hour format (e.g., 02:00 or 14:30).','Invalid time',0,16)
        return
    }
    $hh,$mm = $tbTime.Text -split ':'
    $at = (Get-Date).Date.AddHours([int]$hh).AddMinutes([int]$mm)

    $tag = $null
    if ($cbTag.SelectedItem -and $cbTag.SelectedItem -ne '(no filter — default run)') {
        $tag = [string]$cbTag.SelectedItem
        if ($tag -notmatch '^[A-Za-z0-9_.\-]{1,40}$') {
            [void][System.Windows.Forms.MessageBox]::Show(
                "Tag '$tag' contains invalid characters. The config file may have been tampered with.",'Invalid tag',0,16)
            return
        }
    }

    $trigger = switch ($cbType.SelectedItem) {
        'Daily'  { New-ScheduledTaskTrigger -Daily -At $at }
        'Weekly' { New-ScheduledTaskTrigger -Weekly -DaysOfWeek $cbDow.SelectedItem -At $at }
        'Once'   { New-ScheduledTaskTrigger -Once -At $at }
    }

    $scriptPath = Join-Path $PSScriptRoot 'Start-ServerSync.ps1'
    $taskArgs = "-NoProfile -File `"$scriptPath`""
    if ($tag) { $taskArgs += " -Tag $tag" }

    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $taskArgs
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

    try {
        Register-ScheduledTask -TaskName $taskName -TaskPath $script:TaskFolder `
            -Action $action -Trigger $trigger -Settings $settings `
            -User $runAsUser -RunLevel Highest -Force | Out-Null
        Refresh-ScheduledTasks
    }
    catch {
        [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message,'Error',0,16)
    }
}

$btnRefSched.Add_Click({ Refresh-ScheduledTasks })
$btnAddSched.Add_Click({ Prompt-AddSchedule })
$btnDelSched.Add_Click({
    if ($schedGrid.SelectedRows.Count -eq 0) { return }
    $name = $schedGrid.SelectedRows[0].Cells['name'].Value
    if ([System.Windows.Forms.MessageBox]::Show("Delete task '$name'?",'Confirm',4,32) -eq 'Yes') {
        Unregister-ScheduledTask -TaskName $name -TaskPath $script:TaskFolder -Confirm:$false
        Refresh-ScheduledTasks
    }
})
$btnRunSched.Add_Click({
    if ($schedGrid.SelectedRows.Count -eq 0) { return }
    $name = $schedGrid.SelectedRows[0].Cells['name'].Value
    Start-ScheduledTask -TaskName $name -TaskPath $script:TaskFolder
})

Refresh-ScheduledTasks

[void]$form.ShowDialog()
