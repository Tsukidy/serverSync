# ServerSync Design

**Date:** 2026-04-22
**Status:** Approved design, ready for implementation planning

## Purpose

Automate secure, one-way pulls of Acronis `.TIB` backup files from multiple Windows Server backup sources onto an air-gapped Windows Server. The script must:

1. Enable networking on the air-gapped server
2. Pull files from each configured folder pair (source → destination)
3. Always disable networking when finished, even on failure
4. Apply per-folder-pair retention (keep N newest `.TIB` files per subdirectory)
5. Provide a GUI for configuration, log viewing, credential management, and scheduling

The air-gapped server pulls only — nothing is pushed back.

## Environment

- **Air-gapped server:** Windows Server, 6 cores / 6 threads, no hyperthreading
- **Backup sources:** Windows Server(s), accessed over SMB
- **Network posture:** All NICs disabled by default. Enabled only during sync windows.
- **Trigger:** Task Scheduler primarily; also runnable manually

## Architecture

### Components

| Script | Purpose |
|--------|---------|
| `Start-ServerSync.ps1` | Orchestrator — runs from Task Scheduler or manually |
| `ServerSync-Manager.ps1` | GUI admin tool (WinForms) — config editor, log viewer, credential manager, scheduler |
| `Setup-Credentials.ps1` | CLI credential setup (alternative to GUI tab) |
| `Modules\NetworkControl.ps1` | Enable/disable NICs, verify network readiness |
| `Modules\SyncOperations.ps1` | Invoke robocopy, parse exit codes |
| `Modules\Retention.ps1` | Per-subdirectory `.TIB` retention cleanup |
| `Modules\Logging.ps1` | File log + Windows Event Log + SMTP email |
| `Modules\ConfigLoader.ps1` | Load and validate `config.json` |

### Design principles

- **GUI is read/write for config and credentials; read-only for logs; it does NOT trigger syncs or toggle NICs.** Security-sensitive operations stay in the signed orchestrator.
- **Retention is the only destructive operation.** Sync phase uses additive-copy only (`/XO`, no `/MIR`), so source retention policies never delete files from the air-gapped server.
- **NICs are always disabled in a `finally` block** and verified disabled after. If verification fails, the script exits with code 3 and sends an urgent email.
- **Credentials are referenced by name**, never stored in config or scripts. Storage is Windows Credential Manager only.

## Data Flow

```
[Task Scheduler task: "Daily Sync"]
    │
    ▼
[Start-ServerSync.ps1 -Tag daily]
    │
    ├─ Load & validate config.json
    ├─ Initialize logging (file + Event Log)
    ├─ Filter folder pairs by -Tag (no tag → only pairs with "default" tag)
    │
    ├─ TRY
    │   ├─ Enable NICs listed in config
    │   ├─ Wait for network ready (ping configured host, up to timeout)
    │   │
    │   ├─ For each matched folder pair:
    │   │   ├─ TRY
    │   │   │   ├─ Retrieve credentials from Credential Manager
    │   │   │   ├─ New-SmbMapping to source UNC
    │   │   │   ├─ robocopy [source] [dest] /E /Z /COPY:DAT /XO /R:3 /W:10 /MT:<N> /LOG+:<file> /NP
    │   │   │   ├─ Parse robocopy exit code
    │   │   │   ├─ Remove-SmbMapping
    │   │   │   └─ If success: retention cleanup on destination
    │   │   │       └─ For each subdirectory: keep N newest .TIB files, delete rest
    │   │   └─ CATCH
    │   │       └─ Log failure, mark pair failed, continue to next
    │   │
    │   └─ Summarize: X successful, Y failed
    │
    ├─ CATCH (fatal errors)
    │   └─ Log fatal error
    │
    ├─ FINALLY (always runs)
    │   ├─ Disable all NICs listed in config
    │   ├─ Verify disabled
    │   └─ If verification fails → Event Log + urgent email
    │
    ├─ If any failures → send summary email
    └─ Exit with appropriate code
```

