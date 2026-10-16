# Client guide

The AppDepot client has three faces built on one PowerShell module:

| Interface | Use it for |
|---|---|
| **GUI** — `Show-DepotGui` / Start menu *AppDepot* | End users and technicians browsing and installing |
| **CLI** — `depot` | Quick commands, batch files, task sequences (`--json` for scripts) |
| **PowerShell module** — `AppDepot` | Automation, remoting, reporting |

Works on Windows PowerShell 5.1 and PowerShell 7. Installing and detecting applications
requires Windows; browsing the catalog and downloading work on any OS.

## Installation

```powershell
# As administrator
.\Install-AppDepotClient.ps1 -ServerUrl http://appdepot.corp.example.com:8080
.\Install-AppDepotClient.ps1 -ServerUrl http://appdepot.corp.example.com:8080 -AutoUpdate -AutoUpdateTime 12:30
.\Install-AppDepotClient.ps1 -Uninstall
```

The installer copies the module to `%ProgramFiles%\WindowsPowerShell\Modules\AppDepot`, the CLI
to `%ProgramFiles%\AppDepot` (added to `PATH`), creates the Start menu shortcut and writes
`%ProgramData%\AppDepot\client.json`. `-AutoUpdate` registers the *AppDepot Auto Update*
scheduled task, which runs `depot upgrade --all` as SYSTEM daily (with up to an hour of random
delay to spread load).

To deploy with Intune, package the `client` folder as a Win32 app with install command
`powershell.exe -ExecutionPolicy Bypass -File Install-AppDepotClient.ps1 -ServerUrl http://...`
and uninstall command `... -File Install-AppDepotClient.ps1 -Uninstall`.

## GUI

```powershell
Show-DepotGui        # or: depot gui, or the Start menu shortcut
```

| View | What it shows |
|---|---|
| **Catalog** | Every application in the repository as a card with publisher, category, version and a status pill (*Available*, *Installed*, *Update available*). Search box filters by name, id, publisher or category. |
| **Installed** | Repository applications installed on this computer. |
| **Updates** | Installed applications with a newer version. The sidebar badge shows the count; *Update all* installs them. |
| **Add apps** | Three tabs (needs the server API key, under Settings): **From winget** — search, preview (with an *MSI available* badge), choose a category and add; **Upload installer** — create a manual application or add a version by uploading a file; **Manifest** — load a template (manual, adobe, web, json, github, url, multi, winget), edit, **Test** and add. |
| **Activity** | The server's event log (downloads, updates, purges, errors) and a log of this session's operations. |
| **Settings** | Server URL, transfer method, cache option, server API key, *Test connection*, *Open log folder*. |

Selecting an application opens the details pane: description, latest and installed versions,
installer technology, download size, date added to the repository, licence, website, a
version picker (any version kept in the repository) and *Install / Update / Reinstall* and
*Uninstall* buttons.

All work runs in background runspaces, so the window never freezes; a progress bar and status
line show what is happening. The connection indicator in the sidebar turns green when the
server answers. If the GUI is not elevated, a banner offers *Restart as administrator*.
Press **F5** to refresh.

## Command line: `depot`

```
depot list [filter] [--category C]       List applications in the repository
depot search <query>                     Search
depot show <id>                          Details, versions, install/uninstall commands, Intune package
depot versions <id> [--all]              Versions kept in the repository (--all includes purged)

depot installed                          Repository applications installed here
depot upgrade                            List available updates
depot upgrade <id> [<id>...] | --all     Install updates
depot install <id> [<id>...]             --version V  --force  --keep
depot uninstall <id> [--yes]
depot download <id> [--dest DIR]         --version V  --intune  --method Auto|Unc|Http

depot status [<id>]                      Server status / one application's check status
depot events [--app ID] [--last N]       Server event log [--errors]
depot server check [<id>...]             Check for new versions now [--force] [--wait]   (API key)
depot server schedule global "<cron>"                                                    (API key)
depot server schedule <id> "<cron>"|manual|global                                        (API key)

depot app search <query>                Search winget                                      (API key)
depot app add <wingetId> [--category C]  Add from winget [--check] [--replace] [--yes]      (API key)
depot app add --file <manifest.yaml>     Add from a manifest file                           (API key)
depot app test <wingetId>|--file F|--id ID   Preview: version, installers, MSI or not       (API key)
depot app template <type>                Manifest template (winget github web json url multi adobe manual)
depot app create <id> --name "Name"      Manual application [--type inno] [--installer FILE --version V] (API key)
depot app upload <id> <file> [--version V]   Upload an installer as a new version               (API key)
depot app remove <id> [--delete-files]                                                      (API key)

depot config                             Show configuration
depot config set <name> <value>          ServerUrl, TransferMethod, CachePath, LogPath, TimeoutSec,
                                         InstallTimeoutMinutes, KeepInstallers, ApiKey
depot config reset
depot test                               Test server and share connectivity
depot gui                                Open the GUI
depot help [command]
```

Global options: `--json` (machine-readable output), `--server URL`, `--quiet`, `--verbose`.

Exit codes: `0` success · `1` failure · `2` usage error · `3010` success, restart required.

```bat
depot install Google.Chrome 7zip.7zip --quiet
if %ERRORLEVEL%==3010 shutdown /r /t 300
```

