# Manifest reference

To add applications without writing YAML, see [adding-applications.md](adding-applications.md).

Each application is a YAML file in `manifests_dir`. Files are loaded on startup and with
`appdepot-server sync`; they can also be posted to `POST /api/v1/apps` as JSON.
Validate with `appdepot-server validate manifests/*.yaml`.

```yaml
id: Mozilla.Firefox                 # required: unique id (letters, digits, . _ + -)
name: Mozilla Firefox               # required: display name
publisher: Mozilla
description: Free and open-source web browser.
homepage: https://www.mozilla.org/firefox/
license: MPL-2.0
category: Browsers                  # used for grouping/filtering in clients
tags: [browser]
enabled: true                       # false = hidden and never checked
schedule: "45 */6 * * *"            # cron | manual | omitted = global schedule
retain_versions: 5                  # override the global retention (default 3)

source:                             # required: where to find new versions (see below)
  type: json
  ...
# or several sources - all are checked and the preferred installer (MSI) wins:
# sources:
#   - {type: web, ...}
#   - {type: winget, ...}

installer:                          # optional: overrides for silent install
  type: msi
  install_args: '/qn /norestart DESKTOP_SHORTCUT=false'
  uninstall_command: '"%ProgramFiles%\Mozilla Firefox\uninstall\helper.exe" /S'
  uninstall_args: '/S'
  architecture: x64
  scope: machine                    # machine | user
  upgrade_behavior: install         # install (in place) | uninstall_previous
  setup_file: setup.exe             # for .zip installers: the file to run inside the archive
  signer: Adobe                     # require a valid Authenticode signature from this signer (regex)
  update_with: Vendor.App.Update    # an application holding update patches (.msp) for this one
  requires: [Microsoft.VCRedist.2015+.x64]   # applications installed first when missing
  success_exit_codes: [0, 3010]     # added to 0, 1707, 3010, 1641
  preferred_types: [msi, wix, inno]  # override the server's installer preference for this app

detection:                          # how clients find the installed version
  display_name: '^Mozilla Firefox'  # regex on Programs and Features DisplayName
  publisher: '^Mozilla'             # optional regex on Publisher
  product_code: '{GUID}'            # optional, MSI product codes are added automatically
  key_pattern: '^\{AC76BA86-'      # optional regex on the uninstall registry key name
  exclude: 'Maintenance Service'    # optional regex: ignore entries whose name matches
  appx_name: MSTeams                # MSIX/AppX apps: the package name (instead of display_name)
```

## Installer preference (MSI first)

AppDepot prefers MSI installers. For every check:

1. **All sources** of the application are queried, and every source returns *all* installers it
   offers for its newest version (winget: every installer for the architecture; GitHub: every
   asset matching `asset_pattern`; web/json: every URL in `download_url` or matched by
   `url_regex`). A source that fails does not stop the others.
2. The **newest version** found by any source is selected.
3. For that version the installer type earliest in the preference list wins. The default list
   (`installers.preferred_types` in `appdepot.yaml`) is
   `msi, wix, msix, appx, burn, inno, nullsoft, exe`. Ties go to the source listed first.
4. If the download of the chosen installer fails (for example a guessed `.msi` URL returns 404),
   the next candidate is tried.
5. If a version is already stored as an EXE and an MSI of the **same version** becomes available,
   the stored EXE is replaced by the MSI on the next check.

The event log records the decision, e.g. `Selected MSI from web (source 1 of 2)` or
`No MSI available for version 8.7.1 from 1 source(s) (found: nullsoft); using nullsoft from winget`.
Preview it at any time with `Test-DepotAppSource` / `depot app test`.

A newer version always beats an older MSI: if source A has 2.0 as an EXE and source B only has
1.9 as an MSI, 2.0 is used.

## Sources

### `winget` — use the winget community repository

The easiest choice: winget manifests already contain URLs, SHA-256 hashes, installer types,
silent switches and MSI product codes.

```yaml
source:
  type: winget
  package: Microsoft.VisualStudioCode   # winget PackageIdentifier (winget search ...)
  architecture: x64                     # x64 (default) | x86 | arm64 | neutral
  installer_type: inno                  # optional: only consider these type(s), e.g. [wix, msi]
  scope: machine                        # preferred scope (default machine)
  locale: en-US                         # optional
  version_filter: '^\d+\.\d+\.\d+$'     # optional regex (e.g. to skip betas)
  strict_type: false                    # true = fail if the preferred type is missing
```

