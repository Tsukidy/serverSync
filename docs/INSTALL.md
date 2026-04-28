# ServerSync Installation Guide

Step-by-step installation on the air-gapped server. For ongoing operations,
configuration deep-dives, and troubleshooting, see
[DEPLOYMENT.md](DEPLOYMENT.md).

## Time required

About 30 minutes if you already know the source servers and have admin access.

## Before you start

You need:

- **Local Administrator** access on the air-gapped Windows Server
- A list of source servers and the SMB share path on each
- (Recommended) a separate management NIC so you don't lock yourself out
  while testing — not strictly required
- The `CredentialManager` PowerShell module — either available via internet
  during install, or its module folder copied over from another machine

## Two accounts you must create first

You'll create one account on the air-gapped server and one on each source
server. **Create them before running the installer.**

### On the air-gapped server: `ServerSyncSvc`

This account will run the orchestrator script via Task Scheduler.

```powershell
$pw = Read-Host "Password for ServerSyncSvc" -AsSecureString
New-LocalUser -Name ServerSyncSvc -Password $pw `
    -PasswordNeverExpires -UserMayNotChangePassword -AccountNeverExpires `
    -Description "ServerSync run-as account"
Add-LocalGroupMember -Group Administrators -Member ServerSyncSvc
```

**Why Administrators?** Because `Enable-NetAdapter` and `Disable-NetAdapter`
require admin rights. There is no way to toggle NICs without admin.

### On each source server: `ServerSyncReader`

This account is what the air-gapped server authenticates as when reading
the source's SMB share. It needs read-only access — nothing more.

```powershell
$pw = Read-Host "Password for ServerSyncReader" -AsSecureString
New-LocalUser -Name ServerSyncReader -Password $pw `
    -PasswordNeverExpires -UserMayNotChangePassword -AccountNeverExpires `
    -Description "ServerSync pull credential (read-only)"
# Default Users group is fine; nothing else needed.
```

Then on the same source server, grant Share + NTFS Read on the backup folder:

```powershell
# If the share already exists, just add Read for ServerSyncReader.
# If you need to create one:
New-SmbShare -Name "Backups" -Path "D:\Backups" -ReadAccess "ServerSyncReader"

$acl = Get-Acl "D:\Backups"
$rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
    "ServerSyncReader", "ReadAndExecute,ListDirectory",
    "ContainerInherit,ObjectInherit", "None", "Allow")
$acl.AddAccessRule($rule)
Set-Acl "D:\Backups" $acl
```

Repeat for every source server.

## Step 1 — Get the code onto the air-gapped server

Copy the `serverSync` repo folder to the air-gapped server. If it has
transient internet:

```powershell
git clone https://github.com/Tsukidy/serverSync.git C:\serverSync
```

Otherwise, copy via approved removable media to the same location.

## Step 2 — Install the CredentialManager module

The orchestrator and GUI both depend on this PowerShell module.

**With internet during install:**

```powershell
Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
Install-Module CredentialManager -Scope AllUsers -Force
```

**Offline:** install on a connected machine, then copy
`C:\Program Files\WindowsPowerShell\Modules\CredentialManager\` (the entire
folder) to the same path on the air-gapped server.

Verify:

```powershell
Import-Module CredentialManager
Get-Command -Module CredentialManager
```

## Step 3 — Run the installer

Open PowerShell **as a Local Administrator** (your own admin login is fine —
this is not the same as `ServerSyncSvc`):

```powershell
cd C:\serverSync
.\src\Install-ServerSync.ps1 -ServiceAccount "$env:COMPUTERNAME\ServerSyncSvc"
```

What this does:

- Creates `C:\ProgramData\ServerSync\` and `\ProgramData\ServerSync\logs\`
- Applies restricted ACLs — **only `Administrators`, `SYSTEM`, and the account
  passed as `-ServiceAccount` get Full Control**
- Registers the Windows Event Log source `ServerSync` (in Application log)
- Creates a Task Scheduler folder `\ServerSync\` for ServerSync's tasks

The installer is idempotent. Running it again does not break anything.

Optional flags:

```powershell
.\src\Install-ServerSync.ps1 `
    -ServiceAccount  "$env:COMPUTERNAME\ServerSyncSvc" `
    -InstallRoot     "C:\Program Files\ServerSync" `
    -DataRoot        "C:\ProgramData\ServerSync" `
    -EventLogSource  "ServerSync"
