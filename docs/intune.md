# Intune guide

For every version it downloads, the server writes three files next to the installer:

```
\\appdepot\AppDepot\Google.Chrome\130.0.6723.92\intune\
    Google.Chrome_130.0.6723.92.intunewin     package to upload
    Google.Chrome_130.0.6723.92.intune.txt    deployment sheet: everything to type into Intune
    Google.Chrome_130.0.6723.92.detect.ps1    custom detection script
```

## Creating the Win32 app

1. **Intune admin center → Apps → Windows → Add → Windows app (Win32)**.
2. Upload the `.intunewin` file.
3. Open the `.intune.txt` sheet and copy:
   - **App information**: name, publisher, description, information URL, category
   - **Program**: *Install command* and *Uninstall command* exactly as written, install behaviour
     (*System* for machine-wide installers), device restart behaviour
   - **Return codes**: 0, 1707 success · 3010 soft reboot · 1641 hard reboot · 1618 retry
     (these are Intune's defaults)
   - **Requirements**: architecture and minimum OS
4. **Detection rules** — the sheet lists the options for this installer:
   - **MSI** (MSI installers): product code with *version ≥* check
   - **Custom script**: upload the `.detect.ps1` file. It reports the app as installed when
     Programs and Features contains a matching entry with this version or newer, so it keeps
     working after the app updates itself.
   - **Registry**: manual alternative.
5. Assign and deploy.

You can collect the files from any computer with the client:

```powershell
Save-DepotInstaller Google.Chrome -IncludeIntunePackage -Destination C:\Intune\Chrome
depot download Google.Chrome --intune --dest C:\Intune\Chrome
```

or find them with `Get-DepotAppVersion Google.Chrome latest | Format-List Intune*`.

## Supersedence

When a new version arrives, create a new Win32 app from the new package and add the previous
app under **Supersedence** (*Uninstall previous version: No* for in-place upgraders such as
browsers; *Yes* for applications whose manifest sets `upgrade_behavior: uninstall_previous`).

## About the packager

The built-in packager writes the same format as Microsoft's *Win32 Content Prep Tool*:
a ZIP containing `IntuneWinPackage/Contents/IntunePackage.intunewin` (the source folder,
zipped, encrypted with AES-256-CBC and authenticated with HMAC-SHA256) and
`IntuneWinPackage/Metadata/Detection.xml` (keys, IV, MAC, SHA-256 digest, setup file and, for
MSIs, product code/version/upgrade code). Each package uses fresh random keys.
Verify any package with:

```bash
appdepot-server verify-package Google.Chrome_130.0.6723.92.intunewin
```

To use Microsoft's tool instead, set in `appdepot.yaml` (Windows servers only):

```yaml
intune:
  packager: official
  intunewinapputil_path: C:\Tools\IntuneWinAppUtil.exe
```

After changing an application's install arguments in its manifest, rebuild the package and
sheet for an existing version with `appdepot-server repackage <id> <version>`.
