# Adding applications

There are several ways to add an application, all ending in the same place: a manifest file in the
server's `manifests` folder and a row in the database. Whichever you use, AppDepot first
**previews** the application, so you see before saving which version will be downloaded,
which installer will be used and whether an MSI is available.

| From | Best for |
|---|---|
| **GUI** — *Add apps* page | Point and click: search, preview, choose a category, add |
| **PowerShell** — `New-DepotApp` | Scripted onboarding of many applications |
| **CLI** — `depot app add` / `appdepot-server app add` | Quick additions from a console or on the server itself |
| **Manifest file** | Applications that are not in winget (vendor sites, GitHub, APIs, Adobe) |
| **Upload** (manual application) | Software that cannot be downloaded: in-house, licensed, or anything you have as a file |

Everything except editing files on the server needs the server **API key**
(GUI: *Settings → Server API key*; PowerShell/CLI: `depot config set ApiKey <key>` or
`$env:APPDEPOT_API_KEY`).

## 1. From the winget catalog (recommended)

winget lists thousands of applications with download URLs, hashes, installer types and silent
switches. AppDepot turns a winget package into a complete manifest — name, publisher,
description, licence, homepage, a category guess and a detection rule — and then checks it
against your installer preference.

### GUI

1. Open AppDepot and choose **Add apps**.
2. Search (`notepad`, `Mozilla.Firefox`, `remote desktop`…) and select a result.
3. The preview pane shows the latest version, the installer that will be used and a badge:
   - **green** — an MSI is available and will be used
   - **amber** — no MSI exists; the next preferred type is used (the reason is shown)
   - **red** — no usable installer was found
4. Adjust the **Category**, leave **Download it now** ticked, and click **Add to repository**.
   The application appears in the Catalog when the server has downloaded it.

### PowerShell

```powershell
Find-DepotWingetPackage notepad                       # search
Test-DepotAppSource -WingetId Notepad++.Notepad++     # preview, nothing saved
New-DepotApp -WingetId Notepad++.Notepad++ -Category Development -CheckNow

# several at once
'Mozilla.Firefox', 'VideoLAN.VLC', 'PuTTY.PuTTY' | ForEach-Object { New-DepotApp -WingetId $_ -CheckNow }

# see the generated manifest without adding anything
New-DepotApp -WingetId Adobe.Acrobat.Reader.64-bit -WhatIf
(Test-DepotAppSource -WingetId Adobe.Acrobat.Reader.64-bit).Manifest
```

### Command line

```bat
depot app search notepad
depot app test Notepad++.Notepad++
depot app add Notepad++.Notepad++ --category Development --check
```

On the server itself (no API key needed):

```bat
appdepot-server app search notepad
appdepot-server app add Notepad++.Notepad++ --category Development --check --yes
```

### How winget search works

The server downloads winget's package index (the same file the `winget` command uses,
`cdn.winget.microsoft.com/cache/source.msix`) and caches it for a day in
`<repository>\.cache\winget`. If that host is blocked by your proxy, search falls back to GitHub
code search, which needs `sources.github_token`. Adding a package by its **exact id** always works
as long as `api.github.com` and `raw.githubusercontent.com` are reachable.

## 2. From a manifest file (any source)

For applications that are not in winget, or when you want a vendor's own MSI, write a manifest.
Start from a template:

```powershell
Get-DepotManifestTemplate web | Set-Content .\Contoso.App.yaml     # winget github web json url multi
notepad .\Contoso.App.yaml
Test-DepotAppSource -Path .\Contoso.App.yaml                        # does it find the installer?
New-DepotApp -Path .\Contoso.App.yaml -CheckNow
```

```bat
depot app template web > Contoso.App.yaml
depot app test --file Contoso.App.yaml
depot app add --file Contoso.App.yaml --check
```

On the server you can also simply save the file in the `manifests` folder; it is loaded at the
next start or with `appdepot-server sync`. See [manifest-reference.md](manifest-reference.md)
for every option.

### Getting an MSI when winget only has an EXE

Many vendors publish an MSI on their website even when winget lists only an EXE. Give the
application **several sources**; all of them are checked and the MSI wins:

```yaml
id: 7zip.7zip
name: 7-Zip
sources:
  - type: web                       # vendor site: has the MSI
    url: https://www.7-zip.org/download.html
    version_regex: 'Download 7-Zip (?P<version>\d+\.\d+)'
    download_url: https://www.7-zip.org/a/7z{version_nodots}-x64.msi
  - type: winget                    # fallback: the EXE
    package: 7zip.7zip
detection:
  display_name: '^7-Zip'
```

## 3. Manual applications (upload your own installers)

For in-house software, licensed products, or anything the server cannot download, create a
**manual** application and upload its installer files. Each upload goes through the same
processing as a download: silent install/uninstall commands, Intune package, deployment sheet,
detection script, database record and version retention. Manual applications are never checked
for updates; you upload each new version.

