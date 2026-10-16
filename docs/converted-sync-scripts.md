# Converted sync scripts

Every script in `SyncScripts/` has been converted to AppDepot manifests in `server/manifests/`.
The scripts' methods (where versions come from, how files are verified, how they are installed
and detected) are kept; AppDepot's server then does the downloading, version history, Intune
packaging and database work that each script did on its own.

Applications whose versions install **side by side** (.NET channels, Python branches, Java
versions, Audacity 3 and 4, ODBC 17 and 18, Visual C++ families) become **one application per
track**, so each keeps its own version history and computers can have several.

| Script | Manifest(s) | Method |
|---|---|---|
| 7Zip.ps1 | `7zip.7zip` | GitHub releases (ip7z/7zip) MSI, SHA-256 from GitHub; 7-zip.org fallback |
| AdobeAcrobat.ps1 | `Adobe.Acrobat.Reader.64-bit`, `…Reader.64-bit.Update`, `Adobe.Acrobat.Pro.64-bit`, `…Pro.64-bit.Update` | Built-in `adobe` source: products service / release notes, `.msp` patches, full installers |
| AdobeCCDesktop.ps1 | `Adobe.CreativeCloud` | **Manual**: upload the Admin Console package zip (`setup.exe --silent`) |
| Audacity.ps1 | `Audacity.Audacity.4`, `Audacity.Audacity.3` | GitHub releases filtered per track (`tag_regex`); 4 = MSI, 3 = Inno EXE |
| Chrome.ps1 | `Google.Chrome` | Fixed enterprise MSI link (ETag); version from the MSI's texts, fallback Google version-history API (fully rolled-out Stable) |
| DotNetDesktopRuntime.ps1 | `Microsoft.DotNet.DesktopRuntime.8` / `.9` / `.10` | .NET release metadata JSON, SHA-512 |
| DuoWinLogon.ps1 | `Duo.DuoWinLogon` | Fixed "latest" zip (ETag), `DuoWindowsLogon64.msi` inside, version from the MSI; requires VC++ |
| Edge.ps1 | `Microsoft.Edge` | Edge Enterprise release feed (JSON filters), SHA-256 |
| Firefox.ps1 | `Mozilla.Firefox`, `Mozilla.Firefox.ESR` | product-details JSON + release archive MSI |
| MimecastOutlook.ps1 | `Mimecast.MimecastForOutlook` | Zendesk article JSON → "Mimecast for Outlook" 32-bit link; zip → MSI; re-downloaded only when the link changes |
| NotepadPlusPlus.ps1 | `Notepad++.Notepad++` | GitHub releases MSI (SHA-256); winget fallback |
| ODBCDriver.ps1 | `Microsoft.msodbcsql.18`, `Microsoft.msodbcsql.17` | fwlink from the docs page (GitHub source, then learn.microsoft.com); version from the MSI; 17 requires VC++ |
| OpenVPNConnect.ps1 | `OpenVPNTechnologies.OpenVPNConnect` | Release notes: version + build, SHA-256; winget fallback |
| PuTTY.ps1 | `PuTTY.PuTTY` | `latest/sha256sums` gives version and SHA-256; file from the release folder |
| Python.ps1 | `Python.Python.3.11` … `3.14` | winget packages per branch (python.org installers with SHA-256) |
| RingCentral.ps1 | `RingCentral.RingCentral` | Fixed MSI link (ETag), version from the MSI |
| Teams.ps1 | `Microsoft.Teams` | Fixed MSIX link (ETag), version from AppxManifest.xml, provisioned for all users |
| TemurinJRE.ps1 | `EclipseAdoptium.Temurin.8.JRE` … `.25.JRE` | Adoptium API per Java version, SHA-256 |
| Thunderbird.ps1 | `Mozilla.Thunderbird` | product-details JSON + release archive MSI |
| VCRedist.ps1 | `Microsoft.VCRedist.2015+.x64/x86/arm64`, `.2013/.2012/.2010/.2008/.2005` (x64, x86) | aka.ms links; v14 version from the EXE; older families are fixed final versions |
| VLC.ps1 | `VideoLAN.VLC` | "last" folder gives the version; MSI from the version folder |
| VMwareTools.ps1 | `VMware.VMwareTools` | Broadcom repository listing; `/S /v"/qn REBOOT=R ADDLOCAL=ALL"` |
| WatchGuardAuthClient.ps1 | `WatchGuard.WatchGuardAuthenticationClient` | winget catalog (WatchGuard's CDN link + SHA-256) |
| Zoom.ps1 | `Zoom.Zoom` | "latest" link's redirect gives the version |

Authenticode signer checks (`installer.signer`) carry over from each script; they run when the
AppDepot server is on Windows.

## Differences from the scripts

- **Architectures.** The scripts kept x64, x86 and ARM64 side by side in one folder. The
  manifests are 64-bit (the VC++ runtimes include x86 and ARM64). For another architecture copy
  a manifest, change `id`, the architecture in the source (or the URL), and the detection name.
- **Client switches.** Options of the client scripts such as `-CloseRunning`,
  `-ConvertToNativeArchitecture`, `-RemoveUserLevelChrome` or `-RemoveClassicTeams` have no
  equivalent. MSI properties from `-MsiProperties` go in `installer.install_args` (examples are
  commented in the manifests, e.g. Edge's `DONOTCREATEDESKTOPSHORTCUT=TRUE`).
- **Detection.** Detection uses Programs and Features (with the scripts' exclude patterns), MSI
  product codes, or the provisioned MSIX package (Teams), rather than program file versions.
- **Python** uses winget's per-branch packages instead of the python.org API; add or remove
  branch manifests as branches reach end of life.
- **WatchGuard** no longer probes the CDN for unannounced versions; upload a release that is not
  in winget yet with `Publish-DepotInstaller`.
- **Teams** is provisioned with `Add-AppxProvisionedPackage` (as teamsbootstrapper.exe does)
  and classic Teams is not removed.
- **Audacity**: moving a computer from 3 to 4 is "install Audacity 4, uninstall Audacity 3".
- **Duo**: updates keep the existing configuration; for new installs add your IKEY/SKEY/HOST to
  `install_args` (see the comment in the manifest).
- **Checksums**: the Firefox/Thunderbird `SHA256SUMS` and VLC `.sha256` files are not read;
  those files are verified by their Authenticode signature (Mozilla, VideoLAN).

The original scripts are kept in `SyncScripts/` for reference.
