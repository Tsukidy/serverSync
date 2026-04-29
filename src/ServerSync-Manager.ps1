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
# SIG # Begin signature block
# MIIb+wYJKoZIhvcNAQcCoIIb7DCCG+gCAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQUiA26jjM3RSxj5FNyBUfZIEaY
# qVWgghZeMIIDIDCCAgigAwIBAgIQLo8iz9yyer1NP2dUhiQqSDANBgkqhkiG9w0B
# AQsFADAoMSYwJAYDVQQDDB1EeWxhbiBQb3dlclNoZWxsIENvZGUgU2lnbmluZzAe
# Fw0yNjA0MjkxNTQ4NDlaFw0zMTA0MjkxNTU4NDlaMCgxJjAkBgNVBAMMHUR5bGFu
# IFBvd2VyU2hlbGwgQ29kZSBTaWduaW5nMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8A
# MIIBCgKCAQEA187btBBaXCyufe8zEYV/KrqJtV0ZJBJ6gxK/WHN51TUL6TRgFRyR
# uIsO/trCaIneAmgFr8YwxxJoRiMDYQod0sV9HtGvgggGcb/46ZCUq5USefFXLc+T
# D2mwYR5qIxovBTOOM+/YkKvS5AWa0f8QDndEgrUAhMk80OxurUNhxgRTevQ+aS+v
# e2J9Qms0QtvzADQWznixqqDGQvCNe36ZxsCfshlJ8LMtSdDsKnxPzOKF9lfEZxGh
# CN73z3jD+Mx8EGL3bwmSj1pGIga6IRF5Youb9P1uulc2S7oxZobcjGHG0/W3aInB
# MR7OSSoFbnqbcMSmTmqjKLkBKXLhWfy56QIDAQABo0YwRDAOBgNVHQ8BAf8EBAMC
# B4AwEwYDVR0lBAwwCgYIKwYBBQUHAwMwHQYDVR0OBBYEFAwu+b0hH5HVWlmafHj2
# 9akN2UJEMA0GCSqGSIb3DQEBCwUAA4IBAQBKZFg3pWpgLWeEMzhl4AcySBKbJNQW
# hoLwj58Mmaen7GQQd3q5pmrFtQmxpyF//tnYQ+Mdxr1YXtHoCxkNbPRKXg+Y7DM7
# xlr9sE/aUHTfY4WMbSD9iLxo0lv9EfKDa+0yGlwL24KUqqXwN1vaDk6JL/+6LX5z
# ln9LTEjgqQ7enUNKIcQlcuoPXYG7nUQlfOMG9BLpMMzYGaJJ2bKF35yK5Tho6O7a
# H0nC0sQ25NF/N4wxHF6qknb3Fn16mRfYZmOA3Qj3xI0SUZKAHcBVMN1cNAV6n+Hx
# AYDS1bcNrwM0hjSFPGkRUcJNPINYS/Y+wPNoTAf4I6sBlC3BJhkbkWQqMIIFjTCC
# BHWgAwIBAgIQDpsYjvnQLefv21DiCEAYWjANBgkqhkiG9w0BAQwFADBlMQswCQYD
# VQQGEwJVUzEVMBMGA1UEChMMRGlnaUNlcnQgSW5jMRkwFwYDVQQLExB3d3cuZGln
# aWNlcnQuY29tMSQwIgYDVQQDExtEaWdpQ2VydCBBc3N1cmVkIElEIFJvb3QgQ0Ew
# HhcNMjIwODAxMDAwMDAwWhcNMzExMTA5MjM1OTU5WjBiMQswCQYDVQQGEwJVUzEV
# MBMGA1UEChMMRGlnaUNlcnQgSW5jMRkwFwYDVQQLExB3d3cuZGlnaWNlcnQuY29t
# MSEwHwYDVQQDExhEaWdpQ2VydCBUcnVzdGVkIFJvb3QgRzQwggIiMA0GCSqGSIb3
# DQEBAQUAA4ICDwAwggIKAoICAQC/5pBzaN675F1KPDAiMGkz7MKnJS7JIT3yithZ
# wuEppz1Yq3aaza57G4QNxDAf8xukOBbrVsaXbR2rsnnyyhHS5F/WBTxSD1Ifxp4V
# pX6+n6lXFllVcq9ok3DCsrp1mWpzMpTREEQQLt+C8weE5nQ7bXHiLQwb7iDVySAd
# YyktzuxeTsiT+CFhmzTrBcZe7FsavOvJz82sNEBfsXpm7nfISKhmV1efVFiODCu3
# T6cw2Vbuyntd463JT17lNecxy9qTXtyOj4DatpGYQJB5w3jHtrHEtWoYOAMQjdjU
# N6QuBX2I9YI+EJFwq1WCQTLX2wRzKm6RAXwhTNS8rhsDdV14Ztk6MUSaM0C/CNda
# SaTC5qmgZ92kJ7yhTzm1EVgX9yRcRo9k98FpiHaYdj1ZXUJ2h4mXaXpI8OCiEhtm
# mnTK3kse5w5jrubU75KSOp493ADkRSWJtppEGSt+wJS00mFt6zPZxd9LBADMfRyV
# w4/3IbKyEbe7f/LVjHAsQWCqsWMYRJUadmJ+9oCw++hkpjPRiQfhvbfmQ6QYuKZ3
# AeEPlAwhHbJUKSWJbOUOUlFHdL4mrLZBdd56rF+NP8m800ERElvlEFDrMcXKchYi
# Cd98THU/Y+whX8QgUWtvsauGi0/C1kVfnSD8oR7FwI+isX4KJpn15GkvmB0t9dmp
# sh3lGwIDAQABo4IBOjCCATYwDwYDVR0TAQH/BAUwAwEB/zAdBgNVHQ4EFgQU7Nfj
# gtJxXWRM3y5nP+e6mK4cD08wHwYDVR0jBBgwFoAUReuir/SSy4IxLVGLp6chnfNt
# yA8wDgYDVR0PAQH/BAQDAgGGMHkGCCsGAQUFBwEBBG0wazAkBggrBgEFBQcwAYYY
# aHR0cDovL29jc3AuZGlnaWNlcnQuY29tMEMGCCsGAQUFBzAChjdodHRwOi8vY2Fj
# ZXJ0cy5kaWdpY2VydC5jb20vRGlnaUNlcnRBc3N1cmVkSURSb290Q0EuY3J0MEUG
# A1UdHwQ+MDwwOqA4oDaGNGh0dHA6Ly9jcmwzLmRpZ2ljZXJ0LmNvbS9EaWdpQ2Vy
# dEFzc3VyZWRJRFJvb3RDQS5jcmwwEQYDVR0gBAowCDAGBgRVHSAAMA0GCSqGSIb3
# DQEBDAUAA4IBAQBwoL9DXFXnOF+go3QbPbYW1/e/Vwe9mqyhhyzshV6pGrsi+Ica
# aVQi7aSId229GhT0E0p6Ly23OO/0/4C5+KH38nLeJLxSA8hO0Cre+i1Wz/n096ww
# epqLsl7Uz9FDRJtDIeuWcqFItJnLnU+nBgMTdydE1Od/6Fmo8L8vC6bp8jQ87PcD
# x4eo0kxAGTVGamlUsLihVo7spNU96LHc/RzY9HdaXFSMb++hUD38dglohJ9vytsg
# jTVgHAIDyyCwrFigDkBjxZgiwbJZ9VVrzyerbHbObyMt9H5xaiNrIv8SuFQtJ37Y
# OtnwtoeW/VvRXKwYw02fc7cBqZ9Xql4o4rmUMIIGtDCCBJygAwIBAgIQDcesVwX/
# IZkuQEMiDDpJhjANBgkqhkiG9w0BAQsFADBiMQswCQYDVQQGEwJVUzEVMBMGA1UE
# ChMMRGlnaUNlcnQgSW5jMRkwFwYDVQQLExB3d3cuZGlnaWNlcnQuY29tMSEwHwYD
# VQQDExhEaWdpQ2VydCBUcnVzdGVkIFJvb3QgRzQwHhcNMjUwNTA3MDAwMDAwWhcN
# MzgwMTE0MjM1OTU5WjBpMQswCQYDVQQGEwJVUzEXMBUGA1UEChMORGlnaUNlcnQs
# IEluYy4xQTA/BgNVBAMTOERpZ2lDZXJ0IFRydXN0ZWQgRzQgVGltZVN0YW1waW5n
# IFJTQTQwOTYgU0hBMjU2IDIwMjUgQ0ExMIICIjANBgkqhkiG9w0BAQEFAAOCAg8A
# MIICCgKCAgEAtHgx0wqYQXK+PEbAHKx126NGaHS0URedTa2NDZS1mZaDLFTtQ2oR
# jzUXMmxCqvkbsDpz4aH+qbxeLho8I6jY3xL1IusLopuW2qftJYJaDNs1+JH7Z+Qd
# SKWM06qchUP+AbdJgMQB3h2DZ0Mal5kYp77jYMVQXSZH++0trj6Ao+xh/AS7sQRu
# QL37QXbDhAktVJMQbzIBHYJBYgzWIjk8eDrYhXDEpKk7RdoX0M980EpLtlrNyHw0
# Xm+nt5pnYJU3Gmq6bNMI1I7Gb5IBZK4ivbVCiZv7PNBYqHEpNVWC2ZQ8BbfnFRQV
# ESYOszFI2Wv82wnJRfN20VRS3hpLgIR4hjzL0hpoYGk81coWJ+KdPvMvaB0WkE/2
# qHxJ0ucS638ZxqU14lDnki7CcoKCz6eum5A19WZQHkqUJfdkDjHkccpL6uoG8pbF
# 0LJAQQZxst7VvwDDjAmSFTUms+wV/FbWBqi7fTJnjq3hj0XbQcd8hjj/q8d6ylgx
# CZSKi17yVp2NL+cnT6Toy+rN+nM8M7LnLqCrO2JP3oW//1sfuZDKiDEb1AQ8es9X
# r/u6bDTnYCTKIsDq1BtmXUqEG1NqzJKS4kOmxkYp2WyODi7vQTCBZtVFJfVZ3j7O
# gWmnhFr4yUozZtqgPrHRVHhGNKlYzyjlroPxul+bgIspzOwbtmsgY1MCAwEAAaOC
# AV0wggFZMBIGA1UdEwEB/wQIMAYBAf8CAQAwHQYDVR0OBBYEFO9vU0rp5AZ8esri
# kFb2L9RJ7MtOMB8GA1UdIwQYMBaAFOzX44LScV1kTN8uZz/nupiuHA9PMA4GA1Ud
# DwEB/wQEAwIBhjATBgNVHSUEDDAKBggrBgEFBQcDCDB3BggrBgEFBQcBAQRrMGkw
# JAYIKwYBBQUHMAGGGGh0dHA6Ly9vY3NwLmRpZ2ljZXJ0LmNvbTBBBggrBgEFBQcw
# AoY1aHR0cDovL2NhY2VydHMuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0VHJ1c3RlZFJv
# b3RHNC5jcnQwQwYDVR0fBDwwOjA4oDagNIYyaHR0cDovL2NybDMuZGlnaWNlcnQu
# Y29tL0RpZ2lDZXJ0VHJ1c3RlZFJvb3RHNC5jcmwwIAYDVR0gBBkwFzAIBgZngQwB
# BAIwCwYJYIZIAYb9bAcBMA0GCSqGSIb3DQEBCwUAA4ICAQAXzvsWgBz+Bz0RdnEw
# vb4LyLU0pn/N0IfFiBowf0/Dm1wGc/Do7oVMY2mhXZXjDNJQa8j00DNqhCT3t+s8
# G0iP5kvN2n7Jd2E4/iEIUBO41P5F448rSYJ59Ib61eoalhnd6ywFLerycvZTAz40
# y8S4F3/a+Z1jEMK/DMm/axFSgoR8n6c3nuZB9BfBwAQYK9FHaoq2e26MHvVY9gCD
# A/JYsq7pGdogP8HRtrYfctSLANEBfHU16r3J05qX3kId+ZOczgj5kjatVB+NdADV
# ZKON/gnZruMvNYY2o1f4MXRJDMdTSlOLh0HCn2cQLwQCqjFbqrXuvTPSegOOzr4E
# Wj7PtspIHBldNE2K9i697cvaiIo2p61Ed2p8xMJb82Yosn0z4y25xUbI7GIN/TpV
# fHIqQ6Ku/qjTY6hc3hsXMrS+U0yy+GWqAXam4ToWd2UQ1KYT70kZjE4YtL8Pbzg0
# c1ugMZyZZd/BdHLiRu7hAWE6bTEm4XYRkA6Tl4KSFLFk43esaUeqGkH/wyW4N7Oi
# gizwJWeukcyIPbAvjSabnf7+Pu0VrFgoiovRDiyx3zEdmcif/sYQsfch28bZeUz2
# rtY/9TCA6TD8dC3JE3rYkrhLULy7Dc90G6e8BlqmyIjlgp2+VqsS9/wQD7yFylIz
# 0scmbKvFoW2jNrbM1pD2T7m3XDCCBu0wggTVoAMCAQICEAqA7xhLjfEFgtHEdqeV
# dGgwDQYJKoZIhvcNAQELBQAwaTELMAkGA1UEBhMCVVMxFzAVBgNVBAoTDkRpZ2lD
# ZXJ0LCBJbmMuMUEwPwYDVQQDEzhEaWdpQ2VydCBUcnVzdGVkIEc0IFRpbWVTdGFt
# cGluZyBSU0E0MDk2IFNIQTI1NiAyMDI1IENBMTAeFw0yNTA2MDQwMDAwMDBaFw0z
# NjA5MDMyMzU5NTlaMGMxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdpQ2VydCwg
# SW5jLjE7MDkGA1UEAxMyRGlnaUNlcnQgU0hBMjU2IFJTQTQwOTYgVGltZXN0YW1w
# IFJlc3BvbmRlciAyMDI1IDEwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoIC
# AQDQRqwtEsae0OquYFazK1e6b1H/hnAKAd/KN8wZQjBjMqiZ3xTWcfsLwOvRxUwX
# cGx8AUjni6bz52fGTfr6PHRNv6T7zsf1Y/E3IU8kgNkeECqVQ+3bzWYesFtkepEr
# vUSbf+EIYLkrLKd6qJnuzK8Vcn0DvbDMemQFoxQ2Dsw4vEjoT1FpS54dNApZfKY6
# 1HAldytxNM89PZXUP/5wWWURK+IfxiOg8W9lKMqzdIo7VA1R0V3Zp3DjjANwqAf4
# lEkTlCDQ0/fKJLKLkzGBTpx6EYevvOi7XOc4zyh1uSqgr6UnbksIcFJqLbkIXIPb
# cNmA98Oskkkrvt6lPAw/p4oDSRZreiwB7x9ykrjS6GS3NR39iTTFS+ENTqW8m6TH
# uOmHHjQNC3zbJ6nJ6SXiLSvw4Smz8U07hqF+8CTXaETkVWz0dVVZw7knh1WZXOLH
# gDvundrAtuvz0D3T+dYaNcwafsVCGZKUhQPL1naFKBy1p6llN3QgshRta6Eq4B40
# h5avMcpi54wm0i2ePZD5pPIssoszQyF4//3DoK2O65Uck5Wggn8O2klETsJ7u8xE
# ehGifgJYi+6I03UuT1j7FnrqVrOzaQoVJOeeStPeldYRNMmSF3voIgMFtNGh86w3
# ISHNm0IaadCKCkUe2LnwJKa8TIlwCUNVwppwn4D3/Pt5pwIDAQABo4IBlTCCAZEw
# DAYDVR0TAQH/BAIwADAdBgNVHQ4EFgQU5Dv88jHt/f3X85FxYxlQQ89hjOgwHwYD
# VR0jBBgwFoAU729TSunkBnx6yuKQVvYv1Ensy04wDgYDVR0PAQH/BAQDAgeAMBYG
# A1UdJQEB/wQMMAoGCCsGAQUFBwMIMIGVBggrBgEFBQcBAQSBiDCBhTAkBggrBgEF
# BQcwAYYYaHR0cDovL29jc3AuZGlnaWNlcnQuY29tMF0GCCsGAQUFBzAChlFodHRw
# Oi8vY2FjZXJ0cy5kaWdpY2VydC5jb20vRGlnaUNlcnRUcnVzdGVkRzRUaW1lU3Rh
# bXBpbmdSU0E0MDk2U0hBMjU2MjAyNUNBMS5jcnQwXwYDVR0fBFgwVjBUoFKgUIZO
# aHR0cDovL2NybDMuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0VHJ1c3RlZEc0VGltZVN0
# YW1waW5nUlNBNDA5NlNIQTI1NjIwMjVDQTEuY3JsMCAGA1UdIAQZMBcwCAYGZ4EM
# AQQCMAsGCWCGSAGG/WwHATANBgkqhkiG9w0BAQsFAAOCAgEAZSqt8RwnBLmuYEHs
# 0QhEnmNAciH45PYiT9s1i6UKtW+FERp8FgXRGQ/YAavXzWjZhY+hIfP2JkQ38U+w
# tJPBVBajYfrbIYG+Dui4I4PCvHpQuPqFgqp1PzC/ZRX4pvP/ciZmUnthfAEP1HSh
# TrY+2DE5qjzvZs7JIIgt0GCFD9ktx0LxxtRQ7vllKluHWiKk6FxRPyUPxAAYH2Vy
# 1lNM4kzekd8oEARzFAWgeW3az2xejEWLNN4eKGxDJ8WDl/FQUSntbjZ80FU3i54t
# px5F/0Kr15zW/mJAxZMVBrTE2oi0fcI8VMbtoRAmaaslNXdCG1+lqvP4FbrQ6IwS
# BXkZagHLhFU9HCrG/syTRLLhAezu/3Lr00GrJzPQFnCEH1Y58678IgmfORBPC1JK
# kYaEt2OdDh4GmO0/5cHelAK2/gTlQJINqDr6JfwyYHXSd+V08X1JUPvB4ILfJdmL
# +66Gp3CSBXG6IwXMZUXBhtCyIaehr0XkBoDIGMUG1dUtwq1qmcwbdUfcSYCn+Own
# cVUXf53VJUNOaMWMts0VlRYxe5nK+At+DI96HAlXHAL5SlfYxJ7La54i71McVWRP
# 66bW+yERNpbJCjyCYG2j+bdpxo/1Cy4uPcU3AWVPGrbn5PhDBf3Froguzzhk++am
# i+r3Qrx5bIbY3TVzgiFI7Gq3zWcxggUHMIIFAwIBATA8MCgxJjAkBgNVBAMMHUR5
# bGFuIFBvd2VyU2hlbGwgQ29kZSBTaWduaW5nAhAujyLP3LJ6vU0/Z1SGJCpIMAkG
# BSsOAwIaBQCgeDAYBgorBgEEAYI3AgEMMQowCKACgAChAoAAMBkGCSqGSIb3DQEJ
# AzEMBgorBgEEAYI3AgEEMBwGCisGAQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMCMG
# CSqGSIb3DQEJBDEWBBQUNxfURxDL1wkiC0dajL2JhaTKGjANBgkqhkiG9w0BAQEF
# AASCAQBalbi4jm9G6pwg0GNUX4cDObvWK88CMgOPRUfbdr2jKAB8W9+dm7Ibk3z0
# GMmaw6SBULKO9uNekDykqJ9DPWJwK/jFooVxAu/m9EIcufvxGycq+2Pj223WmzML
# isfR65Md/FKIMeG3QgnfD4CvDG/JH4nPSg9NHFD4cpEJjeajfAK5b/Fwv3NdJChq
# CItmNdXSJ72bxnn2Ek/vpmQ9bmeJ5aKpg8FGBheH6XNYJZFX59ghu/F3qXdLIdw1
# XAiVp6660A1Nw7w3YogdbCusivDWVkGQjCs/XU9I11DOUPSaJXTI7ZYT9BtaNuVB
# v5hqr100mGnZGBAlUozQSXi0yh/KoYIDJjCCAyIGCSqGSIb3DQEJBjGCAxMwggMP
# AgEBMH0waTELMAkGA1UEBhMCVVMxFzAVBgNVBAoTDkRpZ2lDZXJ0LCBJbmMuMUEw
# PwYDVQQDEzhEaWdpQ2VydCBUcnVzdGVkIEc0IFRpbWVTdGFtcGluZyBSU0E0MDk2
# IFNIQTI1NiAyMDI1IENBMQIQCoDvGEuN8QWC0cR2p5V0aDANBglghkgBZQMEAgEF
# AKBpMBgGCSqGSIb3DQEJAzELBgkqhkiG9w0BBwEwHAYJKoZIhvcNAQkFMQ8XDTI2
# MDQyOTE3MTcxMFowLwYJKoZIhvcNAQkEMSIEIHl7O1giOXZ8s6Ce+ScH7zikWE0h
# Y74yZ4+evDS8dV0QMA0GCSqGSIb3DQEBAQUABIICAG7FlWUUK2Xq5IjBtf6ez4HW
# CJLDhm/i4Nye1DTCeVxtDUEWJzUUZCnLqXnaGXRKVXD77LnHCt5WoM2Pp2/cfSZ8
# lVCTEK7uuohUoaw5T26Vi0OLuen9Obztti4NMR12di/2c4Y50wz2s8JCunZE3TUx
# dYosK1Yhn6TP4qWMBeWIe6RY9T0n2fPUe5Z+fOgTj2wjEs5zRv7FpDIhcK/BWBa3
# iLwzM5Tj1sU12tSHpY2ayUNHZOyeGOrPIiGBsJQiiZQD4Yhn/BA5EMRTI0z4an4f
# jt5pjZ0m+sThCTpL7JyFh6lHNh7hIQ9umdv5K6OJKWJ6c1vzoG30g7AShjR/eCDb
# J2F5wInkSvoQDlzZS81VbRvARhYRAtT2o6tVUiOuSYrfKXZYLb+NdpFxaOVbydpF
# 9Xkc8aOqEDxyen1p/C6rNbU/oBLyi4l8mTjvejqVk3l6AW/IvVbmrVGtLfGxg8Cx
# n4cHutubppxKBQPFNMzCxHoMHyPQw0qDTTSNgackz9BG4LfcAsWYgX6goD1S0Bhr
# T8gQUPMBVOGbYoobM59Bic1qPnGhOTxaTUv09spuMAPl+0DDLccdeskveIUk1Uds
# rFV2TUF9JdilRXWfc1toIX6ddvMc6lcShYSv1wZkKUC7lblGswo27HAME5kPGsGc
# ilOFRoSPdhb9Gfp/872j
# SIG # End signature block
