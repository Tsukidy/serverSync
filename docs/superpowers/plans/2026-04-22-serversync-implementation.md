# ServerSync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a secure PowerShell-based backup sync system for an air-gapped Windows Server that pulls backup files/folders from multiple Windows Server sources over SMB, applies per-pair retention, and toggles NICs on/off with hard security guarantees.

**Architecture:** Orchestrator script (`Start-ServerSync.ps1`) composed of five dot-sourced modules (`ConfigLoader`, `Logging`, `Retention`, `SyncOperations`, `NetworkControl`). Separate WinForms GUI tool (`ServerSync-Manager.ps1`) for admin tasks. All destructive logic lives in `Retention.ps1` only. NICs are enabled in a `try` block and unconditionally disabled-and-verified in the outer `finally`.

**Tech Stack:** PowerShell 5.1+ (Windows PowerShell and PowerShell 7 both supported), Pester 5.x for tests, Windows Forms (built-in), robocopy (built-in), Windows Credential Manager via the `CredentialManager` PowerShell module (installable offline), ScheduledTasks module (built-in).

**Development environment note:** The developer may be working on Linux (pwsh available) but the script targets Windows Server. Pure-logic tests (ConfigLoader, Retention, exit-code parsing) run cross-platform with `pwsh` + Pester. Tests tagged `Windows` require running on a Windows host. A Windows VM or the target server itself is needed for end-to-end smoke testing.

---

## Phase 1: Project Foundation

### Task 1: Create directory structure and .gitignore

**Files:**
- Create: `src/` (directory)
- Create: `src/Modules/` (directory)
- Create: `tests/` (directory)
- Create: `tests/fixtures/` (directory)
- Create: `config/` (directory)
- Create: `.gitignore`

- [ ] **Step 1: Create directories**

```bash
cd /home/user/Documents/Software/Scripts/github/serverSync/serverSync
mkdir -p src/Modules tests/fixtures config
```

- [ ] **Step 2: Create .gitignore**

Write `.gitignore`:

```gitignore
# Runtime artifacts
logs/
*.log
*.tmp
*.bak

# Local config with credentials references
config/config.local.json

# Pester results
TestResults.xml
coverage.xml

# OS
.DS_Store
Thumbs.db

# Editors
.vscode/settings.json
.idea/
```

- [ ] **Step 3: Commit**

```bash
git add .gitignore src/ tests/ config/
git commit -m "Add project directory structure and gitignore"
```

Note: Empty directories aren't tracked by git, so the commit will only include `.gitignore`. That's fine — directories materialize as files are added.

---

### Task 2: Add README sections describing the project structure

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Replace README.md with structure documentation**

