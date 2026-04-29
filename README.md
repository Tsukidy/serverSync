# serverSync

Secure one-way backup sync for an air-gapped Windows Server.

Pulls backup files from one or more Windows Server sources over SMB, then
disables networking. Per-folder-pair retention keeps the N newest files (by
extension) or N newest subfolders on the air-gapped destination, independent
of source retention.

## Getting started

New deployment? Start with **[docs/INSTALL.md](docs/INSTALL.md)**.

Already running and need to operate, configure, or troubleshoot?
**[docs/DEPLOYMENT.md](docs/DEPLOYMENT.md)** has the full reference.

## Layout

- `src/Start-ServerSync.ps1` — orchestrator (runs from Task Scheduler or manually)
- `src/ServerSync-Manager.ps1` — WinForms admin GUI (config / logs / credentials / schedule tabs)
- `src/Setup-Credentials.ps1` — CLI credential setup helper
- `src/Install-ServerSync.ps1` — installer (directories, ACLs, Event Log source, Task Scheduler folder)
- `src/Update-ServerSync.ps1` — admin-triggered git-based update with rollback safety
- `src/Modules/*.ps1` — modules dot-sourced by the orchestrator and GUI
- `tests/*.Tests.ps1` — Pester tests (cross-platform compatible)
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

## Documentation

- **[docs/INSTALL.md](docs/INSTALL.md)** — step-by-step installation on the
  air-gapped server. Start here for a new deployment.
- **[docs/DEPLOYMENT.md](docs/DEPLOYMENT.md)** — full deployment and operations
  guide: account model, config reference, scheduling, daily ops, troubleshooting.
- **[docs/superpowers/specs/2026-04-22-serversync-design.md](docs/superpowers/specs/2026-04-22-serversync-design.md)**
  — full design specification (v1).
- **[docs/superpowers/specs/2026-04-29-serversync-v2-design.md](docs/superpowers/specs/2026-04-29-serversync-v2-design.md)**
  — v2 amendment: mirror retention mode and the in-place update mechanism.
- **[docs/superpowers/plans/2026-04-22-serversync-implementation.md](docs/superpowers/plans/2026-04-22-serversync-implementation.md)**
  — implementation plan (history of how the code came together).

## Development

Unit tests run anywhere PowerShell + Pester 5 are available, including
Windows PowerShell 5.1 on Windows Server / Windows 11:

    Invoke-Pester -Path tests -Output Detailed

End-to-end validation (NICs, SMB, Credential Manager, robocopy) must be done
on a Windows Server test VM that mirrors production.
