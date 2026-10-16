# Server guide

The AppDepot server is a Python service that

1. checks the internet for new application versions on a schedule,
2. downloads them into the repository and verifies their hashes,
3. packages each installer for Intune,
4. removes versions beyond the retention limit,
5. records everything in the database, and
6. serves the catalog (REST API) and files (HTTP + SMB share) to clients.

## Requirements

- Python 3.10 or newer
- Disk space: roughly *(number of apps) × 3 versions × 2* (installer + `.intunewin`)
- Outbound HTTPS to the vendors' download sites, `api.github.com` and
  `raw.githubusercontent.com` (winget and GitHub sources) and `cdn.winget.microsoft.com`
  (winget search when adding applications)
- Inbound TCP 8080 (API/HTTP) and 445 (SMB) from your client VLANs

## Installation on Windows Server (recommended)

Windows is the natural host because clients install from an SMB share using their domain
accounts. Run as administrator:

```powershell
cd AppDepot\server\deploy
.\Install-AppDepotServer.ps1 `
    -InstallPath C:\AppDepot `
    -RepositoryPath D:\AppDepot\Repository `
    -ShareName AppDepot `
    -Port 8080 `
    -AllowedSubnets 10.10.0.0/16, 10.20.30.0/24, 192.168.50.0/24 `
    -NssmPath C:\Tools\nssm.exe
```

The script

- creates a virtual environment in `C:\AppDepot\venv` and installs the server,
- copies the example manifests to `C:\AppDepot\manifests`,
- writes `C:\AppDepot\appdepot.yaml` with a random API key (printed once),
- shares the repository as `\\<server>\AppDepot` — read for *Authenticated Users*
  (this includes computer accounts, so installs running as SYSTEM work), full control for
  Administrators,