The version is read from MSI files automatically. For other files give the version and the
installer type, so the correct silent switches are used (`inno`, `nullsoft`, `burn`, or `exe` with
your own `install_args`).

### GUI

*Add apps* → **Upload installer**:

- **New application**: id, name, publisher, category, installer type, optional silent arguments,
  uninstall command and detection name; choose the file and click **Create and upload**.
- **New version of an existing application**: pick the application, choose the file, enter the
  version (not needed for MSI files) and click **Upload new version**.

### PowerShell

```powershell
# create + first version (version read from the MSI)
New-DepotApp -Id Contoso.Timesheets -Name 'Contoso Timesheets' -Publisher Contoso -Category Business `
    -InstallerPath \\build01\drops\Timesheets-2.4.1.msi

# an EXE needs the version and its installer type (or silent arguments)
New-DepotApp -Id Vendor.CadSuite -Name 'CAD Suite' -InstallerType inno -InstallerPath .\CadSuite_2025.1.exe -Version 2025.1

# later versions
Publish-DepotInstaller -Id Vendor.CadSuite -Path .\CadSuite_2025.2.exe -Version 2025.2
Get-ChildItem \\build01\drops\Timesheets-*.msi | Publish-DepotInstaller -Id Contoso.Timesheets
```

### Command line

```bat
depot app create Contoso.Timesheets --name "Contoso Timesheets" --category Business --installer Timesheets-2.4.1.msi
depot app create Vendor.CadSuite --name "CAD Suite" --type inno
depot app upload Vendor.CadSuite CadSuite_2025.1.exe --version 2025.1
```

On the server (files on a local disk or share):

```bat
appdepot-server app create Vendor.CadSuite --name "CAD Suite" --type inno --installer D:\Drops\CadSuite_2025.1.exe --version 2025.1
appdepot-server app import Vendor.CadSuite D:\Drops\CadSuite_2025.2.exe --version 2025.2
```

ZIP files work too: set the setup file (`-SetupFile setup.exe`, `--setup-file setup.exe`) and the
server extracts it. You can also upload a version for a *non-manual* application, for example one
the server cannot reach.

## 4. Adobe Acrobat and Reader

Adobe is not served well by winget for enterprise deployment, so AppDepot has a built-in `adobe`
source (the method from the Adobe sync script: Adobe's products service and release notes,
`ardownload` patch files, the full Reader and Acrobat installers). Four manifests are included:

| Application | What it is |
|---|---|
| `Adobe.Acrobat.Reader.64-bit` | Full Reader installer (MUI) for new installs |
| `Adobe.Acrobat.Reader.64-bit.Update` | Reader cumulative update patch (.msp) |
| `Adobe.Acrobat.Pro.64-bit` | Acrobat Pro installer (zip, setup.exe) for new installs |
| `Adobe.Acrobat.Pro.64-bit.Update` | Acrobat Pro cumulative update patch (.msp) |

Clients update an installed Reader or Acrobat with the patch, and apply the patch straight after a
new install. Copy and adjust a manifest (`Get-DepotManifestTemplate adobe`) for 32-bit or en_US
packages. See [manifest-reference.md](manifest-reference.md#adobe--adobe-acrobat-and-acrobat-reader-dc-continuous-track).

## 5. Through the REST API

```powershell
$h = @{ 'X-Api-Key' = $key }
$gen = Invoke-RestMethod "$server/api/v1/winget/packages/Notepad++.Notepad++" -Headers $h
$gen.preview.note
Invoke-RestMethod "$server/api/v1/apps?check=true" -Method Post -Headers $h `
    -ContentType 'application/json' -Body ($gen.manifest | ConvertTo-Json -Depth 10)
```

Upload an installer (raw body):

```powershell
Invoke-RestMethod "$server/api/v1/apps/Vendor.CadSuite/versions?filename=CadSuite_2025.2.exe&version=2025.2" `
    -Method Post -Headers $h -InFile .\CadSuite_2025.2.exe -ContentType application/octet-stream
```

See [api.md](api.md) for all onboarding endpoints.

## Removing an application

```powershell
Remove-DepotApp Contoso.OldTool                 # stop tracking it; keep stored files
Remove-DepotApp Contoso.OldTool -DeleteFiles    # also delete installers and Intune packages
```

```bat
depot app remove Contoso.OldTool --delete-files
appdepot-server app remove Contoso.OldTool
```

The manifest file is renamed to `*.yaml.removed`, so a later sync does not add it back; rename it
to restore the application. Computers that installed it are not affected.

## After adding

- The application is checked on the global schedule (or its own `schedule:`).
  `-CheckNow` / `--check` downloads it immediately.
- `depot events --app <id>` shows which installer was chosen and why
  (`Selected MSI from …` or `No MSI available …; using … from …`).
- If an MSI becomes available later for a version you already have as an EXE, the next check
  replaces the EXE with the MSI automatically.
