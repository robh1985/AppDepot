# PowerShell cmdlet reference

_Generated from the module's comment-based help. The same text is available with_ `Get-Help <cmdlet> -Full`.

| Cmdlet | Synopsis |
|---|---|
| [Get-DepotApp](#get-depotapp) | Lists the applications available in the AppDepot repository. |
| [Find-DepotApp](#find-depotapp) | Searches the AppDepot catalog. |
| [Get-DepotAppVersion](#get-depotappversion) | Lists the versions of an application stored in the repository. |
| [Get-DepotInstalledApp](#get-depotinstalledapp) | Lists catalog applications that are installed on this computer. |
| [Get-DepotUpdate](#get-depotupdate) | Lists installed applications that have a newer version in the repository. |
| [Install-DepotApp](#install-depotapp) | Installs an application from the AppDepot repository. |
| [Update-DepotApp](#update-depotapp) | Updates installed applications to the latest version in the repository. |
| [Uninstall-DepotApp](#uninstall-depotapp) | Silently uninstalls an application that was installed from the repository. |
| [Save-DepotInstaller](#save-depotinstaller) | Copies an installer (and optionally its Intune package) from the repository. |
| [Get-DepotServerStatus](#get-depotserverstatus) | Shows the status of the AppDepot server: version, schedules and per-application check results. |
| [Get-DepotEvent](#get-depotevent) | Reads the server event log (downloads, updates, purges, schedule changes, errors). |
| [Invoke-DepotServerCheck](#invoke-depotservercheck) | Asks the server to check the internet for new versions now. (Administrative) |
| [Set-DepotSchedule](#set-depotschedule) | Changes the global or a per-application update schedule on the server. (Administrative) |
| [Find-DepotWingetPackage](#find-depotwingetpackage) | Searches the winget catalog for applications to add to the repository. (Administrative) |
| [Test-DepotAppSource](#test-depotappsource) | Previews what the server would download for an application, without saving anything. |
| [New-DepotApp](#new-depotapp) | Adds a new application to the repository. (Administrative) |
| [Publish-DepotInstaller](#publish-depotinstaller) | Uploads an installer file to the repository as a new version of an application. (Administrative) |
| [Remove-DepotApp](#remove-depotapp) | Removes an application from the repository. (Administrative) |
| [Get-DepotManifestTemplate](#get-depotmanifesttemplate) | Returns a manifest template for writing an application definition by hand. |
| [Add-DepotCatalogApp](#add-depotcatalogapp) | Adds the applications that ship with AppDepot to the repository. (Administrative) |
| [Get-DepotConfig](#get-depotconfig) | Shows the AppDepot client configuration. |
| [Set-DepotConfig](#set-depotconfig) | Changes the AppDepot client configuration. |
| [Test-DepotConnection](#test-depotconnection) | Tests the connection to the AppDepot server and the repository share. |
| [Compare-DepotVersion](#compare-depotversion) | Compares two version strings the same way the AppDepot server does. |
| [Show-DepotGui](#show-depotgui) | Opens the AppDepot graphical client. |

## Get-DepotApp

Lists the applications available in the AppDepot repository.

```powershell
Get-DepotApp [-Id <String>] [-Name <String>] [-Category <String>] [-Detailed] [-IncludeEmpty]
```

### Description

```text
Returns the catalog of applications that have at least one version stored in the repository.
Filter by id/name wildcards or category. With -Id and an exact id, -Detailed adds the
source definition, next scheduled check and every stored version.
```

### Parameters

| Parameter | Type | Required | Pipeline | Description |
|---|---|---|---|---|
| `-Id` | String | false | true (ByPropertyName) | Application id, e.g. 7zip.7zip. Wildcards are supported. |
| `-Name` | String | false | false | Display-name filter. Wildcards are supported. |
| `-Category` | String | false | false | Only return applications in this category (e.g. Browsers, Utilities). |
| `-Detailed` | SwitchParameter | false | false | Include detailed information (versions, source, next check). Slower: one request per app. |
| `-IncludeEmpty` | SwitchParameter | false | false | Also list applications that have no version in the repository yet (for example manual applications before their first upload, or applications whose first check failed). |

### Examples

```powershell
Get-DepotApp

Id                          Name                Latest      Category
--                          ----                ------      --------
7zip.7zip                   7-Zip               24.08       Utilities
Google.Chrome               Google Chrome       130.0.6723  Browsers
```

```powershell
Get-DepotApp -Name *chrome*
```

```powershell
Get-DepotApp -Category Browsers | Install-DepotApp

Installs every application in the Browsers category.
```

**Output:** `AppDepot.App`

## Find-DepotApp

Searches the AppDepot catalog.

```powershell
Find-DepotApp -Query <String>
```

### Description

```text
Performs a server-side search of application ids, names, publishers and descriptions.
```

### Parameters

| Parameter | Type | Required | Pipeline | Description |
|---|---|---|---|---|
| `-Query` | String | true | false | Text to search for, e.g. 'browser' or 'adobe'. |

### Examples

```powershell
Find-DepotApp editor

Id                          Name                Latest   Category
--                          ----                ------   --------
Microsoft.VisualStudioCode  Visual Studio Code  1.94.2   Development
Notepad++.Notepad++         Notepad++           8.7      Development
```

**Output:** `AppDepot.App`

## Get-DepotAppVersion

Lists the versions of an application stored in the repository.

```powershell
Get-DepotAppVersion -Id <String> [-Version <String>] [-IncludePurged]
```

### Description

```text
The repository keeps the most recent versions of each application (3 by default). Each
version object includes the file locations (UNC and HTTP), SHA-256, silent install and
uninstall commands and the Intune package location.
```

### Parameters

| Parameter | Type | Required | Pipeline | Description |
|---|---|---|---|---|
| `-Id` | String | true | true (ByPropertyName) | Application id. |
| `-Version` | String | false | false | A specific version, or 'latest'. |
| `-IncludePurged` | SwitchParameter | false | false | Also list versions that were removed by the retention policy (history only). |

### Examples

```powershell
Get-DepotAppVersion 7zip.7zip

Version  Latest  Type      Size (MB)  Downloaded         Intune
-------  ------  ----      ---------  ----------         ------
24.08    True    exe            1.6   16/10/2026 03:00   ok
24.07    False   exe            1.6   20/06/2026 03:00   ok
```

```powershell
(Get-DepotAppVersion Google.Chrome -Version latest).InstallCommand
```

```powershell
Get-DepotAppVersion Mozilla.Firefox latest | Select-Object IntunePackage, IntuneInfo

Shows where the .intunewin file and the Intune deployment sheet are stored.
```

**Output:** `AppDepot.AppVersion`

## Get-DepotInstalledApp

Lists catalog applications that are installed on this computer.

```powershell
Get-DepotInstalledApp [-Id <String>]
```

### Description

```text
Reads Programs and Features (machine and current-user uninstall registry keys) and matches
entries to catalog applications using each application's detection rule (MSI product codes
or a display-name regular expression). Returns installed and latest versions and whether
an update is available. For applications updated with a patch (update_with, e.g. Adobe
Acrobat), the newest patch counts as the latest version and UpdateVia names the patch.
```

### Parameters

| Parameter | Type | Required | Pipeline | Description |
|---|---|---|---|---|
| `-Id` | String | false | false | Only return this application (wildcards supported). |

### Examples

```powershell
Get-DepotInstalledApp

Id                  Name       Installed  Latest  Update
--                  ----       ---------  ------  ------
7zip.7zip           7-Zip      24.07      24.08   True
Notepad++.Notepad++ Notepad++  8.7        8.7     False
```

**Output:** `AppDepot.InstalledApp`

## Get-DepotUpdate

Lists installed applications that have a newer version in the repository.

```powershell
Get-DepotUpdate [-Id <String>]
```

### Description

```text
Equivalent to Get-DepotInstalledApp | Where-Object UpdateAvailable.
```

### Parameters

| Parameter | Type | Required | Pipeline | Description |
|---|---|---|---|---|
| `-Id` | String | false | false | Only check this application (wildcards supported). |

### Examples

```powershell
Get-DepotUpdate
```

```powershell
Get-DepotUpdate | Update-DepotApp

Installs all available updates.
```

**Output:** `AppDepot.InstalledApp`

## Install-DepotApp

Installs an application from the AppDepot repository.

```powershell
Install-DepotApp -Id <String> [-Version <String>] [-Force] [-KeepInstaller] [-RetryCount <Int32>] [-NoPatch] [-WhatIf] [-Confirm]
```

### Description

```text
Fetches the installer from the repository (SMB share or HTTP), verifies its SHA-256 hash and
runs the silent install command stored in the database. Exit codes 0, 1707, 3010 and 1641
(plus any extra success codes defined for the application) are treated as success; 3010 and
1641 set RebootRequired. Exit code 1618 (another installation in progress) is retried.

If the same or a newer version is already installed the application is skipped unless
-Force is used. Machine-wide installers require an elevated session.

Archive installers (.zip, e.g. Adobe Acrobat) are extracted and their setup file is run.
Applications listed as requirements (installer.requires, e.g. the Visual C++ runtime) are
installed first when they are missing.

Update patches (.msp) are only applied when the product they update is installed. When an
application names an update patch (update_with), the newest patch is applied right after a
new install, so the computer ends up on the latest version.

Every action is logged to <LogPath>\AppDepot.log; MSI and MSP installs also write a verbose log.
```

### Parameters

| Parameter | Type | Required | Pipeline | Description |
|---|---|---|---|---|
| `-Id` | String | true | true (ByValue, ByPropertyName) | Application id. Accepts pipeline input from Get-DepotApp / Find-DepotApp. |
| `-Version` | String | false | true (ByPropertyName) | Version to install (default: latest). Must be one of the versions kept in the repository. |
| `-Force` | SwitchParameter | false | false | Install even if the same or a newer version is already installed. |
| `-KeepInstaller` | SwitchParameter | false | false | Keep the installer in the cache after a successful installation. |
| `-RetryCount` | Int32 | false | false | Number of retries when another installation is in progress (exit code 1618). Default 3. |
| `-NoPatch` | SwitchParameter | false | false | Do not apply the application's update patch after a new install (see update_with, used for Adobe Acrobat and Reader whose full installers can be older than the newest patch). |

### Examples

```powershell
Install-DepotApp 7zip.7zip
```

```powershell
Install-DepotApp Mozilla.Firefox -Version 131.0.2

Installs a specific (older) version that is still kept in the repository.
```

```powershell
Find-DepotApp browser | Install-DepotApp -WhatIf

Shows what would be installed without doing it.
```

```powershell
'Google.Chrome', '7zip.7zip', 'Notepad++.Notepad++' | Install-DepotApp
```

**Output:** `AppDepot.Result`

## Update-DepotApp

Updates installed applications to the latest version in the repository.

```powershell
Update-DepotApp -Id <String[]> [-KeepInstaller] [-WhatIf] [-Confirm]
Update-DepotApp -All [-KeepInstaller] [-WhatIf] [-Confirm]
```

### Description

```text
Compares installed versions with the repository and installs newer versions. Applications
whose upgrade behaviour is 'uninstall_previous' are removed before the new version is
installed; all others are upgraded in place.
```

### Parameters

| Parameter | Type | Required | Pipeline | Description |
|---|---|---|---|---|
| `-Id` | String[] | true | true (ByValue, ByPropertyName) | Application(s) to update. Accepts pipeline input from Get-DepotUpdate. |
| `-All` | SwitchParameter | true | false | Update every installed catalog application that has an update. |
| `-KeepInstaller` | SwitchParameter | false | false |  |

### Examples

```powershell
Update-DepotApp -All
```

```powershell
Update-DepotApp Google.Chrome
```

```powershell
Get-DepotUpdate | Where-Object Id -like 'Mozilla.*' | Update-DepotApp
```

```powershell
Update-DepotApp -All -WhatIf
```

**Output:** `AppDepot.Result`

## Uninstall-DepotApp

Silently uninstalls an application that was installed from the repository.

```powershell
Uninstall-DepotApp -Id <String> [-WhatIf] [-Confirm]
```

### Description

```text
Finds the application's Programs and Features entry using its detection rule and removes it:
  1. MSI products are removed with msiexec /x {ProductCode} /qn
  2. otherwise an uninstall command defined for the application on the server is used
  3. otherwise the entry's QuietUninstallString is used
  4. otherwise its UninstallString with the silent switches for the installer technology
```

### Parameters

| Parameter | Type | Required | Pipeline | Description |
|---|---|---|---|---|
| `-Id` | String | true | true (ByValue, ByPropertyName) | Application id. |

### Examples

```powershell
Uninstall-DepotApp VideoLAN.VLC
```

```powershell
Get-DepotInstalledApp -Id 'Mozilla.*' | Uninstall-DepotApp -WhatIf
```

**Output:** `AppDepot.Result`

## Save-DepotInstaller

Copies an installer (and optionally its Intune package) from the repository.

```powershell
Save-DepotInstaller -Id <String> [-Version <String>] [-Destination <String>] [-IncludeIntunePackage] [-TransferMethod <String>]
```

### Description

```text
Fetches the installer of an application version from the repository, using the SMB share
(UNC path) or HTTP depending on the TransferMethod setting, and verifies its SHA-256 hash.
Install-DepotApp uses this internally; you can also use it to stage installers or to collect
the .intunewin package and deployment notes for Intune.
```

### Parameters

| Parameter | Type | Required | Pipeline | Description |
|---|---|---|---|---|
| `-Id` | String | true | true (ByPropertyName) | Application id. |
| `-Version` | String | false | false | Version to fetch (default: latest). |
| `-Destination` | String | false | false | Target folder. Defaults to the client cache (<CachePath>\<Id>\<Version>). |
| `-IncludeIntunePackage` | SwitchParameter | false | false | Also copy the .intunewin package, the deployment sheet (.intune.txt) and the detection script. |
| `-TransferMethod` | String | false | false | Override the configured transfer method (Auto, Unc or Http). |

### Examples

```powershell
Save-DepotInstaller 7zip.7zip -Destination C:\Temp\7zip
```

```powershell
Save-DepotInstaller Google.Chrome -IncludeIntunePackage -Destination \\fileserver\intune\chrome
```

**Output:** `System.IO.FileInfo`

## Get-DepotServerStatus

Shows the status of the AppDepot server: version, schedules and per-application check results.

```powershell
Get-DepotServerStatus [-Id <String>]
```

### Description

```text
Combines the health, schedule and catalog endpoints into one overview. Use -Id to see the
status of one application, including its last error and next scheduled check.
```

### Parameters

| Parameter | Type | Required | Pipeline | Description |
|---|---|---|---|---|
| `-Id` | String | false | false | Show details for one application. |

### Examples

```powershell
Get-DepotServerStatus
```

```powershell
Get-DepotServerStatus -Id Google.Chrome | Format-List
```

## Get-DepotEvent

Reads the server event log (downloads, updates, purges, schedule changes, errors).

```powershell
Get-DepotEvent [-Id <String>] [-Level <String>] [-Last <Int32>]
```

### Parameters

| Parameter | Type | Required | Pipeline | Description |
|---|---|---|---|---|
| `-Id` | String | false | false | Only events for this application. |
| `-Level` | String | false | false | Only events of this level (info, error). |
| `-Last` | Int32 | false | false | Number of events to return (default 50, newest first). |

### Examples

```powershell
Get-DepotEvent -Level error
```

```powershell
Get-DepotEvent -Id Mozilla.Firefox -Last 10
```

## Invoke-DepotServerCheck

Asks the server to check the internet for new versions now. (Administrative)

```powershell
Invoke-DepotServerCheck [-Id <String[]>] [-Force] [-Wait] [-WhatIf] [-Confirm]
```

### Description

```text
Triggers an immediate update check outside the normal schedule. Without -Wait the check is
queued and runs in the background on the server; with -Wait (single application only) the
command returns the result. Requires the server API key (Set-DepotConfig -ApiKey).
```

### Parameters

| Parameter | Type | Required | Pipeline | Description |
|---|---|---|---|---|
| `-Id` | String[] | false | true (ByPropertyName) | Application(s) to check. Omit to check every enabled application. |
| `-Force` | SwitchParameter | false | false | Download again even if the version is already in the repository. |
| `-Wait` | SwitchParameter | false | false | Wait for the result (single application). |

### Examples

```powershell
Invoke-DepotServerCheck -Id Google.Chrome -Wait

app_id        status   version        message
------        ------   -------        -------
Google.Chrome updated  130.0.6723.92  Downloaded version 130.0.6723.92
```

```powershell
Invoke-DepotServerCheck
```

## Set-DepotSchedule

Changes the global or a per-application update schedule on the server. (Administrative)

```powershell
Set-DepotSchedule -Id <String> -Schedule <String> [-WhatIf] [-Confirm]
Set-DepotSchedule -Global -Schedule <String> [-WhatIf] [-Confirm]
```

### Description

```text
Schedules use 5-field cron syntax: minute hour day-of-month month day-of-week.
  '0 3 * * *'      every day at 03:00
  '0 */6 * * *'    every 6 hours
  '30 2 * * 1-5'   02:30 Monday to Friday
  '0 4 * * sun'    04:00 on Sundays
For an application, 'manual' disables automatic checks and 'global' (or an empty value)
returns it to the global schedule. Requires the server API key.
```

### Parameters

| Parameter | Type | Required | Pipeline | Description |
|---|---|---|---|---|
| `-Global` | SwitchParameter | true | false | Change the global schedule. |
| `-Id` | String | true | false | Change the schedule of this application. |
| `-Schedule` | String | true | false | Cron expression, 'manual' or 'global'. |

### Examples

```powershell
Set-DepotSchedule -Global -Schedule '0 2 * * *'
```

```powershell
Set-DepotSchedule -Id Google.Chrome -Schedule '0 */4 * * *'
```

```powershell
Set-DepotSchedule -Id Contoso.LegacyApp -Schedule manual
```

## Find-DepotWingetPackage

Searches the winget catalog for applications to add to the repository. (Administrative)

```powershell
Find-DepotWingetPackage -Query <String> [-Limit <Int32>]
```

### Description

```text
Searches winget package ids, names and monikers through the AppDepot server. Each result
shows whether the application is already in the repository. Add a result with
New-DepotApp -WingetId <Id>. Requires the server API key.
```

### Parameters

| Parameter | Type | Required | Pipeline | Description |
|---|---|---|---|---|
| `-Query` | String | true | false | Text to search for, e.g. 'chrome' or 'Adobe Acrobat'. |
| `-Limit` | Int32 | false | false | Maximum number of results (default 25). |

### Examples

```powershell
Find-DepotWingetPackage chrome

Id                   Name                 Version         InRepository
--                   ----                 -------         ------------
Google.Chrome        Google Chrome        130.0.6723.92   True
Google.Chrome.Beta   Google Chrome Beta   131.0.6778.24   False
```

```powershell
Find-DepotWingetPackage 'remote desktop' | Where-Object -Not InRepository
```

**Output:** `AppDepot.WingetPackage`

## Test-DepotAppSource

Previews what the server would download for an application, without saving anything.

```powershell
Test-DepotAppSource -WingetId <String> [-Category <String>] [-Architecture <String>]
Test-DepotAppSource -Path <String>
Test-DepotAppSource -Manifest <Hashtable>
Test-DepotAppSource -Id <String>
```

### Description

```text
Asks the server to query every source of an application and report the newest version,
every installer candidate, whether an MSI is available and which installer would be
selected (MSI is preferred over all other types). Nothing is saved or downloaded.

Use it before New-DepotApp, to check a manifest you are writing, or to see why an
existing application uses a particular installer. Requires the server API key.
```

### Parameters

| Parameter | Type | Required | Pipeline | Description |
|---|---|---|---|---|
| `-WingetId` | String | true | false | A winget package id; the manifest is generated from winget's metadata. |
| `-Path` | String | true | false | A manifest YAML file. |
| `-Manifest` | Hashtable | true | false | A manifest as a hashtable (same keys as the YAML file). |
| `-Id` | String | true | false | An application already in the repository. |
| `-Category` | String | false | false | Category to use for a generated winget manifest. |
| `-Architecture` | String | false | false | Architecture for a generated winget manifest (default x64). |

### Examples

```powershell
Test-DepotAppSource -WingetId Notepad++.Notepad++

Id            : Notepad++.Notepad++
LatestVersion : 8.7.1
Installer     : nullsoft
MsiAvailable  : False
Note          : No MSI available for version 8.7.1 from 1 source(s) (found: nullsoft); using nullsoft from winget (source 1 of 1)
```

```powershell
(Test-DepotAppSource -Path .\Contoso.App.yaml).Candidates | Format-Table
```

```powershell
Test-DepotAppSource -Id 7zip.7zip
```

**Output:** `AppDepot.SourcePreview`

## New-DepotApp

Adds a new application to the repository. (Administrative)

```powershell
New-DepotApp -WingetId <String> [-Category <String>] [-Architecture <String>] [-CheckNow] [-Replace] [-WhatIf] [-Confirm]
New-DepotApp -Path <String> [-CheckNow] [-Replace] [-WhatIf] [-Confirm]
New-DepotApp -Manifest <Hashtable> [-CheckNow] [-Replace] [-WhatIf] [-Confirm]
New-DepotApp -Id <String> -Name <String> [-Publisher <String>] [-Description <String>] [-Homepage <String>] [-InstallerType <String>] [-InstallArgs <String>] [-UninstallCommand <String>] [-SetupFile <String>] [-DetectionName <String>] [-InstallerPath <String>] [-Version <String>] [-Category <String>] [-CheckNow] [-Replace] [-WhatIf] [-Confirm]
```

### Description

```text
Adds an application in one of three ways:

  -WingetId   the server generates the manifest from the winget catalog (name, publisher,
              description, licence, homepage, category, detection rule)
  -Path       a manifest YAML file you wrote (see Get-DepotManifestTemplate)
  -Manifest   a hashtable with the same keys as a manifest file
  -Name       a manual application: you upload its installers (in-house or licensed
              software, or anything not available for download). Give -InstallerPath to
              upload the first version straight away; later versions are added with
              Publish-DepotInstaller.

The server previews the sources first; the result tells you which installer will be used
and whether an MSI is available (MSI is always preferred). The manifest is then saved in
the server's manifests folder and loaded into the database. Use -CheckNow to download the
application immediately instead of waiting for the next scheduled check.

Use -WhatIf to see the preview without adding anything. Requires the server API key.
```

### Parameters

| Parameter | Type | Required | Pipeline | Description |
|---|---|---|---|---|
| `-WingetId` | String | true | true (ByPropertyName) | winget package id, e.g. Notepad++.Notepad++ (find it with Find-DepotWingetPackage). |
| `-Path` | String | true | false | Manifest YAML file. |
| `-Manifest` | Hashtable | true | false | Manifest hashtable. |
| `-Id` | String | true | false | Id of a manual application, e.g. Contoso.Timesheets (letters, digits, . _ + -). |
| `-Name` | String | true | false | Display name of a manual application. |
| `-Publisher` | String | false | false | Publisher of a manual application. |
| `-Description` | String | false | false | Description of a manual application. |
| `-Homepage` | String | false | false | Information URL of a manual application. |
| `-InstallerType` | String | false | false | Installer technology of a manual application's files: msi, inno, nullsoft, burn, exe, msix, appx or msp. MSI, MSP and MSIX files are recognised automatically. |
| `-InstallArgs` | String | false | false | Silent install arguments (required for generic 'exe' installers; replaces the defaults). |
| `-UninstallCommand` | String | false | false | Silent uninstall command, e.g. '"%ProgramFiles%\Contoso\uninstall.exe" /S'. |
| `-SetupFile` | String | false | false | For .zip installers: the file inside the archive to run, e.g. setup.exe. |
| `-DetectionName` | String | false | false | Regular expression for the Programs and Features name (default: ^<Name>). |
| `-InstallerPath` | String | false | false | Installer file to upload as the first version of a manual application. |
| `-Version` | String | false | false | Version of -InstallerPath (read from MSI files when omitted). |
| `-Category` | String | false | false | Category for a winget application (default: guessed from its description and tags). |
| `-Architecture` | String | false | false | Architecture for a winget application (default x64). |
| `-CheckNow` | SwitchParameter | false | false | Download the application right away. |
| `-Replace` | SwitchParameter | false | false | Overwrite an application that already exists. |

### Examples

```powershell
New-DepotApp -WingetId Notepad++.Notepad++ -CheckNow
```

```powershell
Find-DepotWingetPackage putty | Select-Object -First 1 | New-DepotApp -Category Networking
```

```powershell
New-DepotApp -WingetId Adobe.Acrobat.Reader.64-bit -WhatIf

Shows the generated manifest and installer preview without adding the application.
```

```powershell
Get-DepotManifestTemplate web | Set-Content .\Contoso.App.yaml
notepad .\Contoso.App.yaml
Test-DepotAppSource -Path .\Contoso.App.yaml
New-DepotApp -Path .\Contoso.App.yaml -CheckNow
```

```powershell
New-DepotApp -Id Contoso.Timesheets -Name 'Contoso Timesheets' -Publisher Contoso -Category Business `
    -InstallerPath \\build01\drops\Timesheets-2.4.1.msi

Creates a manual application and uploads its first version (read from the MSI).
```

```powershell
New-DepotApp -Id Vendor.CadSuite -Name 'CAD Suite' -InstallerType exe -InstallArgs '/quiet /norestart' `
    -InstallerPath .\CadSuite_2025.1.exe -Version 2025.1
```

```powershell
New-DepotApp -Manifest @{
    id = 'Contoso.Agent'; name = 'Contoso Agent'; publisher = 'Contoso'; category = 'Security'
    source = @{ type = 'url'; url = 'https://contoso.example/agent/latest.msi'; version_from = 'msi' }
}
```

**Output:** `AppDepot.SourcePreview`

## Publish-DepotInstaller

Uploads an installer file to the repository as a new version of an application. (Administrative)

```powershell
Publish-DepotInstaller -Id <String> -Path <String> [-Version <String>] [-Replace] [-WhatIf] [-Confirm]
```

### Description

```text
Adds a version you supply yourself - for manual applications (in-house or licensed software
that cannot be downloaded), or to add a version the server cannot fetch. The file is
uploaded over HTTP and processed exactly like a download: silent install and uninstall
commands, Intune package, deployment sheet and detection script, database record and
version retention.

The version is read from MSI files automatically; for other files give -Version.
ZIP files are unpacked on the server using the application's setup_file setting.
Requires the server API key.
```

### Parameters

| Parameter | Type | Required | Pipeline | Description |
|---|---|---|---|---|
| `-Id` | String | true | false | Application id (create manual applications with New-DepotApp -Id ... -Name ...). |
| `-Path` | String | true | true (ByValue, ByPropertyName) | Installer file (.msi, .exe, .msp, .msix, .zip ...). |
| `-Version` | String | false | false | Version of the installer. Required unless the file is an MSI. |
| `-Replace` | SwitchParameter | false | false | Replace the version if it is already in the repository. |

### Examples

```powershell
Publish-DepotInstaller -Id Contoso.Timesheets -Path \\build01\drops\Timesheets-2.5.0.msi
```

```powershell
Publish-DepotInstaller -Id Vendor.CadSuite -Path .\CadSuite_2025.2.exe -Version 2025.2
```

```powershell
Get-ChildItem \\build01\drops\Timesheets-*.msi | Publish-DepotInstaller -Id Contoso.Timesheets

Uploads several versions; each version is read from its MSI. The repository keeps the newest ones.
```

**Output:** `AppDepot.Result`

## Remove-DepotApp

Removes an application from the repository. (Administrative)

```powershell
Remove-DepotApp -Id <String> [-DeleteFiles] [-WhatIf] [-Confirm]
```

### Description

```text
Removes the application from the database and stops checking it for updates. Its manifest
file on the server is renamed to *.removed (so it is not re-added and can be restored).
Stored installers are kept unless -DeleteFiles is used. Computers that already installed the
application are not affected. Requires the server API key.
```

### Parameters

| Parameter | Type | Required | Pipeline | Description |
|---|---|---|---|---|
| `-Id` | String | true | true (ByPropertyName) | Application id. |
| `-DeleteFiles` | SwitchParameter | false | false | Also delete every stored version (installers and Intune packages) from the repository. |

### Examples

```powershell
Remove-DepotApp Contoso.OldTool
```

```powershell
Remove-DepotApp Contoso.OldTool -DeleteFiles -Confirm:$false
```

## Get-DepotManifestTemplate

Returns a manifest template for writing an application definition by hand.

```powershell
Get-DepotManifestTemplate -Type <String>
```

### Description

```text
Templates exist for every source type: winget, github, web (scrape a download page), json
(vendor API), url (fixed "latest" link), multi (several sources; the MSI is preferred),
adobe (Acrobat / Reader installers and update patches) and manual (you upload the installers).
Save the template, edit it, check it with Test-DepotAppSource -Path and add it with
New-DepotApp -Path. See docs/manifest-reference.md for every option.
```

### Parameters

| Parameter | Type | Required | Pipeline | Description |
|---|---|---|---|---|
| `-Type` | String | true | false | winget, github, web, json, url or multi. |

### Examples

```powershell
Get-DepotManifestTemplate web | Set-Content .\Contoso.App.yaml
```

**Output:** `System.String`

## Add-DepotCatalogApp

Adds the applications that ship with AppDepot to the repository. (Administrative)

```powershell
Add-DepotCatalogApp [-Id <String[]>] [-Overwrite] [-CheckNow] [-WhatIf] [-Confirm]
```

### Description

```text
The AppDepot server includes a catalog of ready-made application manifests (the converted
sync scripts: 7-Zip, Chrome, Edge, Firefox, Adobe Acrobat/Reader, .NET, Visual C++, Java,
Python, Zoom and more; see docs/converted-sync-scripts.md). This copies them into the
server's manifests folder and loads them into the database.

New applications are added. Manifests that are already installed and identical are left
alone, manifests that differ (edited on the server, or from an older AppDepot release) are
kept unless -Overwrite is used, and applications removed with Remove-DepotApp are not added
back unless you name them with -Id.

The applications appear in Get-DepotApp and the GUI catalog once the server has downloaded
a version: use -CheckNow, Invoke-DepotServerCheck, or wait for the schedule.
Requires the server API key.
```

### Parameters

| Parameter | Type | Required | Pipeline | Description |
|---|---|---|---|---|
| `-Id` | String[] | false | true (ByValue, ByPropertyName) | Only these applications (default: the whole catalog). |
| `-Overwrite` | SwitchParameter | false | false | Replace installed manifests that differ from the bundled ones. The server keeps each old file as *.yaml.bak. |
| `-CheckNow` | SwitchParameter | false | false | Download the added applications now (in the background on the server). |

### Examples

```powershell
Add-DepotCatalogApp -WhatIf
Shows what would be added, kept or updated.
```

```powershell
Add-DepotCatalogApp -CheckNow
```

```powershell
Add-DepotCatalogApp -Id Google.Chrome, Microsoft.Edge, Mozilla.Firefox -CheckNow
```

## Get-DepotConfig

Shows the AppDepot client configuration.

```powershell
Get-DepotConfig 
```

### Description

```text
Returns the effective client configuration: values saved with Set-DepotConfig, overridden by
the APPDEPOT_SERVER and APPDEPOT_API_KEY environment variables, with defaults for the rest.
The configuration file is %ProgramData%\AppDepot\client.json.

The API key is masked in the output.
```

### Examples

```powershell
Get-DepotConfig

ServerUrl      : http://appdepot.corp.example.com:8080
TransferMethod : Auto
CachePath      : C:\ProgramData\AppDepot\Cache
...
```

**Output:** `AppDepot.Config`

## Set-DepotConfig

Changes the AppDepot client configuration.

```powershell
Set-DepotConfig [-ServerUrl <String>] [-TransferMethod <String>] [-CachePath <String>] [-LogPath <String>] [-TimeoutSec <Int32>] [-InstallTimeoutMinutes <Int32>] [-KeepInstallers <Boolean>] [-ApiKey <String>] [-Reset] [-WhatIf] [-Confirm]
```

### Description

```text
Saves settings to %ProgramData%\AppDepot\client.json (administrator rights are needed on
most systems). Only the parameters you specify are changed.
```

### Parameters

| Parameter | Type | Required | Pipeline | Description |
|---|---|---|---|---|
| `-ServerUrl` | String | false | false | URL of the AppDepot server, e.g. http://appdepot.corp.example.com:8080 |
| `-TransferMethod` | String | false | false | How installers are fetched from the repository: Auto - use the SMB share (UNC path) when reachable, otherwise HTTP (default) Unc - always copy from the SMB share Http - always download over HTTP |
| `-CachePath` | String | false | false | Folder where installers are staged before installation. |
| `-LogPath` | String | false | false | Folder for the client log (AppDepot.log) and MSI verbose logs. |
| `-TimeoutSec` | Int32 | false | false | Timeout for API requests. |
| `-InstallTimeoutMinutes` | Int32 | false | false | Maximum time an installer may run before it is terminated. |
| `-KeepInstallers` | Boolean | false | false | Keep installers in the cache after a successful installation. |
| `-ApiKey` | String | false | false | Server API key, required only for the administrative cmdlets (Invoke-DepotServerCheck, Set-DepotSchedule). It is stored in plain text in client.json; on shared machines prefer the APPDEPOT_API_KEY environment variable. |
| `-Reset` | SwitchParameter | false | false | Restore all defaults before applying the other parameters. |

### Examples

```powershell
Set-DepotConfig -ServerUrl http://appdepot.corp.example.com:8080
```

```powershell
Set-DepotConfig -TransferMethod Http -KeepInstallers $true
```

## Test-DepotConnection

Tests the connection to the AppDepot server and the repository share.

```powershell
Test-DepotConnection [-ServerUrl <String>] [-Quiet]
```

### Description

```text
Calls the server health endpoint and checks whether the repository UNC share is reachable
from this computer. Returns an object describing the result; use -Quiet to get $true/$false.
```

### Parameters

| Parameter | Type | Required | Pipeline | Description |
|---|---|---|---|---|
| `-ServerUrl` | String | false | false | Test a different server than the configured one. |
| `-Quiet` | SwitchParameter | false | false | Return only $true (server reachable) or $false. |

### Examples

```powershell
Test-DepotConnection

ServerUrl     : http://appdepot:8080
Reachable     : True
ServerVersion : 1.0.0
Applications  : 8
UncRoot       : \\appdepot\AppDepot
UncReachable  : True
```

```powershell
if (Test-DepotConnection -Quiet) { Update-DepotApp -All }
```

## Compare-DepotVersion

Compares two version strings the same way the AppDepot server does.

```powershell
Compare-DepotVersion -ReferenceVersion <String> -DifferenceVersion <String>
```

### Description

```text
Returns -1 if ReferenceVersion is older, 0 if equal and 1 if newer than DifferenceVersion.

The comparison tolerates real-world version formats that [version] cannot parse:
  * numbers compare numerically       24.08  -eq 24.8
  * trailing zeros are ignored        1.0    -eq 1.0.0
  * pre-release tags sort earlier     1.0-rc1 -lt 1.0
  * a leading 'v' is ignored          v3.1   -eq 3.1
```

### Parameters

| Parameter | Type | Required | Pipeline | Description |
|---|---|---|---|---|
| `-ReferenceVersion` | String | true | false | The version to compare. |
| `-DifferenceVersion` | String | true | false | The version to compare against. |

### Examples

```powershell
Compare-DepotVersion '1.10' '1.9'
1
```

```powershell
Compare-DepotVersion '24.08' '24.8.0'
0
```

**Output:** `System.Int32`

## Show-DepotGui

Opens the AppDepot graphical client.

```powershell
Show-DepotGui 
```

### Description

```text
A WPF application for browsing the repository and managing applications on this computer:

  Catalog    every application in the repository, with details, versions and install button
  Installed  catalog applications installed on this computer
  Updates    installed applications with a newer version available, with "Update all"
  Add apps   add applications (needs the API key): search winget; upload your own installer
             files (manual applications, new versions); or write a manifest for any
             source (vendor sites, GitHub, JSON APIs, Adobe) and test it before adding
  Activity   the server's event log and the operations performed in this session
  Settings   server URL, transfer method, cache options and API key

All server calls and installations run in the background so the window stays responsive.
Run it elevated (as administrator) to install machine-wide applications; the window offers
to restart itself elevated when needed.
```

### Examples

```powershell
Show-DepotGui
```

```powershell
depot gui

The same, from the command-line client.
```