## Configuration Schema (`config.json`)

```json
{
  "network": {
    "nics": ["Ethernet", "Ethernet 2"],
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
    "file_extension": ".TIB",
    "default_count": 3
  },
  "logging": {
    "log_directory": "C:\\ProgramData\\ServerSync\\logs",
    "log_retention_days": 90,
    "event_log_source": "ServerSync"
  },
  "email": {
    "enabled": true,
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
      "name": "FileServer01",
      "source": "\\\\backup01.internal.lan\\Backups\\FileServer01",
      "destination": "D:\\AirgappedBackups\\FileServer01",
      "credential_target": "ServerSync-Backup01",
      "retention_count": 5,
      "tags": ["default", "daily", "critical"]
    },
    {
      "name": "VM Backups",
      "source": "\\\\backup02.internal.lan\\VMBackups",
      "destination": "D:\\AirgappedBackups\\VMs",
      "credential_target": "ServerSync-Backup02",
      "retention_count": 7,
      "tags": ["weekly"]
    }
  ]
}
```

### Field notes

- `network.ready_check_host` — host pinged after NIC enable to confirm network is usable before syncs start.
- `robocopy.extra_flags` — escape hatch for adding flags without editing code (e.g. `/COMPRESS`).
- `retention.default_count` — applies when a pair omits `retention_count`. Default: 3.
- `retention.file_extension` — extension matched during cleanup (case-insensitive). Default: `.TIB`.
- `email.send_on` — `"failure"` (recommended), `"always"`, or `"never"`.
- `email.credential_target` — SMTP auth credentials from Credential Manager; never in config.
- `folder_pairs[].credential_target` — per-pair, so different source servers can use different credentials.
- `folder_pairs[].retention_count` — optional, falls back to `retention.default_count`.
- `folder_pairs[].tags` — see tag semantics below.

### Tag semantics

- **No tags at all** (empty array `[]` OR field missing entirely) → pair is ignored. Acts as a soft disable for maintenance.
- **Has tags** → pair runs when `-Tag <name>` matches one of its tags, or on a no-filter run if `"default"` is among its tags.
- **GUI behavior** — new pairs are created with `["default"]`. User removes `"default"` to exclude from no-filter runs while keeping the pair available for scoped runs.
- **Robocopy warnings** (exit codes 4-7) count as success — retention runs on these pairs. Only exit 8+ is treated as failure.

Examples:
- `["default", "daily"]` — runs on full run AND on `-Tag daily`
- `["weekly"]` — runs ONLY on `-Tag weekly`
- `[]` — never runs

## Robocopy Flags

`/E /Z /COPY:DAT /XO /R:3 /W:10 /MT:<N> /LOG+:<file> /NP`

| Flag | Purpose |
|------|---------|
| `/E` | Copy subdirectories including empty ones — preserves full directory structure |
| `/Z` | Restartable mode — resilient to network interruptions |
| `/COPY:DAT` | Copy Data, Attributes, Timestamps (no ACLs — destination ACLs set locally) |
| `/XO` | Skip older — never overwrite newer destination files with older source files |
| `/R:3 /W:10` | Retry 3 times, 10-second wait between retries |
| `/MT:<N>` | Multithreaded copy, N from config (default 6, matching core count) |
| `/LOG+:<file>` | Append to log file |
| `/NP` | No per-file progress output — keeps log readable |

