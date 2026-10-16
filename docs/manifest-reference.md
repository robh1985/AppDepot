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
  success_exit_codes: [0, 3010]     # added to 0, 1707, 3010, 1641
  preferred_types: [msi, wix, inno]  # override the server's installer preference for this app

detection:                          # how clients find the installed version
  display_name: '^Mozilla Firefox'  # regex on Programs and Features DisplayName
  publisher: '^Mozilla'             # optional regex on Publisher
  product_code: '{GUID}'            # optional, MSI product codes are added automatically
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
| `exe` | `install_args` **required** | `uninstall_command` recommended |

When `type` is omitted it is detected from the source (winget), the file extension or the file
itself. For a manifest with several candidates, `type` labels the generic `.exe` files
(e.g. `inno`); `.msi`/`.msix` files are always recognised by their extension.
`install_args` *replaces* the defaults (and switches published by winget). In
`uninstall_command` you can use `{product_code}`, `{version}` and `{filename}`.

Without an explicit uninstall command, non-MSI installers get a short PowerShell command that
finds the application in Programs and Features by `detection.display_name` and runs its
uninstaller silently — this works in Intune and in the client.

## Detection

Clients decide whether an application is installed, and which version, from:

1. MSI product codes of every stored version (+ `detection.product_code`), matched against
   uninstall registry key names;
2. `detection.display_name` (regex) and optional `detection.publisher` (regex) against
   Programs and Features entries. When several match, the highest version wins.

If `display_name` is omitted it defaults to `^<name>`. Make the expression specific enough
not to match other products (e.g. `^Google Chrome$`, not `Chrome`).