Installers for the requested architecture (or neutral) are offered; x86 is used for x64 only when
no x64 installer exists. Machine-scope installers are preferred over per-user ones. ZIP, portable
and Store packages are skipped. Leave `installer_type` out so the server can pick the MSI when
winget has one. Configure `sources.github_token` to avoid GitHub's
60-requests-per-hour limit.

### `github` — GitHub releases

```yaml
source:
  type: github
  repo: git-for-windows/git
  asset_pattern: '^Git-[\d.]+-64-bit\.exe$'   # regex on the asset file name; may match several
                                              # assets (e.g. '\.(msi|exe)$') - the MSI is preferred
  version_regex: '^v?(\d+\.\d+\.\d+)'          # optional, applied to the tag
  include_prerelease: false
```

### `web` — scrape a download page

```yaml
source:
  type: web
  url: https://www.chiark.greenend.org.uk/~sgtatham/putty/latest.html
  version_regex: 'latest release \((?P<version>[\d.]+)\)'   # highest match wins
  # Either build the URL from the version (a list of templates is allowed; the preferred
  # type that actually exists wins) ...
  download_url: https://the.earth.li/~sgtatham/putty/{version}/w64/putty-64bit-{version}-installer.msi
  # ... or extract it from the page (group 'url' or the first group; relative links allowed)
  # url_regex: 'href="(?P<url>[^"]+64bit-{version}-installer\.msi)"'
```

### `json` — JSON API

```yaml
source:
  type: json
  url: https://product-details.mozilla.org/1.0/firefox_versions.json
  version_path: LATEST_FIREFOX_VERSION          # dotted path, list indexes allowed: a.b[0].c
  download_url: https://download-installer.cdn.mozilla.net/pub/firefox/releases/{version}/win64/en-US/Firefox%20Setup%20{version}.msi
  # url_path: downloads.windows.url             # alternative: URL from the JSON
  # sha256_path: downloads.windows.sha256       # optional hash to verify
```

### `url` — a fixed "always latest" link

```yaml
source:
  type: url
  url: https://vendor.example.com/download/latest/agent-x64.msi
  version_from: msi          # msi | filename | redirect
  version_regex: '(\d+(?:\.\d+)+)'   # for filename / redirect
```

- `msi` downloads the file and reads `ProductVersion`. ETag/Last-Modified are remembered so
  an unchanged file is not downloaded again.
- `filename` / `redirect` take the version from the file name or the final redirected URL.

### `adobe` — Adobe Acrobat and Acrobat Reader (DC, Continuous track)

```yaml
source:
  type: adobe
  product: reader          # reader | acrobat
  package: update          # update (.msp patch) | installer (full installer)
  architecture: x64        # x64 | x86
  language: MUI            # Reader only: MUI (multi-language) | en_US
```

- **Version**: Adobe's Reader products service (`rdc.adobe.io`), falling back to the Acrobat
  release notes index on www.adobe.com.
- **Updates** (`package: update`): the cumulative `.msp` for the release from
  `ardownload3.adobe.com` / `ardownload2.adobe.com` (`AcroRdrDCx64Upd<v>_MUI.msp`,
  `AcrobatDCx64Upd<v>.msp`, ...). The products each patch applies to are read from the patch
  itself; clients only apply a patch to a product it targets.
- **Full installers** (`package: installer`): Reader's offline installer
  (`AcroRdrDCx64<v>_MUI.exe`) — when Adobe has not published one for an out-of-cycle release,
  the previous releases are used — and Acrobat Pro's installer zip from trials.adobe.com
  (`setup.exe` + `AcroPro.msi`, version read from the MSI).

AppDepot ships four ready-made manifests: `Adobe.Acrobat.Reader.64-bit` and
`Adobe.Acrobat.Pro.64-bit` (full installers, for new installs) and their `.Update` patch
applications. The full-installer applications name their patch application in
`installer.update_with`, so clients update existing installs with the small patch and bring a new
install up to date by applying the patch right after it. Patches are large (0.5-1 GB): the
manifests keep 2 versions.

### `manual` — installers you upload

```yaml
source:
  type: manual
```

The server never downloads anything for a manual application. Add versions by uploading files
(`Publish-DepotInstaller`, `depot app upload`, the GUI's *Upload installer* tab or
`appdepot-server app import`). See [adding-applications.md](adding-applications.md).
A manual source cannot be combined with other sources.

### Options shared by `web`, `json` and `url`

