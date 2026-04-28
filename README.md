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