**Not used:** `/MIR` (would delete destination files that aren't in source — breaks independent retention). `/PURGE` (same reason).

## Exit Codes

Orchestrator (`Start-ServerSync.ps1`):

| Code | Meaning |
|------|---------|
| 0 | All matched pairs succeeded, NICs verified disabled |
| 1 | Partial failure (one or more pairs failed), NICs disabled OK |
| 2 | Fatal error before sync loop (config invalid, NIC enable failed, etc.) |
| 3 | **Security failure**: NICs could not be verified disabled. Triggers urgent email. |

Robocopy exit codes (per-pair, logged with decoded meaning):

| Range | Treatment |
|-------|-----------|
| 0-3 | Success |
| 4-7 | Success with warnings (logged, not a failure) |
| 8+ | Failure |

## GUI (`ServerSync-Manager.ps1`)

Built with Windows Forms (`System.Windows.Forms`). Built into .NET Framework; no external dependencies.

### Tab 1: Config Editor

- Load `config.json`, display folder pairs in a grid
- Add / Edit / Delete folder pair
- Edit global settings (NICs, robocopy threads, logging, email)
- Validate on save
- Atomic write: write to temp file, rename over `config.json`
- New folder pairs get `["default"]` tag automatically

### Tab 2: Log Viewer

- List of log files (newest first)
- Click to view contents
- Filter box (plain text filter) + "Failures only" checkbox
- Refresh button for tailing the currently-running sync

### Tab 3: Credentials

- Lists credential targets referenced in `config.json`
- Indicates present vs missing in Credential Manager
- Add / Update credential (masked password input)
- Delete credential
- Never displays passwords, only target names

### Tab 4: Schedule

- Lists Task Scheduler entries under dedicated `\ServerSync\` folder (isolated from other system tasks)
- Columns: task name, trigger, tag filter, last run, last result, next run
- Buttons: Add, Edit, Delete, Run Now, Enable/Disable
- Add/Edit sub-dialog: task name, schedule type (Daily/Weekly/Monthly/Once), time, day-of-week/month, tag filter (dropdown populated from defined tags + "(no filter — default run)"), service account
- Uses built-in `ScheduledTasks` PowerShell module
- GUI self-elevates on startup (Task Scheduler modifications require admin)

## Security Model

| Concern | Mitigation |
|---------|------------|
| Credentials in scripts/config | Windows Credential Manager only, referenced by target name |
| NICs left on after crash | Outer `try/finally` + post-disable verification + exit code 3 alert |
| Unauthorized script modification | Scripts signed with code signing cert; `ExecutionPolicy = AllSigned` |
| Config tampering | `config.json` ACLed to service account + Administrators only |
| Log tampering | Log directory ACLed to service account + Administrators only |
| SMB credential leak | Credentials retrieved per-pair, SMB mappings disconnected after each |
| GUI credential exposure | Masked password input; never displayed back |
| Privilege creep | Dedicated service account with only required share/NTFS rights |
| Task Scheduler abuse | GUI modifies tasks only in dedicated `\ServerSync\` folder |

## Error Handling Rules

- **Per-pair isolation**: a single folder pair's failure (unreachable source, bad credentials, robocopy error) logs the failure and continues to the next pair. It does NOT abort the run.
- **Retention runs only on successful sync**: if a pair's sync fails, retention is skipped for that pair — prevents deleting files when we couldn't refresh from source.
- **Fatal errors abort the sync loop**: invalid config, NIC enable failure, logging subsystem failure. FINALLY block still disables NICs.
- **NIC disable verification is non-negotiable**: if NICs can't be verified disabled at end, exit 3 and urgent email. This is the single most important security invariant.

## Testing Plan

- **Dry-run mode** (`-WhatIf`): resolves config, tags, lists what would sync and what would be deleted, without touching NICs, files, or SMB.
- **Config validation** (`-ValidateConfig`): parses and reports schema errors without running.
- **Pester unit tests** for:
  - Retention logic (the only destructive piece) — thorough coverage
  - Config parsing and validation
  - Tag filtering
  - Robocopy exit-code interpretation
- **Integration test fixture**: local-only test config using temp folders (no real NICs, no real SMB) for smoke-testing changes.

## Deployment Notes (for implementation plan)

- Scripts install to a fixed path (e.g. `C:\Program Files\ServerSync\`)
- `config.json` and logs live under `C:\ProgramData\ServerSync\` with restricted ACLs
- Code signing certificate required on the target server
- Dedicated service account created before first run
- Event Log source registered during install
- Task Scheduler folder `\ServerSync\` created during install