| Option | Sources | Purpose |
|---|---|---|
| `headers: {Name: value}` | all | Extra request headers |
| `browser: true` | all | Send browser-like headers (sites that block scripts) |
| `version_from: file` | web, json, url | No version on the page/API: the version is read from the downloaded file (MSI ProductVersion, MSIX manifest, EXE version resource). An unchanged link or ETag is not downloaded again |
| `strip_html: true` | web | Match `version_regex` against the page text without tags |
| `version_format: '{v}.{b}'` | web | Build the version from named (or `{g1}`, `{g2}`) groups, e.g. OpenVPN's `3.9.0 (5008)` → `3.9.0.5008` |
| `sha256_regex` | web | Find the SHA-256 on the page; `{version}` and `{filename}` placeholders, group `sha` |
| `text_path` + `url_regex` | json | Find links inside an HTML field of the JSON (e.g. a help-center article) |
| `sha256_path`, `sha512_path` | json | Hash to verify |
| `version_regex` (with `version_from: file`) | url | Search the MSI's property values and summary information instead of using ProductVersion (Chrome) |
| `version_api: {url, path}` | url | Fallback version from a JSON API |
| `version_from: fixed` + `version` | url | Final releases that never change (old VC++ runtimes) |
| `tag_regex` | github | Only releases whose tag matches: one application per product track |

JSON paths support filters and selection: `Releases[?Platform=Windows&Architecture=x64]`
keeps matching items, `[max:ProductVersion]` picks the item with the highest version, `[0]`
/ `[-1]` index.

### URL template variables

`{version}`, `{version_nodots}` (24.08 → 2408), `{version_underscore}`, `{version_dashes}`,
`{major}`, `{minor}`, `{patch}`, `{build}`, `{major_minor}`.

## Installer types and default silent switches

| `type` | Install | Uninstall (via registry) |
|---|---|---|
| `msi`, `wix` | `msiexec /i "file.msi" /qn /norestart` | `msiexec /x {ProductCode} /qn /norestart` |
| `nullsoft` (NSIS) | `"setup.exe" /S` | `UninstallString /S` |
| `inno` | `/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP- /ALLUSERS` | `/VERYSILENT /SUPPRESSMSGBOXES /NORESTART` |
| `burn` (WiX bundle) | `/quiet /norestart` | `/uninstall /quiet /norestart` |
| `msix`, `appx` | `Add-AppxProvisionedPackage` | `Remove-AppxProvisionedPackage` |
| `msp` (patch) | `msiexec /p "file.msp" /qn /norestart` | — (removed with the product) |
| `exe` | `install_args` **required** | `uninstall_command` recommended |

When `type` is omitted it is detected from the source (winget), the file extension or the file
itself. For a manifest with several candidates, `type` labels the generic `.exe` files
(e.g. `inno`); `.msi`/`.msix` files are always recognised by their extension.
`install_args` *replaces* the defaults (and switches published by winget). In
`uninstall_command` you can use `{product_code}`, `{version}` and `{filename}`.

Without an explicit uninstall command, non-MSI installers get a short PowerShell command that
finds the application in Programs and Features by `detection.display_name` and runs its
uninstaller silently — this works in Intune and in the client.

## Archives, signatures and patches

- **ZIP installers**: set `installer.setup_file` (a file name, found anywhere in the archive, or a
  relative path). The server extracts the archive, reads the version from an MSI next to the setup
  file when the source has none, and builds the Intune package from the folder that contains the
  setup file. Clients download the archive, extract it and run the setup file.
- **Signatures**: `installer.signer: Adobe` rejects files whose Authenticode signature is not valid
  or not from a matching signer, and tries the next candidate. The check uses Windows' own
  verification, so it runs on Windows servers; on Linux it is logged as "not verified".
- **Patches** (`.msp`) are installed only on computers that have the product. Use `update_with`
  on the product's application to link them.

## Detection

Clients decide whether an application is installed, and which version, from:

1. MSI product codes of every stored version (+ `detection.product_code`), matched against
   uninstall registry key names;
2. `detection.display_name` (regex) and optional `detection.publisher` (regex) against
   Programs and Features entries, optionally limited to registry keys matching
   `detection.key_pattern` (useful when products share a display name, like Adobe Acrobat and
   Reader 64-bit). When several match, the highest version wins.

If `display_name` is omitted it defaults to `^<name>`. Make the expression specific enough
not to match other products (e.g. `^Google Chrome$`, not `Chrome`).