```powershell
$updates = depot upgrade --json | ConvertFrom-Json
```

## PowerShell module

See **[powershell-reference.md](powershell-reference.md)** for every cmdlet's syntax,
parameters and examples, and `Get-Help about_AppDepot` for the conceptual overview.

### Cmdlets at a glance

| Area | Cmdlets |
|---|---|
| Catalog | `Get-DepotApp`, `Find-DepotApp`, `Get-DepotAppVersion` |
| This computer | `Get-DepotInstalledApp`, `Get-DepotUpdate`, `Install-DepotApp`, `Update-DepotApp`, `Uninstall-DepotApp`, `Save-DepotInstaller` |
| Server | `Get-DepotServerStatus`, `Get-DepotEvent`, `Invoke-DepotServerCheck`*, `Set-DepotSchedule`* |
| Adding applications | `Find-DepotWingetPackage`*, `Test-DepotAppSource`*, `New-DepotApp`*, `Publish-DepotInstaller`*, `Remove-DepotApp`*, `Get-DepotManifestTemplate`* — see [adding-applications.md](adding-applications.md) |
| Client | `Get-DepotConfig`, `Set-DepotConfig`, `Test-DepotConnection`, `Compare-DepotVersion`, `Show-DepotGui` |

\* needs the server API key (`Set-DepotConfig -ApiKey` or `$env:APPDEPOT_API_KEY`).

Conventions:

- Every state-changing cmdlet supports `-WhatIf` and `-Confirm`.
- `-Id` accepts pipeline input by value and by property name, and tab-completes from the
  server catalog.
- Objects have type names (`AppDepot.App`, `AppDepot.AppVersion`, `AppDepot.InstalledApp`,
  `AppDepot.Result`, `AppDepot.Event`) with formatted table views.
- Install/Update/Uninstall return `AppDepot.Result` objects and also write non-terminating
  errors on failure, so `-ErrorAction Stop` works as expected.

### Recipes

```powershell
# New computer build
'Google.Chrome', 'Mozilla.Firefox', '7zip.7zip', 'Notepad++.Notepad++' | Install-DepotApp

# Everything in a category
Get-DepotApp -Category Browsers | Install-DepotApp

# Update all and reboot if required
$r = Update-DepotApp -All
if ($r.RebootRequired -contains $true) { Restart-Computer -Force }

# Fleet report
Invoke-Command -ComputerName (Get-ADComputer -Filter * -SearchBase 'OU=Workstations,DC=corp,DC=example,DC=com').Name {
    Get-DepotUpdate
} | Select-Object PSComputerName, Id, InstalledVersion, LatestVersion | Export-Csv updates.csv -NoTypeInformation

# Roll back to an earlier stored version
Get-DepotAppVersion Mozilla.Firefox
Install-DepotApp Mozilla.Firefox -Version 131.0.2 -Force

# Gather Intune packages for this month's updates
Get-DepotApp | Where-Object DownloadedAt -gt (Get-Date).AddDays(-30) |
    ForEach-Object { Save-DepotInstaller $_.Id -IncludeIntunePackage -Destination "C:\Intune\$($_.Id)" }

# Server administration
Invoke-DepotServerCheck -Id Google.Chrome -Wait
Set-DepotSchedule -Id Google.Chrome -Schedule '0 */4 * * *'
Get-DepotEvent -Level error -Last 20
```

## Configuration

`%ProgramData%\AppDepot\client.json`, managed with `Set-DepotConfig` / `depot config set`
(administrator), overridable with environment variables:

| Setting | Default | Environment |
|---|---|---|
| `ServerUrl` | `http://appdepot:8080` | `APPDEPOT_SERVER` |
| `TransferMethod` | `Auto` (share, then HTTP) | |
| `CachePath` | `%ProgramData%\AppDepot\Cache` (elevated) / `%LOCALAPPDATA%\AppDepot\Cache` | |
| `LogPath` | `...\AppDepot\Logs` (same rule) | |
| `TimeoutSec` | `60` | |
| `InstallTimeoutMinutes` | `60` | |
| `KeepInstallers` | `false` | |
| `ApiKey` | – | `APPDEPOT_API_KEY` |

Standard (non-elevated) users automatically use per-user cache and log folders so they can never
modify an installer that an elevated session or the SYSTEM update task will run.

## Troubleshooting

| Symptom | Check |
|---|---|
| *Offline* in the GUI / `depot test` fails | `ServerUrl`, DNS from this VLAN, firewall TCP 8080 |
| Share not reachable | TCP 445 between VLANs; the client falls back to HTTP with `TransferMethod Auto` |
| `SHA-256 mismatch` | The file in the repository changed or was corrupted; run `depot server check <id> --force` |
| Install fails with 1603 | MSI log in the log folder (`<id>_<version>_<time>.msi.log`) |
| App shows *Available* although installed | Its `detection.display_name` does not match Programs and Features — adjust the manifest |
| Admin commands return 401 | Set the API key: `depot config set ApiKey <key>` |

Client log: `<LogPath>\AppDepot.log`. Add `-Verbose` (cmdlets) or `--verbose` (CLI) for detail.

## Running the tests

```powershell
Install-Module Pester -MinimumVersion 5.5 -Scope CurrentUser
Invoke-Pester ./client/tests -Output Detailed
```