```markdown
# serverSync

Secure one-way backup sync for an air-gapped Windows Server.

Pulls backup files from one or more Windows Server sources over SMB, then
disables networking. Per-folder-pair retention keeps the N newest files (by
extension) or N newest subfolders on the air-gapped destination, independent
of source retention.

## Layout

- `src/Start-ServerSync.ps1` — orchestrator (runs from Task Scheduler or manually)
- `src/ServerSync-Manager.ps1` — WinForms admin GUI
- `src/Setup-Credentials.ps1` — CLI credential setup helper
- `src/Install-ServerSync.ps1` — installer (directories, ACLs, Event Log source)
- `src/Modules/*.ps1` — modules dot-sourced by the orchestrator and GUI
- `tests/*.Tests.ps1` — Pester tests
- `config/config.sample.json` — sample config

## Running

Manual:
```
powershell -File src\Start-ServerSync.ps1
powershell -File src\Start-ServerSync.ps1 -Tag daily
```

Validate config without running:
```
powershell -File src\Start-ServerSync.ps1 -ValidateConfig
```

Dry-run (no NIC changes, no copies, no deletions):
```
powershell -File src\Start-ServerSync.ps1 -WhatIf
```

## Design

Full design: `docs/superpowers/specs/2026-04-22-serversync-design.md`
Implementation plan: `docs/superpowers/plans/2026-04-22-serversync-implementation.md`
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "Expand README with project layout and run commands"
```

---

## Phase 2: ConfigLoader Module (pure logic, cross-platform testable)

### Task 3: ConfigLoader — write failing test for minimal valid config

**Files:**
- Create: `tests/ConfigLoader.Tests.ps1`
- Create: `tests/fixtures/config-valid-minimal.json`

- [ ] **Step 1: Write fixture `tests/fixtures/config-valid-minimal.json`**

```json
{
  "network": {
    "nics": ["Ethernet"],
    "ready_timeout_seconds": 30,
    "ready_check_host": "192.168.1.1"
  },
  "robocopy": {
    "threads": 6,
    "retries": 3,
    "retry_wait_seconds": 10,
    "extra_flags": []
  },
  "retention": {
    "default_mode": "files",
    "default_extensions": [".TIB"],
    "default_count": 3
  },
  "logging": {
    "log_directory": "C:\\ProgramData\\ServerSync\\logs",
    "log_retention_days": 90,
    "event_log_source": "ServerSync"
  },
  "email": {
    "enabled": false,
    "smtp_server": "",
    "smtp_port": 25,
    "use_ssl": false,
    "credential_target": "",
    "from": "",
    "to": [],
    "send_on": "failure"
  },
  "folder_pairs": [
    {
      "name": "ServerA",
      "source": "\\\\src\\share",
      "destination": "D:\\dest",
      "credential_target": "ServerSync-Src"
    }
  ]
}
```

- [ ] **Step 2: Write test file `tests/ConfigLoader.Tests.ps1`**

```powershell
BeforeAll {
    $script:ModulePath = Join-Path $PSScriptRoot '..' 'src' 'Modules' 'ConfigLoader.ps1'
    $script:FixturesDir = Join-Path $PSScriptRoot 'fixtures'
    . $script:ModulePath
}

Describe 'ConfigLoader' -Tag 'Unit' {
    Context 'Read-ServerSyncConfig with minimal valid file' {
        It 'returns a PSObject with folder_pairs populated' {
            $path = Join-Path $script:FixturesDir 'config-valid-minimal.json'
            $config = Read-ServerSyncConfig -Path $path
            $config | Should -Not -BeNullOrEmpty
            $config.folder_pairs.Count | Should -Be 1
            $config.folder_pairs[0].name | Should -Be 'ServerA'
        }
    }
}
```

- [ ] **Step 3: Run test (should fail — module not yet created)**

Run: `pwsh -Command "Invoke-Pester -Path tests/ConfigLoader.Tests.ps1 -Output Detailed"`

Expected: FAIL — file not found `src/Modules/ConfigLoader.ps1`.

- [ ] **Step 4: Commit**

```bash
git add tests/ConfigLoader.Tests.ps1 tests/fixtures/config-valid-minimal.json
git commit -m "Add failing test for ConfigLoader minimal valid config"
```

---

### Task 4: ConfigLoader — minimal implementation to pass the test

**Files:**
- Create: `src/Modules/ConfigLoader.ps1`

- [ ] **Step 1: Write minimal implementation**

```powershell
<#
.SYNOPSIS
    Load and validate ServerSync config files.
#>

function Read-ServerSyncConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -Path $Path -PathType Leaf)) {
        throw "Config file not found: $Path"
    }

    $raw = Get-Content -Path $Path -Raw -Encoding UTF8
    try {
        $config = $raw | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "Config file is not valid JSON: $Path. $($_.Exception.Message)"
    }

    return $config
}
```

- [ ] **Step 2: Run test (should pass)**

Run: `pwsh -Command "Invoke-Pester -Path tests/ConfigLoader.Tests.ps1 -Output Detailed"`

Expected: PASS (1 test, 0 failures).

- [ ] **Step 3: Commit**

```bash
git add src/Modules/ConfigLoader.ps1
git commit -m "ConfigLoader: minimal Read-ServerSyncConfig"
```

---

### Task 5: ConfigLoader — add schema validation with failing tests

**Files:**
- Modify: `tests/ConfigLoader.Tests.ps1`
- Create: `tests/fixtures/config-missing-nics.json`
- Create: `tests/fixtures/config-bad-retention-mode.json`

- [ ] **Step 1: Create invalid fixtures**

`tests/fixtures/config-missing-nics.json` — copy of minimal, but delete the `nics` entry from `network`:

```json
{
  "network": {
    "ready_timeout_seconds": 30,
    "ready_check_host": "192.168.1.1"
  },
  "robocopy": { "threads": 6, "retries": 3, "retry_wait_seconds": 10, "extra_flags": [] },
  "retention": { "default_mode": "files", "default_extensions": [".TIB"], "default_count": 3 },
  "logging": { "log_directory": "C:\\logs", "log_retention_days": 90, "event_log_source": "ServerSync" },
  "email": { "enabled": false, "smtp_server": "", "smtp_port": 25, "use_ssl": false, "credential_target": "", "from": "", "to": [], "send_on": "failure" },
  "folder_pairs": [ { "name": "A", "source": "\\\\s\\share", "destination": "D:\\d", "credential_target": "t" } ]
}
```

`tests/fixtures/config-bad-retention-mode.json` — valid apart from bad retention mode on a pair:

```json
{
  "network": { "nics": ["Ethernet"], "ready_timeout_seconds": 30, "ready_check_host": "192.168.1.1" },
  "robocopy": { "threads": 6, "retries": 3, "retry_wait_seconds": 10, "extra_flags": [] },
  "retention": { "default_mode": "files", "default_extensions": [".TIB"], "default_count": 3 },
  "logging": { "log_directory": "C:\\logs", "log_retention_days": 90, "event_log_source": "ServerSync" },
  "email": { "enabled": false, "smtp_server": "", "smtp_port": 25, "use_ssl": false, "credential_target": "", "from": "", "to": [], "send_on": "failure" },
  "folder_pairs": [
    { "name": "A", "source": "\\\\s\\share", "destination": "D:\\d", "credential_target": "t",
      "retention": { "mode": "bogus", "count": 3 } }
  ]
}
```

- [ ] **Step 2: Add validation tests to `tests/ConfigLoader.Tests.ps1`**

Append these `Context` blocks inside the existing `Describe`:

```powershell
    Context 'Test-ServerSyncConfig with valid config' {
        It 'returns $true and no errors' {
            $path = Join-Path $script:FixturesDir 'config-valid-minimal.json'
            $config = Read-ServerSyncConfig -Path $path
            $result = Test-ServerSyncConfig -Config $config
            $result.Valid | Should -Be $true
            $result.Errors.Count | Should -Be 0
        }
    }

    Context 'Test-ServerSyncConfig with missing nics' {
        It 'returns $false and a specific error' {
            $path = Join-Path $script:FixturesDir 'config-missing-nics.json'
            $config = Read-ServerSyncConfig -Path $path
            $result = Test-ServerSyncConfig -Config $config
            $result.Valid | Should -Be $false
            ($result.Errors -join ' ') | Should -Match 'network\.nics'
        }
    }

    Context 'Test-ServerSyncConfig with invalid retention mode on a pair' {
        It 'returns $false and names the pair' {
            $path = Join-Path $script:FixturesDir 'config-bad-retention-mode.json'
            $config = Read-ServerSyncConfig -Path $path
            $result = Test-ServerSyncConfig -Config $config
            $result.Valid | Should -Be $false
            ($result.Errors -join ' ') | Should -Match "pair 'A'"
            ($result.Errors -join ' ') | Should -Match 'retention\.mode'
        }
    }
```

- [ ] **Step 3: Run tests (validation tests should fail — function not defined)**

Run: `pwsh -Command "Invoke-Pester -Path tests/ConfigLoader.Tests.ps1 -Output Detailed"`

Expected: 3 FAIL (the new ones), 1 PASS.

- [ ] **Step 4: Commit (failing tests)**

```bash
git add tests/ConfigLoader.Tests.ps1 tests/fixtures/config-missing-nics.json tests/fixtures/config-bad-retention-mode.json
git commit -m "Add failing tests for ConfigLoader validation"
```

---

### Task 6: ConfigLoader — implement Test-ServerSyncConfig

**Files:**
- Modify: `src/Modules/ConfigLoader.ps1`

- [ ] **Step 1: Append Test-ServerSyncConfig to `src/Modules/ConfigLoader.ps1`**

```powershell
function Test-ServerSyncConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [Object]$Config
    )

    $errors = New-Object System.Collections.Generic.List[string]

    # Top-level sections
    foreach ($section in @('network','robocopy','retention','logging','email','folder_pairs')) {
        if (-not ($Config.PSObject.Properties.Name -contains $section)) {
            $errors.Add("Missing required section: $section")
        }
    }

    if ($Config.network) {
        if (-not $Config.network.nics -or $Config.network.nics.Count -eq 0) {
            $errors.Add("network.nics must be a non-empty array")
        }
        if (-not $Config.network.ready_check_host) {
            $errors.Add("network.ready_check_host is required")
        }
    }

    if ($Config.retention) {
        if ($Config.retention.default_mode -and
            @('files','folders') -notcontains $Config.retention.default_mode) {
            $errors.Add("retention.default_mode must be 'files' or 'folders'")
        }
        if ($Config.retention.default_count -lt 1) {
            $errors.Add("retention.default_count must be >= 1")
        }
    }

    if ($Config.email -and $Config.email.enabled -and
        @('failure','always','never') -notcontains $Config.email.send_on) {
        $errors.Add("email.send_on must be 'failure', 'always', or 'never'")
    }

    if ($Config.folder_pairs) {
        $names = @{}
        foreach ($pair in $Config.folder_pairs) {
            $n = $pair.name
            if (-not $n) { $errors.Add("folder_pair missing 'name'"); continue }
            if ($names.ContainsKey($n)) { $errors.Add("duplicate folder_pair name: '$n'") }
            $names[$n] = $true

            foreach ($required in @('source','destination','credential_target')) {
                if (-not $pair.$required) {
                    $errors.Add("pair '$n' missing '$required'")
                }
            }

            if ($pair.retention) {
                if ($pair.retention.mode -and @('files','folders') -notcontains $pair.retention.mode) {
                    $errors.Add("pair '$n' retention.mode must be 'files' or 'folders'")
                }
                if ($pair.retention.count -and $pair.retention.count -lt 1) {
                    $errors.Add("pair '$n' retention.count must be >= 1")
                }
            }
        }
    }

    return [PSCustomObject]@{
        Valid  = ($errors.Count -eq 0)
        Errors = $errors.ToArray()
    }
}
```

- [ ] **Step 2: Run tests (should all pass)**

Run: `pwsh -Command "Invoke-Pester -Path tests/ConfigLoader.Tests.ps1 -Output Detailed"`

Expected: 4 PASS, 0 FAIL.

- [ ] **Step 3: Commit**

```bash
git add src/Modules/ConfigLoader.ps1
git commit -m "ConfigLoader: add Test-ServerSyncConfig validation"
```

---

### Task 7: ConfigLoader — tag filtering and defaults resolution

**Files:**
- Modify: `tests/ConfigLoader.Tests.ps1`
- Modify: `src/Modules/ConfigLoader.ps1`

- [ ] **Step 1: Add failing tests for `Select-ServerSyncPairs` and `Resolve-RetentionPolicy`**

Append to `tests/ConfigLoader.Tests.ps1`:

```powershell
    Context 'Select-ServerSyncPairs tag filtering' {
        BeforeAll {
            $script:TaggedPairs = @(
                [PSCustomObject]@{ name='A'; tags=@('default','daily') },
                [PSCustomObject]@{ name='B'; tags=@('weekly') },
                [PSCustomObject]@{ name='C'; tags=@() },
                [PSCustomObject]@{ name='D' }  # no tags field at all
            )
        }

        It 'includes only pairs with default tag when no -Tag given' {
            $selected = Select-ServerSyncPairs -Pairs $script:TaggedPairs
            $selected.Count | Should -Be 1
            $selected[0].name | Should -Be 'A'
        }

        It 'matches specific tag' {
            $selected = Select-ServerSyncPairs -Pairs $script:TaggedPairs -Tag 'weekly'
            $selected.Count | Should -Be 1
            $selected[0].name | Should -Be 'B'
        }

        It 'excludes pairs with empty or missing tags always' {
            $selectedD = Select-ServerSyncPairs -Pairs $script:TaggedPairs -Tag 'anything'
            $selectedD.name | Should -Not -Contain 'C'
            $selectedD.name | Should -Not -Contain 'D'
        }
    }

    Context 'Resolve-RetentionPolicy' {
        It 'uses pair retention when fully specified' {
            $defaults = [PSCustomObject]@{ default_mode='files'; default_extensions=@('.TIB'); default_count=3 }
            $pair = [PSCustomObject]@{ retention = [PSCustomObject]@{ mode='folders'; count=7 } }
            $r = Resolve-RetentionPolicy -Pair $pair -Defaults $defaults
            $r.Mode | Should -Be 'folders'
            $r.Count | Should -Be 7
        }

        It 'falls back to defaults when pair omits retention' {
            $defaults = [PSCustomObject]@{ default_mode='files'; default_extensions=@('.TIB'); default_count=3 }
            $pair = [PSCustomObject]@{ name='X' }
            $r = Resolve-RetentionPolicy -Pair $pair -Defaults $defaults
            $r.Mode | Should -Be 'files'
            $r.Extensions | Should -Be @('.TIB')
            $r.Count | Should -Be 3
        }

        It 'merges per-pair count with default extensions in files mode' {
            $defaults = [PSCustomObject]@{ default_mode='files'; default_extensions=@('.TIB'); default_count=3 }
            $pair = [PSCustomObject]@{ retention = [PSCustomObject]@{ count=10 } }
            $r = Resolve-RetentionPolicy -Pair $pair -Defaults $defaults
            $r.Mode | Should -Be 'files'
            $r.Count | Should -Be 10
            $r.Extensions | Should -Be @('.TIB')
        }
    }
```

- [ ] **Step 2: Run tests (should fail — functions not defined)**

Run: `pwsh -Command "Invoke-Pester -Path tests/ConfigLoader.Tests.ps1 -Output Detailed"`

Expected: 6 new FAIL.

- [ ] **Step 3: Implement in `src/Modules/ConfigLoader.ps1`**

Append:

```powershell
function Select-ServerSyncPairs {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [Object[]]$Pairs,

        [string]$Tag
    )

    $results = foreach ($pair in $Pairs) {
        $tags = @()
        if ($pair.PSObject.Properties.Name -contains 'tags' -and $null -ne $pair.tags) {
            $tags = @($pair.tags)
        }
        if ($tags.Count -eq 0) { continue }  # no tags means disabled

        if ($Tag) {
            if ($tags -contains $Tag) { $pair }
        }
        else {
            if ($tags -contains 'default') { $pair }
        }
    }
    # Ensure we always return an array, even for 0 or 1 matches
    return ,@($results)
}

function Resolve-RetentionPolicy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [Object]$Pair,

        [Parameter(Mandatory)]
        [Object]$Defaults
    )

    $pairRetention = $null
    if ($Pair.PSObject.Properties.Name -contains 'retention' -and $null -ne $Pair.retention) {
        $pairRetention = $Pair.retention
    }

    $mode = if ($pairRetention -and $pairRetention.mode) { $pairRetention.mode }
            else { $Defaults.default_mode }

    $count = if ($pairRetention -and $pairRetention.count) { $pairRetention.count }
             else { $Defaults.default_count }

    $extensions = @()
    if ($mode -eq 'files') {
        if ($pairRetention -and $pairRetention.extensions) {
            $extensions = @($pairRetention.extensions)
        }
        else {
            $extensions = @($Defaults.default_extensions)
        }
    }

    return [PSCustomObject]@{
        Mode       = $mode
        Count      = $count
        Extensions = $extensions
    }
}
```

- [ ] **Step 4: Run tests (should pass)**

Run: `pwsh -Command "Invoke-Pester -Path tests/ConfigLoader.Tests.ps1 -Output Detailed"`

Expected: 10 PASS, 0 FAIL.

- [ ] **Step 5: Commit**

```bash
git add tests/ConfigLoader.Tests.ps1 src/Modules/ConfigLoader.ps1
git commit -m "ConfigLoader: add tag filter and retention policy resolution"
```

---

## Phase 3: Retention Module (pure logic, cross-platform testable)

### Task 8: Retention — write failing test for files mode keeping newest N

**Files:**
- Create: `tests/Retention.Tests.ps1`

- [ ] **Step 1: Write test file**

```powershell
BeforeAll {
    $script:ModulePath = Join-Path $PSScriptRoot '..' 'src' 'Modules' 'Retention.ps1'
    . $script:ModulePath
}

Describe 'Retention - files mode' -Tag 'Unit' {
    BeforeEach {
        $script:TmpRoot = Join-Path ([IO.Path]::GetTempPath()) ("retention-test-" + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:TmpRoot | Out-Null
    }

    AfterEach {
        if (Test-Path $script:TmpRoot) {
            Remove-Item -Recurse -Force $script:TmpRoot
        }
    }

    It 'keeps the N newest matching files in each immediate subfolder' {
        $sub = Join-Path $script:TmpRoot 'MachineA'
        New-Item -ItemType Directory -Path $sub | Out-Null
        1..5 | ForEach-Object {
            $f = New-Item -ItemType File -Path (Join-Path $sub "backup-$_.TIB")
            $f.LastWriteTime = (Get-Date).AddDays(-$_)
        }

        $policy = [PSCustomObject]@{ Mode='files'; Count=2; Extensions=@('.TIB') }
        Invoke-Retention -DestinationRoot $script:TmpRoot -Policy $policy

        $remaining = Get-ChildItem $sub -Filter '*.TIB' | Sort-Object LastWriteTime -Descending
        $remaining.Count | Should -Be 2
        $remaining.Name | Should -Be @('backup-1.TIB','backup-2.TIB')
    }

    It 'never touches files whose extension is not in the list' {
        $sub = Join-Path $script:TmpRoot 'MachineA'
        New-Item -ItemType Directory -Path $sub | Out-Null
        foreach ($ext in '.TIB','.log','.txt') {
            1..3 | ForEach-Object {
                $f = New-Item -ItemType File -Path (Join-Path $sub "file-$_$ext")
                $f.LastWriteTime = (Get-Date).AddDays(-$_)
            }
        }

        $policy = [PSCustomObject]@{ Mode='files'; Count=1; Extensions=@('.TIB') }
        Invoke-Retention -DestinationRoot $script:TmpRoot -Policy $policy

        (Get-ChildItem $sub -Filter '*.TIB').Count | Should -Be 1
        (Get-ChildItem $sub -Filter '*.log').Count | Should -Be 3
        (Get-ChildItem $sub -Filter '*.txt').Count | Should -Be 3
    }

    It 'applies retention independently in each subfolder' {
        foreach ($machine in 'MachineA','MachineB') {
            $sub = Join-Path $script:TmpRoot $machine
            New-Item -ItemType Directory -Path $sub | Out-Null
            1..4 | ForEach-Object {
                $f = New-Item -ItemType File -Path (Join-Path $sub "b-$_.TIB")
                $f.LastWriteTime = (Get-Date).AddDays(-$_)
            }
        }

        $policy = [PSCustomObject]@{ Mode='files'; Count=2; Extensions=@('.TIB') }
        Invoke-Retention -DestinationRoot $script:TmpRoot -Policy $policy

        (Get-ChildItem (Join-Path $script:TmpRoot 'MachineA') -Filter '*.TIB').Count | Should -Be 2
        (Get-ChildItem (Join-Path $script:TmpRoot 'MachineB') -Filter '*.TIB').Count | Should -Be 2
    }

    It 'tracks multiple extensions independently' {
        $sub = Join-Path $script:TmpRoot 'MachineA'
        New-Item -ItemType Directory -Path $sub | Out-Null
        foreach ($ext in '.vbk','.vbm') {
            1..4 | ForEach-Object {
                $f = New-Item -ItemType File -Path (Join-Path $sub "file-$_$ext")
                $f.LastWriteTime = (Get-Date).AddDays(-$_)
            }
        }

        $policy = [PSCustomObject]@{ Mode='files'; Count=2; Extensions=@('.vbk','.vbm') }
        Invoke-Retention -DestinationRoot $script:TmpRoot -Policy $policy

        (Get-ChildItem $sub -Filter '*.vbk').Count | Should -Be 2
        (Get-ChildItem $sub -Filter '*.vbm').Count | Should -Be 2
    }

    It 'matches extensions case-insensitively' {
        $sub = Join-Path $script:TmpRoot 'MachineA'
        New-Item -ItemType Directory -Path $sub | Out-Null
        foreach ($name in 'a.TIB','b.tib','c.Tib','d.TIB','e.TIB') {
            $f = New-Item -ItemType File -Path (Join-Path $sub $name)
            Start-Sleep -Milliseconds 5  # ensure distinct LastWriteTime
        }

        $policy = [PSCustomObject]@{ Mode='files'; Count=3; Extensions=@('.TIB') }
        Invoke-Retention -DestinationRoot $script:TmpRoot -Policy $policy

        (Get-ChildItem $sub).Count | Should -Be 3
    }
}
```

- [ ] **Step 2: Run tests (should fail — module doesn't exist)**

Run: `pwsh -Command "Invoke-Pester -Path tests/Retention.Tests.ps1 -Output Detailed"`

Expected: 5 FAIL (file not found or function not defined).

- [ ] **Step 3: Commit failing tests**

```bash
git add tests/Retention.Tests.ps1
git commit -m "Add failing tests for Retention files mode"
```

---

### Task 9: Retention — implement files mode

**Files:**
- Create: `src/Modules/Retention.ps1`

- [ ] **Step 1: Write `src/Modules/Retention.ps1`**

```powershell
<#
.SYNOPSIS
    Apply per-pair retention to a destination tree. The only destructive
    module in ServerSync.
#>

function Invoke-Retention {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$DestinationRoot,

        [Parameter(Mandatory)]
        [Object]$Policy,

        [scriptblock]$LogCallback
    )

    if (-not (Test-Path -Path $DestinationRoot -PathType Container)) {
        return  # nothing to do
    }

    $subfolders = Get-ChildItem -Path $DestinationRoot -Directory -Force

    switch ($Policy.Mode) {
        'files'   { Invoke-RetentionFilesMode   -Subfolders $subfolders -Policy $Policy -LogCallback $LogCallback }
        'folders' { Invoke-RetentionFoldersMode -Subfolders $subfolders -Policy $Policy -LogCallback $LogCallback }
        default   { throw "Unknown retention mode: $($Policy.Mode)" }
    }
}

function Invoke-RetentionFilesMode {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Object[]]$Subfolders,
        [Object]$Policy,
        [scriptblock]$LogCallback
    )

    foreach ($sub in $Subfolders) {
        foreach ($ext in $Policy.Extensions) {
            $normalizedExt = $ext
            if (-not $normalizedExt.StartsWith('.')) { $normalizedExt = ".$normalizedExt" }

            $files = Get-ChildItem -Path $sub.FullName -File -Force |
                Where-Object { $_.Extension -ieq $normalizedExt } |
                Sort-Object LastWriteTime -Descending

            $toDelete = $files | Select-Object -Skip $Policy.Count
            foreach ($f in $toDelete) {
                if ($PSCmdlet.ShouldProcess($f.FullName, 'Delete (retention)')) {
                    Remove-Item -LiteralPath $f.FullName -Force
                    if ($LogCallback) {
                        & $LogCallback "retention: deleted $($f.FullName)"
                    }
                }
            }
        }
    }
}

function Invoke-RetentionFoldersMode {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Object[]]$Subfolders,
        [Object]$Policy,
        [scriptblock]$LogCallback
    )

    foreach ($sub in $Subfolders) {
        $childFolders = Get-ChildItem -Path $sub.FullName -Directory -Force |
            Sort-Object LastWriteTime -Descending

        $toDelete = $childFolders | Select-Object -Skip $Policy.Count
        foreach ($d in $toDelete) {
            if ($PSCmdlet.ShouldProcess($d.FullName, 'Delete folder recursively (retention)')) {
                Remove-Item -LiteralPath $d.FullName -Recurse -Force
                if ($LogCallback) {
                    & $LogCallback "retention: deleted folder $($d.FullName)"
                }
            }
        }
    }
}
```

- [ ] **Step 2: Run tests (should pass)**

Run: `pwsh -Command "Invoke-Pester -Path tests/Retention.Tests.ps1 -Output Detailed"`

Expected: 5 PASS.

- [ ] **Step 3: Commit**

```bash
git add src/Modules/Retention.ps1
git commit -m "Retention: implement files mode"
```

---

### Task 10: Retention — add folders mode tests and verify

**Files:**
- Modify: `tests/Retention.Tests.ps1`

- [ ] **Step 1: Append folders mode tests**

```powershell
Describe 'Retention - folders mode' -Tag 'Unit' {
    BeforeEach {
        $script:TmpRoot = Join-Path ([IO.Path]::GetTempPath()) ("retention-folders-" + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:TmpRoot | Out-Null
    }
    AfterEach {
        if (Test-Path $script:TmpRoot) { Remove-Item -Recurse -Force $script:TmpRoot }
    }

    It 'keeps the N newest subfolders in each immediate subfolder' {
        $sub = Join-Path $script:TmpRoot 'MachineA'
        New-Item -ItemType Directory -Path $sub | Out-Null
        1..5 | ForEach-Object {
            $d = New-Item -ItemType Directory -Path (Join-Path $sub "2026-04-$_")
            $d.LastWriteTime = (Get-Date).AddDays(-$_)
            # Add a dummy file inside so Remove-Item -Recurse is exercised
            New-Item -ItemType File -Path (Join-Path $d.FullName 'dummy.txt') | Out-Null
        }

        $policy = [PSCustomObject]@{ Mode='folders'; Count=2 }
        Invoke-Retention -DestinationRoot $script:TmpRoot -Policy $policy

        $remaining = Get-ChildItem $sub -Directory | Sort-Object LastWriteTime -Descending
        $remaining.Count | Should -Be 2
        $remaining.Name | Should -Be @('2026-04-1','2026-04-2')
    }

    It 'does not touch files at the evaluated level, only subfolders' {
        $sub = Join-Path $script:TmpRoot 'MachineA'
        New-Item -ItemType Directory -Path $sub | Out-Null
        1..3 | ForEach-Object {
            $d = New-Item -ItemType Directory -Path (Join-Path $sub "run-$_")
            $d.LastWriteTime = (Get-Date).AddDays(-$_)
        }
        New-Item -ItemType File -Path (Join-Path $sub 'marker.txt') | Out-Null

        $policy = [PSCustomObject]@{ Mode='folders'; Count=1 }
        Invoke-Retention -DestinationRoot $script:TmpRoot -Policy $policy

        (Get-ChildItem $sub -Directory).Count | Should -Be 1
        Test-Path (Join-Path $sub 'marker.txt') | Should -Be $true
    }
}

Describe 'Retention - WhatIf support' -Tag 'Unit' {
    BeforeEach {
        $script:TmpRoot = Join-Path ([IO.Path]::GetTempPath()) ("retention-whatif-" + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:TmpRoot | Out-Null
    }
    AfterEach {
        if (Test-Path $script:TmpRoot) { Remove-Item -Recurse -Force $script:TmpRoot }
    }

    It 'does not delete when -WhatIf is used' {
        $sub = Join-Path $script:TmpRoot 'MachineA'
        New-Item -ItemType Directory -Path $sub | Out-Null
        1..4 | ForEach-Object {
            $f = New-Item -ItemType File -Path (Join-Path $sub "b-$_.TIB")
            $f.LastWriteTime = (Get-Date).AddDays(-$_)
        }

        $policy = [PSCustomObject]@{ Mode='files'; Count=1; Extensions=@('.TIB') }
        Invoke-Retention -DestinationRoot $script:TmpRoot -Policy $policy -WhatIf

        (Get-ChildItem $sub -Filter '*.TIB').Count | Should -Be 4
    }
}
```

- [ ] **Step 2: Run all Retention tests (should all pass — folders mode already implemented)**

Run: `pwsh -Command "Invoke-Pester -Path tests/Retention.Tests.ps1 -Output Detailed"`

Expected: 8 PASS.

- [ ] **Step 3: Commit**

```bash
git add tests/Retention.Tests.ps1
git commit -m "Retention: add folders mode and -WhatIf tests"
```

---

## Phase 4: Logging Module

### Task 11: Logging — file logger tests and implementation

**Files:**
- Create: `tests/Logging.Tests.ps1`
- Create: `src/Modules/Logging.ps1`

- [ ] **Step 1: Write failing tests `tests/Logging.Tests.ps1`**

```powershell
BeforeAll {
    $script:ModulePath = Join-Path $PSScriptRoot '..' 'src' 'Modules' 'Logging.ps1'
    . $script:ModulePath
}

Describe 'Logging - file logger' -Tag 'Unit' {
    BeforeEach {
        $script:TmpDir = Join-Path ([IO.Path]::GetTempPath()) ("logging-test-" + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:TmpDir | Out-Null
    }
    AfterEach {
        if (Test-Path $script:TmpDir) { Remove-Item -Recurse -Force $script:TmpDir }
    }

    It 'New-ServerSyncLogger returns a logger object with path' {
        $logger = New-ServerSyncLogger -LogDirectory $script:TmpDir -Prefix 'sync'
        $logger.LogPath | Should -Not -BeNullOrEmpty
        $logger.LogPath | Should -Match 'sync-\d{4}-\d{2}-\d{2}'
    }

    It 'Write-ServerSyncLog appends a timestamped line' {
        $logger = New-ServerSyncLogger -LogDirectory $script:TmpDir -Prefix 'sync'
        Write-ServerSyncLog -Logger $logger -Level 'INFO' -Message 'hello'
        $content = Get-Content -Raw $logger.LogPath
        $content | Should -Match 'INFO'
        $content | Should -Match 'hello'
        $content | Should -Match '\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}'
    }

    It 'Write-ServerSyncLog supports multiple levels' {
        $logger = New-ServerSyncLogger -LogDirectory $script:TmpDir -Prefix 'sync'
        Write-ServerSyncLog -Logger $logger -Level 'ERROR' -Message 'bang'
        Write-ServerSyncLog -Logger $logger -Level 'WARN'  -Message 'hmm'
        $content = Get-Content -Raw $logger.LogPath
        $content | Should -Match 'ERROR.*bang'
        $content | Should -Match 'WARN.*hmm'
    }

    It 'Remove-OldLogFiles deletes files older than retention' {
        $old = New-Item -ItemType File -Path (Join-Path $script:TmpDir 'old.log')
        $old.LastWriteTime = (Get-Date).AddDays(-100)
        $new = New-Item -ItemType File -Path (Join-Path $script:TmpDir 'new.log')
        Remove-OldLogFiles -LogDirectory $script:TmpDir -RetentionDays 90
        Test-Path $old.FullName | Should -Be $false
        Test-Path $new.FullName | Should -Be $true
    }
}
```

- [ ] **Step 2: Run tests (should fail — module missing)**

Run: `pwsh -Command "Invoke-Pester -Path tests/Logging.Tests.ps1 -Output Detailed"`

Expected: 4 FAIL.

- [ ] **Step 3: Write `src/Modules/Logging.ps1`**

```powershell
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
```

- [ ] **Step 4: Run tests (should pass)**

Run: `pwsh -Command "Invoke-Pester -Path tests/Logging.Tests.ps1 -Output Detailed"`

Expected: 4 PASS.

- [ ] **Step 5: Commit**

```bash
git add tests/Logging.Tests.ps1 src/Modules/Logging.ps1
git commit -m "Logging: file logger, event log writer, retention cleanup"
```

---

### Task 12: Logging — email helper

**Files:**
- Modify: `tests/Logging.Tests.ps1`
- Modify: `src/Modules/Logging.ps1`

- [ ] **Step 1: Add failing tests for Send-ServerSyncEmail**

Append to `tests/Logging.Tests.ps1`:

```powershell
Describe 'Logging - email' -Tag 'Unit' {
    It 'Send-ServerSyncEmail returns early when email.enabled is false' {
        $emailConfig = [PSCustomObject]@{ enabled=$false }
        # Should not throw and should not call Send-MailMessage
        { Send-ServerSyncEmail -Config $emailConfig -Subject 'x' -Body 'y' -Credential $null } |
            Should -Not -Throw
    }

    It 'Send-ServerSyncEmail returns early when send_on is "failure" and no failures' {
        $emailConfig = [PSCustomObject]@{ enabled=$true; send_on='failure' }
        { Send-ServerSyncEmail -Config $emailConfig -Subject 'x' -Body 'y' -Credential $null -HasFailures $false } |
            Should -Not -Throw
    }

    It 'Test-ShouldSendEmail matches send_on logic' {
        (Test-ShouldSendEmail -SendOn 'always'  -HasFailures $true)  | Should -Be $true
        (Test-ShouldSendEmail -SendOn 'always'  -HasFailures $false) | Should -Be $true
        (Test-ShouldSendEmail -SendOn 'failure' -HasFailures $true)  | Should -Be $true
        (Test-ShouldSendEmail -SendOn 'failure' -HasFailures $false) | Should -Be $false
        (Test-ShouldSendEmail -SendOn 'never'   -HasFailures $true)  | Should -Be $false
    }
}
```

- [ ] **Step 2: Run tests (should fail)**

Run: `pwsh -Command "Invoke-Pester -Path tests/Logging.Tests.ps1 -Output Detailed"`

Expected: 3 new FAIL.

- [ ] **Step 3: Append to `src/Modules/Logging.ps1`**

```powershell
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
```

- [ ] **Step 4: Run tests (should pass)**

Run: `pwsh -Command "Invoke-Pester -Path tests/Logging.Tests.ps1 -Output Detailed"`

Expected: 7 PASS.

- [ ] **Step 5: Commit**

```bash
git add tests/Logging.Tests.ps1 src/Modules/Logging.ps1
git commit -m "Logging: add email helper with send_on gating"
```

---

## Phase 5: SyncOperations Module

### Task 13: SyncOperations — exit code interpretation

**Files:**
- Create: `tests/SyncOperations.Tests.ps1`
- Create: `src/Modules/SyncOperations.ps1`

- [ ] **Step 1: Write tests**

```powershell
BeforeAll {
    $script:ModulePath = Join-Path $PSScriptRoot '..' 'src' 'Modules' 'SyncOperations.ps1'
    . $script:ModulePath
}

Describe 'SyncOperations - robocopy exit code interpretation' -Tag 'Unit' {
    It 'treats 0-3 as success' {
        foreach ($code in 0..3) {
            $r = ConvertFrom-RobocopyExitCode -ExitCode $code
            $r.Success | Should -Be $true
            $r.HasWarnings | Should -Be $false
        }
    }

    It 'treats 4-7 as success with warnings' {
        foreach ($code in 4..7) {
            $r = ConvertFrom-RobocopyExitCode -ExitCode $code
            $r.Success | Should -Be $true
            $r.HasWarnings | Should -Be $true
        }
    }

    It 'treats 8-16 as failure' {
        foreach ($code in 8..16) {
            $r = ConvertFrom-RobocopyExitCode -ExitCode $code
            $r.Success | Should -Be $false
        }
    }

    It 'returns a human-readable description' {
        (ConvertFrom-RobocopyExitCode -ExitCode 0).Description | Should -Match 'no'
        (ConvertFrom-RobocopyExitCode -ExitCode 1).Description | Should -Match 'copied'
        (ConvertFrom-RobocopyExitCode -ExitCode 8).Description | Should -Match -Not 'success'
    }
}
```

- [ ] **Step 2: Run (should fail — module missing)**

Run: `pwsh -Command "Invoke-Pester -Path tests/SyncOperations.Tests.ps1 -Output Detailed"`

Expected: 4 FAIL.

- [ ] **Step 3: Write `src/Modules/SyncOperations.ps1`**

```powershell
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
```

- [ ] **Step 4: Run tests (should pass)**

Run: `pwsh -Command "Invoke-Pester -Path tests/SyncOperations.Tests.ps1 -Output Detailed"`

Expected: 4 PASS.

- [ ] **Step 5: Commit**

```bash
git add tests/SyncOperations.Tests.ps1 src/Modules/SyncOperations.ps1
git commit -m "SyncOperations: interpret robocopy exit codes"
```

---

### Task 14: SyncOperations — robocopy invocation wrapper

**Files:**
- Modify: `tests/SyncOperations.Tests.ps1`
- Modify: `src/Modules/SyncOperations.ps1`

- [ ] **Step 1: Append tests for argument building**

```powershell
Describe 'SyncOperations - argument building' -Tag 'Unit' {
    It 'Build-RobocopyArgs uses the spec flags' {
        $args = Build-RobocopyArgs -Source '\\src\s' -Destination 'D:\d' `
            -Threads 6 -Retries 3 -RetryWaitSeconds 10 -LogFile 'C:\l.log'
        $argString = $args -join ' '
        $argString | Should -Match '/E'
        $argString | Should -Match '/Z'
        $argString | Should -Match '/COPY:DAT'
        $argString | Should -Match '/XO'
        $argString | Should -Match '/R:3'
        $argString | Should -Match '/W:10'
        $argString | Should -Match '/MT:6'
        $argString | Should -Match '/NP'
        $argString | Should -Match '/LOG\+:C:\\l\.log'
    }

    It 'Build-RobocopyArgs includes extra_flags verbatim' {
        $args = Build-RobocopyArgs -Source '\\s\s' -Destination 'D:\d' `
            -Threads 4 -Retries 1 -RetryWaitSeconds 5 -LogFile 'C:\l.log' `
            -ExtraFlags @('/COMPRESS','/IPG:50')
        $argString = $args -join ' '
        $argString | Should -Match '/COMPRESS'
        $argString | Should -Match '/IPG:50'
    }

    It 'Build-RobocopyArgs puts source and destination first' {
        $args = Build-RobocopyArgs -Source '\\src\s' -Destination 'D:\d' `
            -Threads 6 -Retries 3 -RetryWaitSeconds 10 -LogFile 'C:\l.log'
        $args[0] | Should -Be '\\src\s'
        $args[1] | Should -Be 'D:\d'
    }
}
```

- [ ] **Step 2: Run (new tests should fail)**

Run: `pwsh -Command "Invoke-Pester -Path tests/SyncOperations.Tests.ps1 -Output Detailed"`

Expected: 3 new FAIL.

- [ ] **Step 3: Append to `src/Modules/SyncOperations.ps1`**

```powershell
function Build-RobocopyArgs {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][int]$Threads,
        [Parameter(Mandatory)][int]$Retries,
        [Parameter(Mandatory)][int]$RetryWaitSeconds,
        [Parameter(Mandatory)][string]$LogFile,
        [string[]]$ExtraFlags = @()
    )

    $args = @(
        $Source
        $Destination
        '/E'
        '/Z'
        '/COPY:DAT'
        '/XO'
        "/R:$Retries"
        "/W:$RetryWaitSeconds"
        "/MT:$Threads"
        '/NP'
        "/LOG+:$LogFile"
    )
    if ($ExtraFlags) { $args += $ExtraFlags }
    return ,$args
}

function Invoke-RobocopySync {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][int]$Threads,
        [Parameter(Mandatory)][int]$Retries,
        [Parameter(Mandatory)][int]$RetryWaitSeconds,
        [Parameter(Mandatory)][string]$LogFile,
        [string[]]$ExtraFlags = @()
    )

    if (-not (Test-Path -Path $Destination -PathType Container)) {
        if ($PSCmdlet.ShouldProcess($Destination, 'Create destination directory')) {
            New-Item -ItemType Directory -Path $Destination -Force | Out-Null
        }
    }

    $args = Build-RobocopyArgs -Source $Source -Destination $Destination `
        -Threads $Threads -Retries $Retries -RetryWaitSeconds $RetryWaitSeconds `
        -LogFile $LogFile -ExtraFlags $ExtraFlags

    if ($PSCmdlet.ShouldProcess("$Source -> $Destination", 'robocopy')) {
        $process = Start-Process -FilePath 'robocopy' -ArgumentList $args -Wait -PassThru -NoNewWindow
        return (ConvertFrom-RobocopyExitCode -ExitCode $process.ExitCode)
    }
    else {
        return [PSCustomObject]@{ ExitCode = 0; Success = $true; HasWarnings = $false; Description = '[WhatIf] skipped' }
    }
}
```

- [ ] **Step 4: Run tests (should pass)**

Run: `pwsh -Command "Invoke-Pester -Path tests/SyncOperations.Tests.ps1 -Output Detailed"`

Expected: 7 PASS.

- [ ] **Step 5: Commit**

```bash
git add tests/SyncOperations.Tests.ps1 src/Modules/SyncOperations.ps1
git commit -m "SyncOperations: add Build-RobocopyArgs and Invoke-RobocopySync"
```

---

## Phase 6: NetworkControl Module (Windows-only)

### Task 15: NetworkControl — enable/disable/verify with mocks

**Files:**
- Create: `tests/NetworkControl.Tests.ps1`
- Create: `src/Modules/NetworkControl.ps1`

- [ ] **Step 1: Write tests using Pester mocks**

```powershell
BeforeAll {
    $script:ModulePath = Join-Path $PSScriptRoot '..' 'src' 'Modules' 'NetworkControl.ps1'
    . $script:ModulePath
}

Describe 'NetworkControl - enable/disable' -Tag 'Unit' {
    It 'Enable-ServerSyncNics calls Enable-NetAdapter for each name' {
        Mock Enable-NetAdapter -ModuleName NetworkControl {}
        # Because we dot-source, the module-name approach does not apply.
        # Instead, mock in the caller scope:
        Mock Enable-NetAdapter { } -ParameterFilter { $Name }

        Enable-ServerSyncNics -Names @('Ethernet','Ethernet 2')

        Should -Invoke Enable-NetAdapter -Times 1 -ParameterFilter { $Name -eq 'Ethernet' }
        Should -Invoke Enable-NetAdapter -Times 1 -ParameterFilter { $Name -eq 'Ethernet 2' }
    }

    It 'Disable-ServerSyncNics calls Disable-NetAdapter for each name' {
        Mock Disable-NetAdapter { } -ParameterFilter { $Name }
        Disable-ServerSyncNics -Names @('Ethernet')
        Should -Invoke Disable-NetAdapter -Times 1
    }

    It 'Test-AllNicsDisabled returns $true when all report Status "Disabled"' {
        Mock Get-NetAdapter { [PSCustomObject]@{ Name=$Name; Status='Disabled' } } -ParameterFilter { $Name }
        (Test-AllNicsDisabled -Names @('Ethernet','Ethernet 2')) | Should -Be $true
    }

    It 'Test-AllNicsDisabled returns $false when one is still Up' {
        Mock Get-NetAdapter {
            if ($Name -eq 'Ethernet') { [PSCustomObject]@{ Name=$Name; Status='Disabled' } }
            else { [PSCustomObject]@{ Name=$Name; Status='Up' } }
        } -ParameterFilter { $Name }
        (Test-AllNicsDisabled -Names @('Ethernet','Ethernet 2')) | Should -Be $false
    }
}

Describe 'NetworkControl - readiness' -Tag 'Unit' {
    It 'Wait-NetworkReady returns $true when ping succeeds' {
        Mock Test-Connection { $true }
        (Wait-NetworkReady -TargetHost '192.168.1.1' -TimeoutSeconds 1) | Should -Be $true
    }

    It 'Wait-NetworkReady returns $false after timeout when ping never succeeds' {
        Mock Test-Connection { $false }
        (Wait-NetworkReady -TargetHost '192.168.1.1' -TimeoutSeconds 2) | Should -Be $false
    }
}
```

- [ ] **Step 2: Run (should fail — module missing)**

Run: `pwsh -Command "Invoke-Pester -Path tests/NetworkControl.Tests.ps1 -Output Detailed"`

Expected: all FAIL.

- [ ] **Step 3: Write `src/Modules/NetworkControl.ps1`**

```powershell
<#
.SYNOPSIS
    Enable, disable, and verify network adapters. Verify network readiness.
#>

function Enable-ServerSyncNics {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Names
    )
    foreach ($n in $Names) {
        Enable-NetAdapter -Name $n -Confirm:$false -ErrorAction Stop
    }
}

function Disable-ServerSyncNics {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Names
    )
    $failures = @()
    foreach ($n in $Names) {
        try {
            Disable-NetAdapter -Name $n -Confirm:$false -ErrorAction Stop
        }
        catch {
            $failures += "$n : $($_.Exception.Message)"
        }
    }
    if ($failures.Count -gt 0) {
        throw "Failed to disable NICs: $($failures -join '; ')"
    }
}

function Test-AllNicsDisabled {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Names
    )
    foreach ($n in $Names) {
        $adapter = Get-NetAdapter -Name $n -ErrorAction SilentlyContinue
        if (-not $adapter) { continue }  # missing adapter treated as disabled
        if ($adapter.Status -ne 'Disabled') { return $false }
    }
    return $true
}

function Wait-NetworkReady {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TargetHost,
        [Parameter(Mandatory)][int]$TimeoutSeconds
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            if (Test-Connection -TargetName $TargetHost -Count 1 -Quiet -ErrorAction Stop) {
                return $true
            }
        }
        catch {
            # Test-Connection older param name on Windows PowerShell 5.1
            try {
                if (Test-Connection -ComputerName $TargetHost -Count 1 -Quiet -ErrorAction Stop) {
                    return $true
                }
            } catch {}
        }
        Start-Sleep -Seconds 1
    }
    return $false
}
```

- [ ] **Step 4: Run tests**

Run: `pwsh -Command "Invoke-Pester -Path tests/NetworkControl.Tests.ps1 -Output Detailed"`

Expected: all PASS. (Pester mocks override the real cmdlets in the test scope — this works cross-platform because we're not actually calling the real commands.)

- [ ] **Step 5: Commit**

```bash
git add tests/NetworkControl.Tests.ps1 src/Modules/NetworkControl.ps1
git commit -m "NetworkControl: enable/disable/verify NICs and wait for readiness"
```

---

## Phase 7: Orchestrator

### Task 16: Orchestrator — skeleton with param block and module loading

**Files:**
- Create: `src/Start-ServerSync.ps1`
- Create: `config/config.sample.json`

- [ ] **Step 1: Create sample config**

Copy `tests/fixtures/config-valid-minimal.json` content into `config/config.sample.json` and expand it with realistic examples:

```json
{
  "network": {
    "nics": ["Ethernet"],
    "ready_timeout_seconds": 30,
    "ready_check_host": "192.168.10.1"
  },
  "robocopy": {
    "threads": 6,
    "retries": 3,
    "retry_wait_seconds": 10,
    "extra_flags": []
  },
  "retention": {
    "default_mode": "files",
    "default_extensions": [".TIB"],
    "default_count": 3
  },
  "logging": {
    "log_directory": "C:\\ProgramData\\ServerSync\\logs",
    "log_retention_days": 90,
    "event_log_source": "ServerSync"
  },
  "email": {
    "enabled": false,
    "smtp_server": "mail.internal.lan",
    "smtp_port": 25,
    "use_ssl": false,
    "credential_target": "ServerSync-SMTP",
    "from": "serversync@company.local",
    "to": ["sysadmin@company.local"],
    "send_on": "failure"
  },
  "folder_pairs": [
    {
      "name": "ExampleServerA",
      "source": "\\\\backup01.internal.lan\\Backups\\ServerA",
      "destination": "D:\\AirgappedBackups\\ServerA",
      "credential_target": "ServerSync-Backup01",
      "retention": { "mode": "files", "extensions": [".TIB"], "count": 5 },
      "tags": ["default", "daily"]
    }
  ]
}
```

- [ ] **Step 2: Write orchestrator skeleton `src/Start-ServerSync.ps1`**

```powershell
<#
.SYNOPSIS
    ServerSync orchestrator. Enables NICs, runs configured sync pairs, disables NICs.
.DESCRIPTION
    Intended for Task Scheduler. Accepts -Tag to filter pairs. Supports -WhatIf and
    -ValidateConfig.
.PARAMETER ConfigPath
    Path to config.json. Default: ..\config\config.json relative to this script.
.PARAMETER Tag
    Optional. When provided, only pairs tagged with this value run.
.PARAMETER ValidateConfig
    Load and validate the config, then exit. No sync performed.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ConfigPath,
    [string]$Tag,
    [switch]$ValidateConfig
)

$ErrorActionPreference = 'Stop'

# Resolve default config path
if (-not $ConfigPath) {
    $ConfigPath = Join-Path $PSScriptRoot '..' 'config' 'config.json'
}

# Load modules (dot-source)
$modulesDir = Join-Path $PSScriptRoot 'Modules'
. (Join-Path $modulesDir 'ConfigLoader.ps1')
. (Join-Path $modulesDir 'Logging.ps1')
. (Join-Path $modulesDir 'NetworkControl.ps1')
. (Join-Path $modulesDir 'SyncOperations.ps1')
. (Join-Path $modulesDir 'Retention.ps1')

# Load & validate config
$config = Read-ServerSyncConfig -Path $ConfigPath
$validation = Test-ServerSyncConfig -Config $config
if (-not $validation.Valid) {
    Write-Error "Config invalid:`n$($validation.Errors -join "`n")"
    exit 2
}

if ($ValidateConfig) {
    Write-Host "Config OK: $ConfigPath"
    exit 0
}

# Placeholder: orchestration flow added in next task
Write-Host "Config loaded. Matched pairs: (not yet filtered)"
exit 0
```

- [ ] **Step 3: Validate the skeleton works**

From the repo root:

```bash
cp config/config.sample.json config/config.json
pwsh -File src/Start-ServerSync.ps1 -ValidateConfig
```

Expected: `Config OK: <path>` and exit 0.

Remove the local copy after testing:

```bash
rm config/config.json
```

- [ ] **Step 4: Commit**

```bash
git add src/Start-ServerSync.ps1 config/config.sample.json
git commit -m "Orchestrator: skeleton with config validation and module loading"
```

---

### Task 17: Orchestrator — full sync flow with try/finally NIC safety

**Files:**
- Modify: `src/Start-ServerSync.ps1`

- [ ] **Step 1: Add credential retrieval helper to ConfigLoader**

Append to `src/Modules/ConfigLoader.ps1`:

```powershell
function Get-ServerSyncCredential {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TargetName
    )

    # On Windows, use the CredentialManager module (install: Install-Module CredentialManager -Scope AllUsers)
    # Offline install: extract the module to $env:PSModulePath on the air-gapped server.
    if (-not (Get-Command Get-StoredCredential -ErrorAction SilentlyContinue)) {
        throw "CredentialManager module not available. Install it (Install-Module CredentialManager) or copy it to PSModulePath."
    }

    $cred = Get-StoredCredential -Target $TargetName
    if (-not $cred) {
        throw "Credential not found in Credential Manager: $TargetName"
    }
    return $cred
}
```

Commit now:

```bash
git add src/Modules/ConfigLoader.ps1
git commit -m "ConfigLoader: add Get-ServerSyncCredential helper"
```

- [ ] **Step 2: Replace placeholder section in `src/Start-ServerSync.ps1`**

Replace everything AFTER the `ValidateConfig` block (from the line `# Placeholder: orchestration flow added in next task` onwards) with:

```powershell
# Initialize logging
$logger = New-ServerSyncLogger -LogDirectory $config.logging.log_directory `
                                -Prefix 'sync' `
                                -EventLogSource $config.logging.event_log_source

Write-ServerSyncLog -Logger $logger -Level 'INFO' -Message "ServerSync starting. Tag='$Tag'"

$selectedPairs = Select-ServerSyncPairs -Pairs $config.folder_pairs -Tag $Tag
Write-ServerSyncLog -Logger $logger -Level 'INFO' -Message "Matched $($selectedPairs.Count) pair(s)"

if ($selectedPairs.Count -eq 0) {
    Write-ServerSyncLog -Logger $logger -Level 'WARN' -Message 'No pairs matched, exiting'
    exit 0
}

$hasFailures = $false
$nicsEnabled = $false

try {
    if ($PSCmdlet.ShouldProcess('NICs', "Enable $($config.network.nics -join ', ')")) {
        Enable-ServerSyncNics -Names $config.network.nics
        $nicsEnabled = $true
        Write-ServerSyncLog -Logger $logger -Level 'INFO' -Message "NICs enabled"

        if (-not (Wait-NetworkReady -TargetHost $config.network.ready_check_host -TimeoutSeconds $config.network.ready_timeout_seconds)) {
            throw "Network not ready after $($config.network.ready_timeout_seconds)s (host: $($config.network.ready_check_host))"
        }
        Write-ServerSyncLog -Logger $logger -Level 'INFO' -Message "Network ready"
    }

    foreach ($pair in $selectedPairs) {
        Write-ServerSyncLog -Logger $logger -Level 'INFO' -Message "=== Pair: $($pair.name) ==="
        try {
            $cred = Get-ServerSyncCredential -TargetName $pair.credential_target

            # Map SMB drive temporarily for this pair
            $useDrive = $false
            try {
                if ($PSCmdlet.ShouldProcess($pair.source, 'New-SmbMapping')) {
                    New-SmbMapping -RemotePath $pair.source `
                        -UserName $cred.UserName `
                        -Password $cred.GetNetworkCredential().Password `
                        -Persistent $false -ErrorAction Stop | Out-Null
                    $useDrive = $true
                }

                $result = Invoke-RobocopySync -Source $pair.source `
                    -Destination $pair.destination `
                    -Threads $config.robocopy.threads `
                    -Retries $config.robocopy.retries `
                    -RetryWaitSeconds $config.robocopy.retry_wait_seconds `
                    -LogFile $logger.LogPath `
                    -ExtraFlags $config.robocopy.extra_flags `
                    -WhatIf:$WhatIfPreference

                Write-ServerSyncLog -Logger $logger -Level 'INFO' -Message "  robocopy exit $($result.ExitCode): $($result.Description)"

                if (-not $result.Success) {
                    $hasFailures = $true
                    Write-ServerSyncLog -Logger $logger -Level 'ERROR' -Message "  SYNC FAILED for '$($pair.name)'" -AlsoEventLog
                    continue
                }

                # Retention
                $policy = Resolve-RetentionPolicy -Pair $pair -Defaults $config.retention
                Write-ServerSyncLog -Logger $logger -Level 'INFO' -Message "  retention: mode=$($policy.Mode) count=$($policy.Count)"
                $cb = { param($msg) Write-ServerSyncLog -Logger $logger -Level 'INFO' -Message "  $msg" }
                Invoke-Retention -DestinationRoot $pair.destination -Policy $policy `
                    -LogCallback $cb -WhatIf:$WhatIfPreference
            }
            finally {
                if ($useDrive -and (Get-SmbMapping -RemotePath $pair.source -ErrorAction SilentlyContinue)) {
                    Remove-SmbMapping -RemotePath $pair.source -Force -ErrorAction SilentlyContinue
                }
            }
        }
        catch {
            $hasFailures = $true
            Write-ServerSyncLog -Logger $logger -Level 'ERROR' -Message "  PAIR ERROR '$($pair.name)': $($_.Exception.Message)" -AlsoEventLog
            # continue to next pair
        }
    }
}
catch {
    Write-ServerSyncLog -Logger $logger -Level 'ERROR' -Message "FATAL: $($_.Exception.Message)" -AlsoEventLog
    $hasFailures = $true
}
finally {
    if ($nicsEnabled) {
        try {
            if ($PSCmdlet.ShouldProcess('NICs', "Disable $($config.network.nics -join ', ')")) {
                Disable-ServerSyncNics -Names $config.network.nics
            }
        }
        catch {
            Write-ServerSyncLog -Logger $logger -Level 'ERROR' -Message "Failed to disable NICs: $($_.Exception.Message)" -AlsoEventLog
        }

        # Verify
        $allDown = $true
        if (-not $WhatIfPreference) {
            $allDown = Test-AllNicsDisabled -Names $config.network.nics
        }
        if (-not $allDown) {
            Write-ServerSyncLog -Logger $logger -Level 'ERROR' -Message 'CRITICAL: NIC disable could not be verified' -AlsoEventLog
            # Urgent email
            try {
                $smtpCred = $null
                if ($config.email.enabled -and $config.email.credential_target) {
                    $smtpCred = Get-ServerSyncCredential -TargetName $config.email.credential_target
                }
                Send-ServerSyncEmail -Config $config.email `
                    -Subject '[URGENT] ServerSync: NIC DISABLE VERIFICATION FAILED' `
                    -Body "Host: $env:COMPUTERNAME`nNICs may still be active. Investigate immediately." `
                    -Credential $smtpCred -HasFailures $true
            } catch {}
            exit 3
        }
        Write-ServerSyncLog -Logger $logger -Level 'INFO' -Message 'NICs verified disabled'
    }

    Remove-OldLogFiles -LogDirectory $config.logging.log_directory -RetentionDays $config.logging.log_retention_days
}

# Summary email
try {
    if ($config.email.enabled) {
        $smtpCred = $null
        if ($config.email.credential_target) {
            $smtpCred = Get-ServerSyncCredential -TargetName $config.email.credential_target
        }
        $status = if ($hasFailures) { 'FAILURES' } else { 'OK' }
        Send-ServerSyncEmail -Config $config.email `
            -Subject "[ServerSync] $status on $env:COMPUTERNAME" `
            -Body (Get-Content -Raw $logger.LogPath) `
            -Credential $smtpCred -HasFailures $hasFailures
    }
} catch {
    Write-ServerSyncLog -Logger $logger -Level 'WARN' -Message "Email send failed: $($_.Exception.Message)"
}

if ($hasFailures) { exit 1 } else { exit 0 }
```

- [ ] **Step 3: Sanity-check script parses**

```bash
pwsh -NoProfile -Command ". ./src/Start-ServerSync.ps1 -ValidateConfig -ConfigPath tests/fixtures/config-valid-minimal.json"
```

Expected: `Config OK: ...` and exit 0. The sample config doesn't exist on disk in your working directory — passing the fixture path exercises the whole load+validate path.

- [ ] **Step 4: Commit**

```bash
git add src/Start-ServerSync.ps1
git commit -m "Orchestrator: full sync flow with try/finally NIC safety"
```

---

## Phase 8: Setup & Install Scripts

### Task 18: Setup-Credentials — CLI credential setup

**Files:**
- Create: `src/Setup-Credentials.ps1`

- [ ] **Step 1: Write the script**

```powershell
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
```

- [ ] **Step 2: Commit**

```bash
git add src/Setup-Credentials.ps1
git commit -m "Setup-Credentials: CLI helper for Credential Manager"
```

---

### Task 19: Install-ServerSync — directory setup, ACLs, Event Log source, Task Scheduler folder

**Files:**
- Create: `src/Install-ServerSync.ps1`

- [ ] **Step 1: Write installer**

```powershell
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
```

- [ ] **Step 2: Commit**

```bash
git add src/Install-ServerSync.ps1
git commit -m "Install-ServerSync: setup data dirs, ACLs, Event Log, Task Scheduler folder"
```

---

## Phase 9: GUI (ServerSync-Manager.ps1)

### Task 20: GUI — main form with tab control scaffolding and self-elevation

**Files:**
- Create: `src/ServerSync-Manager.ps1`

- [ ] **Step 1: Write scaffold**

```powershell
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
```

- [ ] **Step 2: Smoke test (manual, Windows only)**

Document that this should be run on Windows:

```
powershell -File src\ServerSync-Manager.ps1
```

Expected: a window opens with four tabs, each showing placeholder text.

- [ ] **Step 3: Commit**

```bash
git add src/ServerSync-Manager.ps1
git commit -m "GUI: WinForms scaffold with four tabs and self-elevation"
```

---

### Task 21: GUI — Config Editor tab

**Files:**
- Modify: `src/ServerSync-Manager.ps1`

- [ ] **Step 1: Replace the `$tabConfig` placeholder with a working editor**

Find the block:

```powershell
foreach ($tab in @($tabConfig,$tabLogs,$tabCreds,$tabSched)) {
```

Remove `$tabConfig` from that loop (leave the other three for now). Before the `[void]$form.ShowDialog()` line, insert:

```powershell
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
```

- [ ] **Step 2: Commit**

```bash
git add src/ServerSync-Manager.ps1
git commit -m "GUI: Config Editor tab with add/edit/delete/reload/save"
```

---

### Task 22: GUI — Log Viewer tab

**Files:**
- Modify: `src/ServerSync-Manager.ps1`

- [ ] **Step 1: Remove `$tabLogs` from the placeholder loop and append this section before `[void]$form.ShowDialog()`**

```powershell
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
```

- [ ] **Step 2: Commit**

```bash
git add src/ServerSync-Manager.ps1
git commit -m "GUI: Log Viewer tab with filter and failures-only"
```

---

### Task 23: GUI — Credentials tab

**Files:**
- Modify: `src/ServerSync-Manager.ps1`

- [ ] **Step 1: Remove `$tabCreds` from the placeholder loop. Append before `[void]$form.ShowDialog()`**

```powershell
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
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "Set credential: $Target"
    $dlg.Size = New-Object System.Drawing.Size(400, 180)
    $dlg.StartPosition = 'CenterParent'

    $lblU = New-Object System.Windows.Forms.Label -Property @{ Text='UserName:'; Location='10,20'; Size='80,20' }
    $tbU = New-Object System.Windows.Forms.TextBox -Property @{ Location='100,20'; Size='270,20' }
    $lblP = New-Object System.Windows.Forms.Label -Property @{ Text='Password:'; Location='10,50'; Size='80,20' }
    $tbP = New-Object System.Windows.Forms.TextBox -Property @{ Location='100,50'; Size='270,20'; UseSystemPasswordChar=$true }
    $ok = New-Object System.Windows.Forms.Button -Property @{ Text='OK'; DialogResult='OK'; Location='200,90' }
    $cancel = New-Object System.Windows.Forms.Button -Property @{ Text='Cancel'; DialogResult='Cancel'; Location='290,90' }
    $dlg.AcceptButton = $ok; $dlg.CancelButton = $cancel
    $dlg.Controls.AddRange(@($lblU,$tbU,$lblP,$tbP,$ok,$cancel))
    if ($dlg.ShowDialog() -ne 'OK') { return }

    $secure = ConvertTo-SecureString -String $tbP.Text -AsPlainText -Force
    try {
        if (Get-StoredCredential -Target $Target -ErrorAction SilentlyContinue) {
            Remove-StoredCredential -Target $Target
        }
        New-StoredCredential -Target $Target -UserName $tbU.Text -SecurePassword $secure `
            -Persist LocalMachine -Type Generic | Out-Null
        Refresh-Credentials
    }
    catch {
        [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message,'Error',0,16)
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
```

- [ ] **Step 2: Commit**

```bash
git add src/ServerSync-Manager.ps1
git commit -m "GUI: Credentials tab using CredentialManager module"
```

---

### Task 24: GUI — Schedule tab

**Files:**
- Modify: `src/ServerSync-Manager.ps1`

- [ ] **Step 1: Remove `$tabSched` from the placeholder loop. Append before `[void]$form.ShowDialog()`**

```powershell
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

    if (-not $tbName.Text) { return }

    $hh,$mm = $tbTime.Text -split ':'
    $at = (Get-Date).Date.AddHours([int]$hh).AddMinutes([int]$mm)

    $trigger = switch ($cbType.SelectedItem) {
        'Daily'  { New-ScheduledTaskTrigger -Daily -At $at }
        'Weekly' { New-ScheduledTaskTrigger -Weekly -DaysOfWeek $cbDow.SelectedItem -At $at }
        'Once'   { New-ScheduledTaskTrigger -Once -At $at }
    }

    $scriptPath = Join-Path $PSScriptRoot 'Start-ServerSync.ps1'
    $args = "-NoProfile -File `"$scriptPath`""
    if ($cbTag.SelectedItem -and $cbTag.SelectedItem -ne '(no filter — default run)') {
        $args += " -Tag $($cbTag.SelectedItem)"
    }

    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $args
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

    $principalParams = @{ UserId = $tbUser.Text; LogonType = 'Password'; RunLevel = 'Highest' }

    try {
        Register-ScheduledTask -TaskName $tbName.Text -TaskPath $script:TaskFolder `
            -Action $action -Trigger $trigger -Settings $settings `
            -User $tbUser.Text -RunLevel Highest -Force | Out-Null
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
```

- [ ] **Step 2: Commit**

```bash
git add src/ServerSync-Manager.ps1
git commit -m "GUI: Schedule tab with ScheduledTasks module"
```

---

## Phase 10: Final integration

### Task 25: Smoke-test config with all fixtures

**Files:** (no changes — just running things)

- [ ] **Step 1: Run all tests**

```bash
pwsh -Command "Invoke-Pester -Path tests -Output Detailed"
```

Expected: all unit tests pass on Linux/pwsh.

- [ ] **Step 2: Smoke test config validation with the sample**

```bash
cp config/config.sample.json /tmp/sstest.json
pwsh -File src/Start-ServerSync.ps1 -ValidateConfig -ConfigPath /tmp/sstest.json
rm /tmp/sstest.json
```

Expected: "Config OK".

- [ ] **Step 3: Smoke test `-Tag` filter with a WhatIf dry-run**

For this to work without real NICs or Windows, modify the test invocation to skip real Windows cmdlets by using the fixture that has a simple pair and running with `-WhatIf`:

```bash
cp tests/fixtures/config-valid-minimal.json /tmp/sstest.json
pwsh -Command "
    `$ErrorActionPreference='Continue'
    try { pwsh -File src/Start-ServerSync.ps1 -ConfigPath /tmp/sstest.json -WhatIf } catch { Write-Host `"Expected: will fail on Windows-specific cmdlets on non-Windows`" }
"
rm /tmp/sstest.json
```

Expected on Linux: the script loads, validates config, gets past tag filtering, and fails at `Enable-NetAdapter` (cmdlet not available). This confirms the earlier pipeline works. Full `-WhatIf` on a real Windows machine is the ultimate test.

- [ ] **Step 4: Document this in README under a "Development" section**

Append to `README.md`:

```markdown

## Development

Unit tests run anywhere PowerShell + Pester are available:

    pwsh -Command "Invoke-Pester -Path tests -Output Detailed"

Tests tagged `Windows` require a Windows host:

    pwsh -Command "Invoke-Pester -Path tests -Tag Windows -Output Detailed"

End-to-end validation (NICs, SMB, Credential Manager, robocopy) must be done on
a Windows Server test VM that mirrors production.
```

- [ ] **Step 5: Commit**

```bash
git add README.md
git commit -m "Add development notes for running tests"
```

---

### Task 26: Final housekeeping — verify plan coverage against spec

**Files:** (no changes)

- [ ] **Step 1: Run the full test suite one more time**

```bash
pwsh -Command "Invoke-Pester -Path tests -Output Detailed"
```

Expected: all unit tests pass, test counts match what each task added.

- [ ] **Step 2: Verify project inventory**

```bash
ls -R src tests config docs
```

Expected presence:
- `src/Start-ServerSync.ps1`
- `src/ServerSync-Manager.ps1`
- `src/Setup-Credentials.ps1`
- `src/Install-ServerSync.ps1`
- `src/Modules/ConfigLoader.ps1`
- `src/Modules/Logging.ps1`
- `src/Modules/NetworkControl.ps1`
- `src/Modules/SyncOperations.ps1`
- `src/Modules/Retention.ps1`
- `tests/*.Tests.ps1` (5 files)
- `tests/fixtures/*.json` (3 files)
- `config/config.sample.json`
- `docs/superpowers/specs/2026-04-22-serversync-design.md`
- `docs/superpowers/plans/2026-04-22-serversync-implementation.md`

- [ ] **Step 3: Review the spec for anything uncovered**

Read `docs/superpowers/specs/2026-04-22-serversync-design.md` and check each requirement has at least one task. Known items for post-implementation (operational, not code-level — out of scope for this plan):

- Code signing cert deployment (manual operational step — spec notes this is required for `ExecutionPolicy = AllSigned`)
- Production Task Scheduler task creation (done via GUI Schedule tab after install)
- Production ACL tightening verification (done via `Install-ServerSync.ps1 -ServiceAccount ...`)
- CredentialManager module offline install (documented in `Get-ServerSyncCredential` error message)

- [ ] **Step 4: No commit needed (verification only). Announce completion.**

---

## Summary

26 tasks, organized into 10 phases. Implementation proceeds bottom-up: pure-logic modules first (ConfigLoader, Retention, exit codes) for fast cross-platform TDD, then Windows-specific modules (NetworkControl), then the orchestrator that composes everything, then setup/install scripts, then the GUI. Tests and implementation are committed together in tight TDD cycles.

Each module has Pester tests; the most destructive piece (Retention) has the most thorough coverage including WhatIf verification. Windows-specific behaviors (NIC state, robocopy, Credential Manager, WinForms) are mockable where possible and manually smoke-tested where not.
