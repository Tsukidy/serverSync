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

## Accounts and credentials

There are two distinct account concepts. They live on different machines and
serve different purposes. Don't conflate them.

### 1) Run-as account — on the air-gapped server

This is the account Task Scheduler runs the orchestrator as. It's what
`Install-ServerSync.ps1 -ServiceAccount` refers to.

Requirements:
- A **dedicated local account** (don't reuse a human admin). Suggested name:
  `ServerSyncSvc`.
- **Local Administrator** group membership — required because
  `Enable-NetAdapter` and `Disable-NetAdapter` need admin.
- **"Log on as a batch job"** right — required for Task Scheduler.
  Local Admins typically have this; verify in `secpol.msc` → Local Policies
  → User Rights Assignment if a task fails to start.
- Strong password set to never expire (it's only used by Task Scheduler).

The installer grants this account Full Control on `C:\ProgramData\ServerSync\`
(config + logs). Credentials this account stores in Credential Manager are
readable only by it and Administrators.

This account never authenticates to the source servers — it only runs the
script locally.

### 2) Pull credentials — accounts on the source servers

These are the accounts the orchestrator authenticates as when connecting to
each source server's SMB share. They're referenced by `credential_target` in
`config.json`.

Requirements on each source server:
- A user account (local or domain) with **read-only** access to the share
  and the underlying NTFS folder containing the backup files.
- "Access this computer from the network" right (default for local users on
  Windows Server).
- No interactive logon rights needed — these accounts only need to satisfy
  SMB authentication.

Suggested name: `ServerSyncReader` — one per source server, or one shared
domain account in a domain environment.

The credentials for these accounts are stored on the air-gapped server in
Windows Credential Manager (under target names you choose, e.g.
`ServerSync-Backup01`). The orchestrator looks them up by name; passwords
never appear in `config.json` or any script.

### Setup order

On the air-gapped server, as a local Administrator:

```
.\src\Install-ServerSync.ps1 -ServiceAccount "AIRGAP\ServerSyncSvc"
```

Then **log in interactively as `ServerSyncSvc`** (physical console or RDP — see
the next section about why not SSH) and store one credential per source:

```
.\src\Setup-Credentials.ps1 -Target ServerSync-Backup01
.\src\Setup-Credentials.ps1 -Target ServerSync-Backup02
```

On each source server, create the read-only account
(`ServerSyncReader` or domain equivalent) and grant it Share permission `Read`
plus NTFS `Read & Execute` on the folder containing the backup files.

### Quick reference

| Account | Where it lives | Purpose | Key rights |
|---|---|---|---|
| `ServerSyncSvc` | Air-gapped server | Runs the orchestrator | Local Admin, "Log on as batch job" |
| `ServerSync-Backup01` (credential) | Credential Manager on air-gapped server (stored by `ServerSyncSvc`) | Authenticates to one source server | Stores username + password of a `ServerSyncReader`-class account |
| `ServerSyncReader` | Each source server | Reads `.TIB` files for the puller | Share Read, NTFS Read & Execute |

## Design

Full design: `docs/superpowers/specs/2026-04-22-serversync-design.md`
Implementation plan: `docs/superpowers/plans/2026-04-22-serversync-implementation.md`

## Development

Unit tests run anywhere PowerShell + Pester 5 are available, including
Windows PowerShell 5.1 on Windows Server / Windows 11:

    Invoke-Pester -Path tests -Output Detailed

End-to-end validation (NICs, SMB, Credential Manager, robocopy) must be done on
a Windows Server test VM that mirrors production.

### Setting up credentials

**Always run `Setup-Credentials.ps1` from an interactive console session** —
the physical console, an RDP session, or a local PowerShell window. Do not run
it through SSH.

When credentials are stored in Credential Manager via an SSH session, Windows
binds them to the SSH (Network) logon token. Sub-processes spawned later
(child PowerShell, scheduled tasks) get their own logon token and cannot read
those credentials, failing with error 1312 ("logon session does not exist").
Storing the credentials from an interactive logon avoids this entirely.
