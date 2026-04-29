# ServerSync v2 Design Amendment

**Date:** 2026-04-29
**Status:** Approved
**Amends:** `2026-04-22-serversync-design.md`

This amendment adds two features to the v1 design without changing existing
behavior. Pairs and installations that don't use the new features behave
exactly as before.

## Features

1. **Mirror retention mode** — per-pair option to use `robocopy /MIR` and
   skip the custom retention pass
2. **In-place update mechanism** — admin-triggered git-based update of the
   install with rollback safety

---

## 1. Mirror retention mode

### Motivation

The v1 design treats sync as additive (`/XO`, never delete) and concentrates
all destruction in `Invoke-Retention`. That's good for the "air-gapped server
holds more copies than source" case, but adds maintenance burden when the
operator just wants the destination to mirror the source. Mirror mode is an
opt-in shortcut for the simpler case.

### Trade-off

Mirror mode means the destination tracks the source exactly. If the source's
own retention removes a file, the next sync removes it from the air-gapped
destination too. **This makes the air-gapped copy less effective as a
"last copy of record" defense, but maintenance is simpler — only one
retention policy to manage, on the source side.**

This is an explicit, per-pair opt-in. Other pairs continue to use additive
copy + custom retention.

### Config schema change

`retention.mode` and `retention.default_mode` accept a new value:

| Value | Meaning |
|---|---|
| `"files"` | (existing) keep N newest files matching extensions per subfolder |
| `"folders"` | (existing) keep N newest subfolders per subfolder |
| `"mirror"` | (new) robocopy `/MIR` — destination becomes exact copy of source |

When `mode = "mirror"`, the `count` and `extensions` fields are ignored.
Validation accepts a mirror policy with no other fields:

```json
"retention": { "mode": "mirror" }
```

If `count` or `extensions` are present alongside `mode = "mirror"`,
`Test-ServerSyncConfig` accepts the config but emits a warning that those
fields will be ignored.

### Robocopy flags change

When the resolved policy mode is `mirror`:

| State | Flags |
|---|---|
| Existing (files / folders modes) | `/E /Z /COPY:DAT /XO /R:N /W:N /MT:N /NP /LOG+:` |
| Mirror mode | `/MIR /Z /COPY:DAT /R:N /W:N /MT:N /NP /LOG+:` |

`/MIR` is documented by Microsoft as `/E + /PURGE`. We drop `/E` (redundant)
and `/XO` (would prevent overwriting newer destination files, contradicting
"mirror"). All other flags stay identical.

### Orchestrator behavior

After `Invoke-RobocopySync` returns success, the orchestrator inspects the
resolved policy:

```powershell
if ($policy.Mode -eq 'mirror') {
    Write-Log "  retention: skipped (mirror mode — robocopy /PURGE handled deletion)"
} else {
    Invoke-Retention -DestinationRoot $pair.destination -Policy $policy ...
}
```

Mirror pairs also emit a loud pre-sync log line so the destructive nature is
unambiguous in audits:

```
[INFO]   robocopy MIRROR mode — destination will match source exactly,
        including any deletions on source side
```

### Tests

- `ConfigLoader.Tests.ps1`: `Resolve-RetentionPolicy` returns `Mode='mirror'`
  for a pair specifying mirror mode; falls back to `default_mode='mirror'`
  correctly
- `ConfigLoader.Tests.ps1`: `Test-ServerSyncConfig` accepts `mode='mirror'`
- `SyncOperations.Tests.ps1`: `Build-RobocopyArgs -Mirror` includes `/MIR`,
  excludes `/E` and `/XO`

### Backwards compatibility

- Existing configs with `mode='files'` or `mode='folders'` are unchanged
- Default mode stays `'files'` if a config omits `default_mode`
- Existing tests stay green

---

## 2. In-place update mechanism

### Motivation

Updates currently require copying files manually onto the air-gapped server.
For a deployment where update windows can coincide with sync windows
(network briefly enabled), a small admin-triggered update script reduces the
operational burden.

### Design principles

- **Admin-triggered only** — never invoked from the orchestrator, never
  scheduled, never automatic
- **Opt-in** — disabled by default in config; enabled explicitly per
  installation
- **Same NIC discipline as orchestrator** — uses the existing
  `NetworkControl` module, so the update window has the same enable/verify-
  disable contract as a regular sync
- **Rollback safety** — captures a git tag before update; restores from tag
  if the post-update smoke test fails