```

## Step 4 — Move the scripts to a permanent location

Optional but recommended. Keeps everything tidy:

```powershell
Copy-Item -Recurse C:\serverSync 'C:\Program Files\ServerSync\'
```

The rest of this guide assumes scripts are at `C:\Program Files\ServerSync\`.

## Step 5 — Store source credentials

> **Critical:** Run this from an interactive console — RDP or physical
> console. **Not over SSH.** SSH gives you a Network logon and credentials
> stored in that context cannot be read by Task Scheduler later (error 1312).

Log in as `ServerSyncSvc` (RDP, switch user, etc.). Then for each source:

```powershell
cd 'C:\Program Files\ServerSync'
.\src\Setup-Credentials.ps1 -Target ServerSync-Backup01
# Enter the username and password of the ServerSyncReader account
# on the source server when prompted.
```

The `-Target` value is just a label — pick anything you want. It must match
what you'll put in `config.json` later.

Repeat for each source server (e.g. `ServerSync-Backup02`, etc.).

If email alerts will use authenticated SMTP, also store the SMTP credential:

```powershell
.\src\Setup-Credentials.ps1 -Target ServerSync-SMTP
```

## Step 6 — Create the config file

Copy the sample to the data root and edit it:

```powershell
Copy-Item 'C:\Program Files\ServerSync\config\config.sample.json' `
          'C:\ProgramData\ServerSync\config.json'
notepad 'C:\ProgramData\ServerSync\config.json'
```

Minimum changes you'll always make:

- `network.nics` — the NIC names that should be toggled. Get them with
  `Get-NetAdapter | Format-Table Name, Status, InterfaceDescription`.
  **Do not list a management NIC here.**
- `network.ready_check_host` — IP/hostname pinged after enabling NICs to
  confirm the network is usable. A backup server or your gateway is fine.
- `email.*` — fill in if you want alerts; otherwise leave `enabled: false`.
- `folder_pairs` — replace the example. For each source server you want to
  pull from, add an entry with `name`, `source` (UNC path), `destination`
  (local path), `credential_target` (matching what you stored in Step 5),
  optional `retention`, and `tags: ["default"]`.

Validate the config without running anything:

```powershell
.\src\Start-ServerSync.ps1 -ValidateConfig `
    -ConfigPath 'C:\ProgramData\ServerSync\config.json'
```

Exit code 0 means the config is well-formed. Exit code 2 means errors —
they print to stderr telling you what's wrong.

## Step 7 — First test run

Logged in as `ServerSyncSvc` (still on the console / RDP):

```powershell
.\src\Start-ServerSync.ps1 -ConfigPath 'C:\ProgramData\ServerSync\config.json'
```

Watch the log live in another window:

```powershell
Get-Content 'C:\ProgramData\ServerSync\logs\sync-*.log' -Wait
```

Expected: NICs enabled → each pair authenticated → robocopy copies → retention
prunes old files → NICs disabled and verified → exit 0.

Exit codes:

| Code | Meaning |
|---|---|
| 0 | All pairs succeeded, NICs verified disabled |
| 1 | Partial failure — at least one pair failed; NICs still disabled OK |
| 2 | Fatal — config invalid, NIC enable failed, etc. |
| 3 | **NIC disable verification failed** — investigate immediately |

## Step 8 — Schedule it

Easiest way: run the GUI from the air-gapped console:

```powershell
.\src\ServerSync-Manager.ps1
```

Click the **Schedule** tab → **Add task**. Pick a time after your source
backups complete. Set Run-As to `HOSTNAME\ServerSyncSvc`. Done.

For PowerShell-only setup, see
[DEPLOYMENT.md → Scheduling](DEPLOYMENT.md#scheduling).

## Step 9 — Confirm scheduled run

Wait for the next scheduled time, then check:

```powershell
Get-ScheduledTaskInfo -TaskName "Daily Sync" -TaskPath "\ServerSync\"
Get-Content 'C:\ProgramData\ServerSync\logs\sync-*.log' | Select-Object -Last 30
```

Last result `0` and an `[INFO] NICs verified disabled` line near the end of
the log = success.

## What you have now

- Run-as account `ServerSyncSvc` with no interactive logons happening
- All sync activity logged under `C:\ProgramData\ServerSync\logs\`
- Critical events surfaced to Windows Event Log under source `ServerSync`
- NICs toggled on and off in a tight window
- Backup files pulled to your air-gapped destination, with per-pair
  retention pruning the old copies

## Troubleshooting common install issues

See [DEPLOYMENT.md → Troubleshooting](DEPLOYMENT.md#troubleshooting). The
most common ones during install:

- **`CredRead failed with the error code 1312`** — credentials were stored
  via SSH, not an interactive console. Re-store via RDP/console as
  `ServerSyncSvc`.
- **`Access is denied`** from robocopy or `New-PSDrive` — usually an ACL
  problem on the source side. Reverify share and NTFS Read for
  `ServerSyncReader`.
- **Installer fails on `Set-Acl`** — the `-ServiceAccount` you passed
  doesn't exist. Create it first (Step 0 above).