- adds firewall rules for the API port (and SMB) limited to `-AllowedSubnets`,
- registers the **AppDepot** service through [NSSM](https://nssm.cc) or, without NSSM, a
  startup scheduled task running as SYSTEM.

Re-run it to upgrade; existing configuration is kept.

Then fetch the first versions:

```powershell
C:\AppDepot\venv\Scripts\appdepot-server.exe --config C:\AppDepot\appdepot.yaml check
```

## Installation on Linux

```bash
sudo useradd --system --home /opt/appdepot appdepot
sudo mkdir -p /opt/appdepot /srv/appdepot/repository && sudo chown appdepot: /opt/appdepot /srv/appdepot -R
sudo -u appdepot python3 -m venv /opt/appdepot/venv
sudo -u appdepot /opt/appdepot/venv/bin/pip install ./server
sudo -u appdepot cp server/appdepot.example.yaml /opt/appdepot/appdepot.yaml   # edit it
sudo -u appdepot cp -r server/manifests /opt/appdepot/
sudo cp server/deploy/appdepot.service /etc/systemd/system/
sudo systemctl enable --now appdepot
```

Share `/srv/appdepot/repository` with Samba (`server/deploy/smb.conf.snippet`) and set
`repository.unc_root` to that share. Without a share, clients use HTTP automatically.

### Docker

```bash
docker build -t appdepot ./server
docker run -d --name appdepot -p 8080:8080 -v /srv/appdepot:/data appdepot
```

`/data` holds `appdepot.yaml`, `manifests/`, the database and the repository.

## Configuration (`appdepot.yaml`)

| Setting | Default | Description |
|---|---|---|
| `server.host` | `0.0.0.0` | Listen address. `0.0.0.0` = all interfaces |
| `server.port` | `8080` | API / HTTP port |
| `server.public_url` | `http://localhost:8080` | URL clients use; HTTP download links are built from it |
| `server.api_key` | – | Required for admin API calls (`X-Api-Key`). Without a key, admin calls are only accepted from localhost. Can also be set with `APPDEPOT_API_KEY` |
| `repository.root` | `./repository` | Folder holding installers and packages |
| `repository.unc_root` | – | UNC path of the share pointing at `root`, e.g. `\\appdepot\AppDepot` |
| `repository.retain_versions` | `3` | Versions kept per application |
| `database.url` | `sqlite:///./appdepot.db` | SQLAlchemy URL (SQLite, PostgreSQL, SQL Server…) |
| `schedule.global` | `0 3 * * *` | Global cron schedule |
| `schedule.timezone` | server local | e.g. `Europe/London` |
| `schedule.max_concurrent` | `2` | Parallel downloads |
| `schedule.run_on_startup` | `false` | Check all apps when the service starts |
| `sources.github_token` | – | GitHub token: raises the API limit from 60 to 5,000 requests/hour. **Recommended** when you use winget or GitHub sources |
| `sources.proxy` | – | Outbound proxy URL |
| `sources.timeout` | `600` | Download timeout (seconds) |
| `installers.preferred_types` | `[msi, wix, msix, appx, burn, inno, nullsoft, exe]` | Installer preference applied across all sources of an app (MSI first) |
| `intune.enabled` | `true` | Build Intune packages |
| `intune.packager` | `native` | `native` (built-in) or `official` (IntuneWinAppUtil.exe) |
| `intune.intunewinapputil_path` | – | Path to IntuneWinAppUtil.exe for `official` |
| `manifests_dir` | `./manifests` | Application manifests |
| `logging.level` / `logging.file` | `INFO` / – | Log level and rotating log file |

Relative paths are relative to the configuration file.

### Database

SQLite needs no setup and is fine for hundreds of applications. For a shared or highly
available database:

```yaml
database:
  url: postgresql+psycopg://appdepot:secret@db01/appdepot          # pip install .[postgres]
  # url: mssql+pyodbc://@SQL01/AppDepot?driver=ODBC+Driver+18+for+SQL+Server&trusted_connection=yes
```

Tables are created automatically. See [database.md](database.md).

## Networking across VLANs

The server only needs to be **routable** from every client VLAN:

- The API listens on all interfaces (`server.host: 0.0.0.0`).
- Allow TCP **8080** (API/HTTP) and **445** (SMB) from each client subnet on the server
  firewall *and* on any inter-VLAN firewall/ACL. `-AllowedSubnets` does the server side.
- Use a **DNS name** in `server.public_url` and `repository.unc_root` that resolves in every
  VLAN (not an IP that is only valid on one segment).
- Where SMB is blocked between VLANs (guest or IoT networks), clients fall back to HTTP
  automatically with `TransferMethod Auto`, or can be forced to `Http`.
- For HTTPS, put the server behind a reverse proxy (IIS ARR, nginx) and set `public_url`
  to the `https://` address.

## Schedules

Cron format: `minute hour day-of-month month day-of-week`.

| Expression | Meaning |
|---|---|
| `0 3 * * *` | 03:00 every day (default) |
| `0 */6 * * *` | every 6 hours |
| `30 2 * * 1-5` | 02:30 Monday–Friday |
| `0 4 * * sun` | 04:00 on Sundays |

- **Global schedule** — checks every enabled app that has no schedule of its own.
- **Per-app schedule** — `schedule:` in the manifest, or an override set via API/CLI/PowerShell
  that survives manifest changes. `manual` means "only when asked".

```bash
appdepot-server schedule global "0 2 * * *"
appdepot-server schedule app Google.Chrome "15 */4 * * *"
appdepot-server schedule app Contoso.Legacy manual
appdepot-server schedule app Google.Chrome global      # back to the global schedule
```

```powershell
Set-DepotSchedule -Global -Schedule '0 2 * * *'
Set-DepotSchedule -Id Google.Chrome -Schedule '15 */4 * * *'
```

Changes made with the CLI are picked up by a running server within a minute; API changes
apply immediately.

## What happens during a check

1. **Every source** is queried; each returns all the installers it offers for its newest version.
2. The newest version is chosen and, for it, the most preferred installer type (MSI first —
   see [manifest-reference.md](manifest-reference.md#installer-preference-msi-first)).
   If that version is already stored with an equally good installer, the app is *up to date*;
   if an MSI appeared for a version stored as an EXE, the EXE is replaced.
   For `url` sources the ETag/Last-Modified headers are compared first.
3. The installer is streamed to `<root>\.tmp`, its SHA-256 computed and compared with the
   hash published by the source (winget, GitHub). Mismatches are rejected.
4. The installer type is determined (manifest → source → file inspection: MSI, NSIS,
   Inno Setup, WiX Burn, MSIX). MSI properties (ProductCode, ProductVersion, UpgradeCode)
   are read from MSI files.
5. The file moves to `<root>\<app>\<version>\installer\`.
6. Silent install/uninstall commands are generated, the `.intunewin`, deployment sheet,
   detection script and `metadata.json` are written.
7. The database is updated (version row, latest flags, app status) and events are logged.
8. Retention removes the oldest versions beyond the limit (files deleted, rows marked
   `purged` so history is kept).

Failures are recorded on the application (`last_check_status = failed`, `last_error`) and in
the event log; one failing application never stops the others.

## Admin command line

```
appdepot-server [--config FILE] <command>

  serve                          run API + scheduler (syncs manifests first)
  sync                           load manifests into the database
  check [APP_ID ...] [--force]   check now (all enabled apps by default)
  list                           applications, latest version, status
  versions APP_ID [--all]        stored versions (with --all: purged too)
  schedule show|global|app ...   view / change schedules
  repackage APP_ID VERSION       rebuild Intune package + commands (after manifest changes)
  purge [APP_ID]                 apply retention now
  events [--app ID] [--limit N]  event log
  validate FILE ...              validate manifest files
  verify-package FILE            verify an .intunewin (MAC + digest)

  app search QUERY               search the winget catalog
  app add WINGET_ID [--category C] [--arch x64] [--check] [--yes]
  app add --file MANIFEST.yaml [--check]
  app test (WINGET_ID | --file F | --id APP_ID)   preview: version, installers, MSI or not
  app template TYPE              print a manifest template (winget github web json url multi adobe manual)
  app create APP_ID --name NAME [--type T] [--args A] [--installer FILE --version V]   manual application
  app import APP_ID FILE [--version V] [--replace]   add an installer file as a version
  app remove APP_ID [--delete-files]
```

See [adding-applications.md](adding-applications.md).

## Backup and recovery

Back up the configuration file, the `manifests` folder and the database. The repository can
be re-downloaded, but each version folder also contains `metadata.json` with the full record.

## Security notes

- Keep the API key secret; it allows triggering downloads and changing schedules.
  Read endpoints are intentionally open to the LAN.
- The share is read-only for everyone except administrators and the service account.
- Clients verify each installer's SHA-256 against the database before running it.
- Path traversal is blocked on the `/files` endpoint; temporary files are never served.