- **No effect on data outside `install_root`** — config, logs, and credentials
  live in `C:\ProgramData\ServerSync\` and Credential Manager respectively;
  none of these are touched by an update

### Config schema addition

New top-level section in `config.json`:

```json
"update": {
    "enabled": false,
    "repo_url": "https://github.com/Tsukidy/serverSync.git",
    "branch": "main",
    "install_root": "C:\\Program Files\\ServerSync",
    "backup_tag_count": 3
}
```

Field meanings:

| Field | Meaning |
|---|---|
| `enabled` | Master switch. If `false`, `Update-ServerSync.ps1` refuses to run. Default: `false`. |
| `repo_url` | Git URL to fetch from. Used to set the `origin` remote at the start of every update so the URL can change in config without touching the .git config manually. |
| `branch` | Branch to track. Default: `"main"`. |
| `install_root` | Path where the scripts live, and which is itself a git working directory. The update operates on this tree. |
| `backup_tag_count` | Number of pre-update rollback tags to retain before pruning. Default: `3`. |

### New script: `src/Update-ServerSync.ps1`

Admin-triggered update orchestrator. Mirrors the structure of
`Start-ServerSync.ps1` for the NIC-safety wrapper but does no sync itself.

Workflow:

1. Load and validate `config.json`
2. Refuse if `update.enabled` is `false` (exit 2)
3. Refuse if `install_root` is not a git working directory (exit 2)
4. Confirm with admin: `Read-Host "Type yes to update"`. Skipped if `-Force`
   is passed.
5. **TRY:**
   - Enable NICs (`Enable-ServerSyncNics`)
   - Wait for network readiness (`Wait-NetworkReady`)
   - `Push-Location $install_root`
   - **Capture rollback point:** `git tag --force "serversync-pre-update-<UTC-timestamp>"`
   - `git remote set-url origin $update.repo_url`
   - `git fetch origin --tags --prune`
   - `git checkout $update.branch`
   - `git reset --hard "origin/$update.branch"`
   - Record new HEAD commit hash for logging
6. **FINALLY:**
   - `Pop-Location`
   - Disable NICs and verify (same exit-3 invariant as orchestrator)
7. **Smoke test:** `& "$install_root\src\Start-ServerSync.ps1" -ValidateConfig -ConfigPath $configPath`
8. **If smoke test fails (non-zero exit):**
   - `git -C $install_root reset --hard "<rollback-tag>"`
   - Send urgent email (if email enabled) — "ServerSync update failed,
     rolled back to <prev-commit>"
   - Write Event Log error
   - Exit 4
9. **If smoke test passes:**
   - Rotate old `serversync-pre-update-*` tags (keep newest `backup_tag_count`)
   - Send summary email (if `send_on=always`)
   - Exit 0

### Exit codes

| Code | Meaning |
|---|---|
| 0 | Update succeeded; smoke test passed; new code is live |
| 2 | Refused before any side effects (config invalid, `enabled=false`, install_root not a git repo) |
| 3 | Critical: NIC disable verification failed at end of run (same as orchestrator) |
| 4 | Update applied but smoke test failed; rollback succeeded; old code is live |
| 5 | Update applied, smoke test failed, AND rollback failed; install state is unknown — **page someone immediately** |

### Why `git reset --hard` instead of `git pull`

A deployed install should not have local edits. If anyone has made local
edits, `git pull` will fail or merge ambiguously. `git reset --hard` makes
the update atomic and predictable — the install matches `origin/<branch>`
exactly, no exceptions. Local edits are lost (which is the point).

### What's not changed by an update

- `C:\ProgramData\ServerSync\config.json` — config lives outside `install_root`
- `C:\ProgramData\ServerSync\logs\` — same
- Credentials in Windows Credential Manager — same
- Scheduled tasks — task definitions reference paths inside `install_root`
  and continue working without modification
- ACLs on data directories — left alone

### What if `repo_url` changes in the future

The script always runs `git remote set-url origin $update.repo_url` before
fetching, so editing the field in `config.json` is sufficient — no manual
git config maintenance required.

### Validation additions

`Test-ServerSyncConfig` adds checks for the `update` section (only when
present):

- `repo_url` must be a non-empty string and look like a URL (basic shape
  check, not a deep validation)
- `branch` must be a non-empty string with no whitespace or shell-special
  characters
- `install_root` must be a non-empty string
- `backup_tag_count` must be an integer >= 1

### Tests

- `ConfigLoader.Tests.ps1`: `Test-ServerSyncConfig` accepts a valid
  `update` section, rejects missing/empty `repo_url`, rejects negative
  `backup_tag_count`
- The git operations themselves are not unit-tested (they require a real
  git working directory and network); integration test on a Windows VM
  with a fork of the repo is the verification path

### Doc updates

- `INSTALL.md` — add "Updating" section explaining the workflow and `enabled` flag
- `DEPLOYMENT.md` — add full operations section: how to update, how rollback works, what to do on exit codes 4 and 5
- `README.md` — one-line pointer to update mechanism in docs index

---

## What's NOT changed by this amendment

- NIC enable/disable safety contract — same `try`/`finally` pattern
- Credential storage — Windows Credential Manager, unchanged
- GUI scope — no GUI changes for either feature; admins use a terminal for
  updates and edit `config.json` directly (or via the existing Config tab)
  to set retention modes
- Email/Event Log alerting — unchanged contracts
- Test framework — Pester 5.x, same approach
- Existing modules — only additive changes; no breaking changes to any
  exported function signature

## Cross-cutting concerns

### Audit findings (from 2026-04-29 security audit)

This amendment does not address any of the v1 audit findings. Specifically,
critical items C1 (NIC verify trust gap), C2 (SMB password as plaintext arg),
C3 (`robocopy.extra_flags` allowlist), C4 (retention path containment), and
C5 (`Test-Path` wildcard) remain open and are tracked separately. Mirror
mode does not introduce new instances of those issues — it uses the same
`Invoke-RobocopySync` flow. The update mechanism inherits C1 (NIC verify)
and shares its mitigation status.

### Backwards compatibility

- A v1 config (no `update` section, no `mode='mirror'` anywhere) runs
  identically under v2
- A v2 config can opt into either feature independently
