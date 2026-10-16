# AppDepot

A self-hosted application repository for Windows networks, similar to winget but on your own
server. AppDepot watches the internet for new application releases, downloads them into an
organised repository on your network, keeps the last three versions, packages every installer
as an Intune `.intunewin` with ready-to-paste install and uninstall commands, and records
everything in a database. Clients browse and install from it with a GUI, a command-line tool
or a PowerShell module.

```
                 internet (winget manifests, GitHub releases, vendor sites, JSON APIs)
                                          │  scheduled checks (global + per app)
                                          ▼
┌───────────────────────────── AppDepot server ─────────────────────────────┐
│  scheduler ─► sources ─► download + SHA-256 ─► repository ─► Intune packager│
│                                  │                    │                     │
│                                  ▼                    ▼                     │
│                          database (SQLite /     \\server\AppDepot\<app>\<ver>\│
│                          PostgreSQL / SQL)        installer\  intune\       │
│                                  │                                          │
│                        REST API + HTTP files (:8080)                        │
└──────────────────────────────────┬───────────────────────────────────────────┘
                                   │  any VLAN that can route to the server
          ┌────────────────────────┼─────────────────────────┐
          ▼                        ▼                         ▼
    AppDepot GUI            depot CLI                 PowerShell module
    (Show-DepotGui)    (depot install chrome)      (Install-DepotApp …)
```

## Features

**Server**
- Organised repository: `<root>\<app id>\<version>\installer|intune`, shared over SMB and HTTP
- Finds new versions automatically from **winget manifests**, **GitHub releases**, **web pages**
  (regex), **JSON APIs** or **fixed "latest" URLs** (version read from the MSI)
- Keeps the last **3 versions** per app (configurable globally and per app)
- **Global schedule** (cron) plus optional **per-application schedules** or manual-only apps
- Every downloaded installer is packaged as **`.intunewin`** (built-in packager, no Windows
  tool needed) with a **deployment sheet** (install/uninstall commands, return codes,
  detection rules) and a **detection script**
- Writes everything to the **database** on every change: latest version, available versions,
  file locations (UNC + HTTP), silent install data, download dates, hashes, audit log
- REST API with interactive docs at `/docs`, status dashboard at `/`
- Hash verification, per-app locking, concurrency limits, error tracking per application

**Client**
- **GUI**: catalog, installed apps, updates (with badge and *Update all*), activity, settings
- **CLI**: `depot list | search | show | install | upgrade | uninstall | download | status …`
  with `--json` output and meaningful exit codes
- **PowerShell module**: 18 documented cmdlets, pipeline support, `-WhatIf`, tab completion,
  formatted output, `Get-Help about_AppDepot`
- Installs from the SMB share or over HTTP, verifies SHA-256, handles reboot codes,
  detects installed versions from Programs and Features, optional daily auto-update task

## Repository layout

| Path | Contents |
|---|---|
| `server/appdepot_server/` | Server (Python 3.10+, FastAPI, SQLAlchemy, APScheduler) |
| `server/manifests/` | Application definitions (YAML) — 8 examples included |
| `server/deploy/` | Windows installer script, systemd unit, Samba share snippet |
| `server/tests/` | Server test suite (pytest) |
| `client/AppDepot/` | PowerShell module (Windows PowerShell 5.1 and PowerShell 7) incl. WPF GUI |
| `client/depot.ps1`, `depot.cmd` | Command-line client |
| `client/Install-AppDepotClient.ps1` | Client installer (Intune/GPO friendly) |
| `client/tests/` | Pester 5 tests |
| `docs/` | Documentation |

## Quick start

**1. Server** (Windows Server, as administrator, Python 3.10+ installed):

```powershell
cd server\deploy
.\Install-AppDepotServer.ps1 -RepositoryPath D:\AppDepot\Repository `
    -AllowedSubnets 10.10.0.0/16, 10.20.0.0/16 -NssmPath C:\Tools\nssm.exe
& C:\AppDepot\venv\Scripts\appdepot-server.exe --config C:\AppDepot\appdepot.yaml check
```

Open `http://<server>:8080/` for the dashboard. Linux and Docker are covered in
[docs/server.md](docs/server.md).

**2. Client** (each computer, as administrator — or deploy the script through Intune):

```powershell
.\client\Install-AppDepotClient.ps1 -ServerUrl http://appdepot.corp.example.com:8080 -AutoUpdate
```

```powershell
depot list
depot install Google.Chrome
depot upgrade --all
Show-DepotGui
```

**3. Add applications** by dropping a manifest into `manifests\` (see
[docs/manifest-reference.md](docs/manifest-reference.md)). The simplest form uses winget's
metadata:

```yaml
id: Notepad++.Notepad++
name: Notepad++
publisher: Notepad++ Team
category: Development
source:
  type: winget
  package: Notepad++.Notepad++
detection:
  display_name: '^Notepad\+\+'
```

## Documentation

- [Server guide](docs/server.md) — installation, configuration, networking across VLANs,
  schedules, retention, admin CLI, backup
- [Manifest reference](docs/manifest-reference.md) — sources, installer types, detection
- [Client guide](docs/client.md) — GUI, `depot` CLI and the full PowerShell cmdlet reference
- [Intune guide](docs/intune.md) — using the generated packages
- [REST API](docs/api.md) and [database schema](docs/database.md)

## Testing

```bash
cd server && pip install -e .[test] && pytest          # 39 tests
```

```powershell
Invoke-Pester ./client/tests                           # Pester 5
```
