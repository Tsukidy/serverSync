# ServerSync Deployment Guide

End-to-end setup for the air-gapped Windows Server that pulls backups, plus
the source servers it reads from.

## Contents

- [Prerequisites](#prerequisites)
- [Accounts you need to create](#accounts-you-need-to-create)
- [Air-gapped server install](#air-gapped-server-install)
- [Storing source-server credentials](#storing-source-server-credentials)
- [Writing the config file](#writing-the-config-file)
- [Source server setup](#source-server-setup)
- [First test run](#first-test-run)
- [Scheduling](#scheduling)
- [Operations](#operations)
- [Troubleshooting](#troubleshooting)

---

## Prerequisites

### Air-gapped server

- Windows Server 2016+ or Windows 11 (Pro/Enterprise)
- Windows PowerShell 5.1 (built in) — PowerShell 7 also works
- The `CredentialManager` PowerShell module v2.0+ — install once with internet,
  then keep on the air-gapped box, or copy the module folder over
- Pester 5.x is only needed if you want to run unit tests on the box (not
  required for normal operation)
- Two NICs recommended — one for the actual sync, and one (optional) on a
  management/admin network so the box stays reachable when sync is idle.
  This is not strictly required.
- A destination volume with enough capacity for `retention.default_count *
  average backup size * folder_pairs`

### Source servers

- Windows Server (any modern version) with the backup files on an SMB share
- Each source must be reachable from the air-gapped server during the sync
  window
- Acronis (or whatever produces your `.TIB` files) configured to write to the
  share

### Network

- During the sync window, the air-gapped server must reach every source
  server's SMB port (TCP 445)
- Outside the sync window, the air-gapped server has no network at all
  (NICs disabled by the script)

---

## Accounts you need to create

There are three classes of account. Decide names and create them before
installing.

### A) Run-as account — air-gapped server only

This account runs the orchestrator script.

| Property | Value |
|---|---|
| Suggested name | `ServerSyncSvc` |
| Type | Local user (recommended) on the air-gapped server |
| Group membership | Local **Administrators** (required — `Disable-NetAdapter` needs admin) |
| Right | "Log on as a batch job" (granted automatically to Administrators in default policy; verify with `secpol.msc`) |
| Password | Strong (32+ characters), set to never expire |
| Interactive login | Disabled is ideal but not required |
| Where it appears | Passed as `Install-ServerSync.ps1 -ServiceAccount`, used by Task Scheduler |

Create with:

```powershell
$pw = Read-Host "Password for ServerSyncSvc" -AsSecureString
New-LocalUser -Name ServerSyncSvc -Password $pw -PasswordNeverExpires `
    -UserMayNotChangePassword -AccountNeverExpires `
    -Description "ServerSync run-as account"
Add-LocalGroupMember -Group Administrators -Member ServerSyncSvc
```

### B) Read-only account on each source server

This account is what the orchestrator authenticates as when it connects to the
source server's SMB share. It needs nothing more than read access to the
backup files.

| Property | Value |
|---|---|
| Suggested name | `ServerSyncReader` |
| Type | Local user on each source server (or one domain account in a domain) |
| Group membership | None special; the default `Users` group is fine |
| Right | "Access this computer from the network" (default for any local user) |
| Share permission | Read on the share that contains the backup files |
| NTFS permission | Read & Execute on the underlying folder tree |
| Interactive login | Should be denied — this account is only for SMB |

You can use one shared account across multiple sources, or one per source.
The latter limits blast radius if a credential leaks.

### C) Installer account

The account you run `Install-ServerSync.ps1` as. **Not stored anywhere** —
only used during install.

- Any account with **Local Administrator** rights on the air-gapped server
- Could be your own admin login, the built-in `Administrator`, or a domain
  admin
- Used once. Doesn't appear in config or scripts.

---

## Air-gapped server install

### Step 1 — Get the code onto the box

If you have transient internet access:
```powershell
git clone https://github.com/Tsukidy/serverSync.git C:\serverSync
```

If not, copy the repo folder over via approved removable media.

### Step 2 — Install the CredentialManager module

If the air-gapped server has internet just for setup:
```powershell
Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
Install-Module CredentialManager -Scope AllUsers -Force
```

If it doesn't, install it on a connected machine, then copy the entire module
folder to the air-gapped box at `C:\Program Files\WindowsPowerShell\Modules\CredentialManager\`.

### Step 3 — Create the run-as account

Use the script in [Accounts → A](#a-run-as-account--air-gapped-server-only)
above.

### Step 4 — Run the installer

**As a Local Administrator** (not as `ServerSyncSvc`):

```powershell
cd C:\serverSync
.\src\Install-ServerSync.ps1 -ServiceAccount "$env:COMPUTERNAME\ServerSyncSvc"
```

The installer will:
1. Create `C:\ProgramData\ServerSync\` and `\ProgramData\ServerSync\logs\`
2. Apply restricted ACLs — only `Administrators`, `SYSTEM`, and the
   `-ServiceAccount` you passed get Full Control
3. Register the Windows Event Log source `ServerSync` in the Application log
4. Create a Task Scheduler folder `\ServerSync\` for scheduled tasks

The installer is idempotent — running it again won't break anything.

Optional parameters:

```powershell
.\src\Install-ServerSync.ps1 `
    -ServiceAccount "$env:COMPUTERNAME\ServerSyncSvc" `
    -InstallRoot   "C:\Program Files\ServerSync" `
    -DataRoot      "C:\ProgramData\ServerSync" `
    -EventLogSource ServerSync
```

### Step 5 — Move the scripts to a fixed location (optional but recommended)

```powershell
Copy-Item -Recurse C:\serverSync 'C:\Program Files\ServerSync\'
```

Future references to script paths in this guide assume `C:\Program Files\ServerSync\`.

---

## Storing source-server credentials

> **Critical:** This step **must** be done from an interactive console session
> on the air-gapped server — the physical console, an RDP session, or a local
> PowerShell window logged in as `ServerSyncSvc`.
>
> Do **not** run `Setup-Credentials.ps1` over SSH. SSH gives you a Network
> logon token. Credentials stored in that context are bound to the SSH session
> and child processes (Task Scheduler, scheduled `powershell.exe` invocations)
> will fail to read them with **error 1312 — "logon session does not exist"**.

### Step 1 — Log in as the run-as account

RDP into the air-gapped server as `ServerSyncSvc`. (Or use `runas` /
`PsExec.exe -i` from another admin login.)

### Step 2 — Store one credential per source server

You'll be prompted for the source-side username and password (the
`ServerSyncReader` account on the source server).

```powershell
cd 'C:\Program Files\ServerSync'
.\src\Setup-Credentials.ps1 -Target ServerSync-Backup01
.\src\Setup-Credentials.ps1 -Target ServerSync-Backup02
.\src\Setup-Credentials.ps1 -Target ServerSync-SMTP   # if email is enabled
```

The target name is arbitrary. It just has to match the `credential_target`
field in `config.json` for that pair.

### Step 3 — Verify

Still as `ServerSyncSvc`:

```powershell
Import-Module CredentialManager
Get-StoredCredential -Target ServerSync-Backup01 | Select-Object UserName
```

If this prints the username you stored, you're good. If it returns nothing,
the credential wasn't actually persisted (most often because you ran setup via
SSH).

---

## Writing the config file

Copy the sample and edit:

```powershell
Copy-Item C:\Program Files\ServerSync\config\config.sample.json `
          C:\ProgramData\ServerSync\config.json
notepad C:\ProgramData\ServerSync\config.json
```

### Top-level structure

```json
{
  "network":      { ... NIC names + readiness check ... },
  "robocopy":     { ... thread count + retries ... },
  "retention":    { ... global defaults for files/folders mode ... },
  "logging":      { ... log directory + Event Log source ... },
  "email":        { ... SMTP settings + when to alert ... },
  "folder_pairs": [ { ... each source → destination ... } ]
}
```

### Key fields to set

**`network.nics`** — array of NIC display names (as shown by `Get-NetAdapter`)
that the script will toggle. Use only the NIC(s) used for syncing. If you
have a separate management NIC, leave it off this list.

```powershell
Get-NetAdapter | Format-Table Name, Status, InterfaceDescription
```

**`network.ready_check_host`** — an IP or hostname the script pings after
enabling the NIC, to confirm the network is actually usable. Pick something
on the sync network that's reliably up (a backup server, your gateway).

**`logging.log_directory`** — should match what the installer set up. Default:
`C:\ProgramData\ServerSync\logs`.

**`logging.event_log_source`** — must match what the installer registered.
Default: `ServerSync`.

**`folder_pairs[].name`** — appears in logs and emails; pick something
descriptive.

**`folder_pairs[].source`** — UNC path to the source share, e.g.
`\\backup01.internal.lan\Backups\FileServer01`.

**`folder_pairs[].destination`** — local path on the air-gapped server
where the pulled files go.

**`folder_pairs[].credential_target`** — must match a target name from
[Storing source-server credentials](#storing-source-server-credentials).

**`folder_pairs[].retention`** — per-pair retention. Three modes:

```json
{ "mode": "files", "extensions": [".TIB"], "count": 5 }
```
Keep N newest files matching extensions, per immediate subfolder.

```json
{ "mode": "folders", "count": 7 }
```
Keep N newest subfolders, per immediate subfolder.

```json
{ "mode": "mirror" }
```
**Mirror mode** — robocopy uses `/MIR`, making the destination match the source
exactly. The destination tracks source's retention: if the source removes a
file, the next sync removes it from the destination too. No `count` or
`extensions` needed (ignored if present).

> **Trade-off of mirror mode:** Simpler maintenance (only one retention
> policy to manage, on the source side) but the air-gapped copy becomes
> less effective as a "last copy of record" defense — a compromised or
> buggy source that wipes its own backups will cause the air-gapped copy
> to wipe too on the next sync. Use mirror mode for sources where source-side
> retention is what you want everywhere, and use `files`/`folders` mode for
> sources where the air-gapped server should keep more (or different)
> copies than the source itself.

If `retention` is omitted entirely, the pair inherits `retention.default_*`
from the top level.

**`folder_pairs[].tags`** — controls when this pair runs:

- `["default"]` — runs when the orchestrator is invoked with no `-Tag` filter
  (the normal case) and excluded from any `-Tag <name>` runs that don't
  list it
- `["default", "daily"]` — runs on default runs AND on `-Tag daily` runs
- `["weekly"]` — only runs on `-Tag weekly`
- `[]` or no `tags` field — pair is **disabled** (soft pause for
  maintenance, never runs)

### Validate the config without running

```powershell
.\src\Start-ServerSync.ps1 -ValidateConfig -ConfigPath C:\ProgramData\ServerSync\config.json
```

Exit codes: 0 = OK, 2 = invalid (errors printed to stderr).

---

## Source server setup

On each Windows Server that has the backup files:

### Step 1 — Create the read-only account

```powershell
$pw = Read-Host "Password for ServerSyncReader" -AsSecureString
New-LocalUser -Name ServerSyncReader -Password $pw -PasswordNeverExpires `
    -UserMayNotChangePassword -AccountNeverExpires `
    -Description "ServerSync pull credential (read-only)"
# Default Users group is fine; nothing else needed.
```

### Step 2 — Grant share read

If the backups already live on a share, grant `ServerSyncReader` Read share
permission. If you need to create a share:

```powershell
New-SmbShare -Name "Backups" -Path "D:\Backups" -ReadAccess "ServerSyncReader"
```

### Step 3 — Grant NTFS read

```powershell
$acl = Get-Acl "D:\Backups"
$rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
    "ServerSyncReader", "ReadAndExecute,ListDirectory",
    "ContainerInherit,ObjectInherit", "None", "Allow")
$acl.AddAccessRule($rule)
Set-Acl "D:\Backups" $acl
```

### Step 4 — Smoke test from the air-gapped server

From the air-gapped server, logged in as `ServerSyncSvc`:

```powershell
$cred = Get-Credential   # enter ServerSyncReader credentials
New-PSDrive -Name TestSrc -PSProvider FileSystem -Root "\\source01\Backups" -Credential $cred
dir TestSrc:
Remove-PSDrive TestSrc
```

If you see the file list, SMB access works. If you get "access denied",
recheck share/NTFS ACLs.

---

## First test run

### Step 1 — Dry-run

```powershell
.\src\Start-ServerSync.ps1 -ConfigPath C:\ProgramData\ServerSync\config.json -WhatIf
```

This walks the config, resolves tags, and reports what *would* happen
without touching the network or files. Use it to confirm config sanity.

Note: `-WhatIf` skips the NIC enable, so robocopy can't actually run; it
just reports it would run.

### Step 2 — Live run, manual

Run logged in as `ServerSyncSvc` (so credentials resolve correctly):

```powershell
.\src\Start-ServerSync.ps1 -ConfigPath C:\ProgramData\ServerSync\config.json
```

Watch the log file in real time:

```powershell
Get-Content C:\ProgramData\ServerSync\logs\sync-*.log -Wait
```

### Exit codes

| Code | Meaning |
|---|---|
| 0 | All matched pairs succeeded; NICs verified disabled |
| 1 | Partial failure — one or more pairs failed; NICs disabled OK |
| 2 | Fatal error before sync loop (config invalid, NIC enable failed, etc.) |
| 3 | **Critical security failure** — NIC disable could not be verified at end of run. Triggers an urgent email if email is enabled. Investigate immediately. |

---

## Scheduling

### Option A — GUI (recommended for new setups)

Run `ServerSync-Manager.ps1` from the air-gapped server console:

```powershell
.\src\ServerSync-Manager.ps1
```

Click the **Schedule** tab. Click **Add task**.

- Schedule type: Daily / Weekly / Once
- Time: pick a window when source backups have already finished and the
  network is quiet
- Tag filter: `(no filter — default run)` for the normal case, or pick a
  tag if you want this scheduled task to only run a subset
- Run as: `HOSTNAME\ServerSyncSvc`

The GUI registers the task in the dedicated `\ServerSync\` Task Scheduler
folder (kept separate from system tasks).

### Option B — PowerShell directly

```powershell
$action = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument "-NoProfile -File `"C:\Program Files\ServerSync\src\Start-ServerSync.ps1`" -ConfigPath `"C:\ProgramData\ServerSync\config.json`""
$trigger = New-ScheduledTaskTrigger -Daily -At 2am
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 4)

Register-ScheduledTask -TaskName "Daily Sync" -TaskPath "\ServerSync\" `
    -Action $action -Trigger $trigger -Settings $settings `
    -User "$env:COMPUTERNAME\ServerSyncSvc" -RunLevel Highest -Force
```

### Multiple schedules with tags

For different syncs at different times, use tags:

```powershell
# Daily 2am — run pairs tagged "daily" only
... -Argument "-File ...\Start-ServerSync.ps1 -Tag daily" ...
# Weekly Sunday 3am — run pairs tagged "weekly" only
... -Argument "-File ...\Start-ServerSync.ps1 -Tag weekly" ...
```

---

## Operations

### Daily

Look at the most recent log:

```powershell
Get-Content (Get-ChildItem C:\ProgramData\ServerSync\logs\sync-*.log | Sort-Object LastWriteTime -Descending | Select-Object -First 1) | Select-Object -Last 50
```

Or use the **Logs** tab in `ServerSync-Manager.ps1`.

### Weekly

- Verify the destination volume has free space
- Check the Event Log (`Application` log, source `ServerSync`) for any errors
- Confirm the most recent `.TIB` files in destination match the most recent
  on each source

### Adding a new source

1. On the new source server: create `ServerSyncReader` and grant share/NTFS
   permissions
2. On the air-gapped server, logged in as `ServerSyncSvc`: store the
   credential — `.\src\Setup-Credentials.ps1 -Target ServerSync-NewBackup`
3. Edit `config.json` (or use the GUI Config tab) — add a new entry to
   `folder_pairs`
4. Validate: `.\src\Start-ServerSync.ps1 -ValidateConfig`
5. Wait for the next scheduled run, or run manually to confirm

### Pausing a pair

In `config.json`, remove all entries from that pair's `tags` array (or
delete the field entirely). The pair stays in the config but never runs.
Restore the tags to re-enable it.

### Rotating a source-side credential

1. Change the password on the source server (or rotate the
   `ServerSyncReader` account however your process works)
2. On the air-gapped server, logged in as `ServerSyncSvc`:
   `.\src\Setup-Credentials.ps1 -Target ServerSync-Backup01` — confirm
   overwrite when prompted
3. Run `Start-ServerSync.ps1 -Tag <something>` or wait for next scheduled run
   to verify

### Updating the install in place

ServerSync ships an admin-triggered update mechanism (`Update-ServerSync.ps1`).
It is **opt-in** — disabled by default — and never invoked by the orchestrator
or scheduled tasks.

#### One-time setup

Edit `config.json` and add (or enable) the `update` section:

```json
"update": {
    "enabled": true,
    "repo_url": "https://github.com/Tsukidy/serverSync.git",
    "branch": "main",
    "install_root": "C:\\Program Files\\ServerSync",
    "backup_tag_count": 3
}
```

`install_root` must be a git working directory (it will be if you cloned the
repo there during install per `INSTALL.md`).

#### Running an update

From any Local Administrator account on the air-gapped server:

```powershell
& 'C:\Program Files\ServerSync\src\Update-ServerSync.ps1' `
    -ConfigPath 'C:\ProgramData\ServerSync\config.json'
```

You will be prompted to confirm. Pass `-Force` to skip the prompt.

What it does:

1. Validates config and refuses to run if `update.enabled = false`
2. Captures a rollback git tag (`serversync-pre-update-<UTC timestamp>`)
3. Enables NICs (with the same verify-disable contract as the orchestrator)
4. `git fetch origin --tags --prune` then `git reset --hard origin/<branch>`
5. Disables NICs and verifies they're down
6. Runs `Start-ServerSync.ps1 -ValidateConfig` as a smoke test
7. **If the smoke test fails:** automatically rolls back to the captured tag
8. Prunes old rollback tags (keeps the newest `backup_tag_count`)

Configuration files (`config.json`), logs, and credentials are never touched
by an update — they live outside `install_root`.

#### Update exit codes

| Code | Meaning |
|---|---|
| 0 | Update succeeded; smoke test passed; new code is live |
| 2 | Refused before any side effects (config invalid, `enabled=false`, install_root not a git repo) |
| 3 | Critical: NIC disable verification failed (same as orchestrator) |
| 4 | Update applied, smoke test failed, **rollback succeeded** — old code is live |
| 5 | Update applied, smoke test failed, **rollback also failed** — install state unknown |

#### Recovering from exit code 4

A clean automatic rollback. The previous code is back in place. Investigate
what made the new commit fail the smoke test (check the most recent
`update-*.log`) and decide whether the upstream commit needs a fix or your
local config has drifted.

#### Recovering from exit code 5

This means the update was partially applied, the smoke test failed, AND the
attempted rollback also failed. The install is in an unknown state. Manual
recovery:

```powershell
cd 'C:\Program Files\ServerSync'
git status                               # see where it is
git tag --list 'serversync-pre-update-*' # see rollback points
git reset --hard <newest-rollback-tag>   # manual rollback
git status                               # verify clean
```

Then run `Start-ServerSync.ps1 -ValidateConfig` to confirm the install is
working again. If `git reset` itself fails, you may need to re-clone the
repo into `install_root` from a known-good commit.

#### Changing the upstream repo URL

Edit `update.repo_url` in `config.json` and run `Update-ServerSync.ps1`.
The script runs `git remote set-url origin <new_url>` at the start of each
update, so the change picks up automatically.

---

## Troubleshooting

### `CredRead failed with the error code 1312`

The credential isn't readable by the process trying to use it. Cause: the
credential was stored in a different logon session (most often: stored over
SSH, or stored as a different user than the one Task Scheduler runs as).

**Fix:** RDP or sit at the console, log in as `ServerSyncSvc`, run
`Setup-Credentials.ps1` again to re-store the credential.

### `Access is denied` from robocopy / SMB

- Confirm the source-side `ServerSyncReader` has share Read AND NTFS
  Read & Execute on the target folder
- Confirm the credential stored on the air-gapped server matches the
  source-side username/password (typo in either side's password is the
  most common cause)
- Try `New-PSDrive` from the air-gapped server with the same credential to
  isolate the issue

### Exit code 3 — NIC disable verification failed

This is the most serious failure. NICs may still be up. Investigate:

```powershell
Get-NetAdapter | Select-Object Name, Status
```

Manually disable any NIC that's up:

```powershell
Disable-NetAdapter -Name "Ethernet0" -Confirm:$false
```

Look at the most recent log to see what happened. Common causes: the
account didn't have admin (so `Disable-NetAdapter` failed), a Group Policy
prevented disabling, or a NIC was renamed and no longer matches the config.

### `network not ready after Xs`

The script enabled the NIC(s) but the configured `ready_check_host` didn't
respond. Either:
- The NIC didn't get an IP fast enough — increase
  `network.ready_timeout_seconds`
- The host isn't reachable — verify `ready_check_host` from a different
  machine on that network
- DHCP issue on the sync network

### `Pester command not found` or tests fail to load

Air-gapped server has Pester 3 (the old one that ships with Windows). Install
Pester 5:

```powershell
Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
Install-Module Pester -Force -SkipPublisherCheck -MinimumVersion 5.0.0 -Scope CurrentUser
```

If tests don't load even after install, set ExecutionPolicy and import
explicitly:

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned -Force
Import-Module 'C:\Users\<you>\Documents\WindowsPowerShell\Modules\Pester\5.7.1\Pester.psd1' -Force
```

### Email isn't sending

- Check `email.enabled = true` in `config.json`
- Check `email.send_on` — `"failure"` only sends on failures, `"always"`
  sends every run
- Confirm SMTP credentials stored under `email.credential_target` (if SMTP
  requires auth)
- Confirm the air-gapped server can reach the SMTP server during the sync
  window
- The orchestrator logs `[WARN] Email send failed: ...` if the send
  attempt errored
