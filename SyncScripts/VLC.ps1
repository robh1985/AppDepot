<#
.SYNOPSIS
    SERVER SCRIPT - Keeps a network share stocked with the latest VLC media player MSI
    installers.

.DESCRIPTION
    - Finds the latest VLC release from VideoLAN's "last" download folder
      (https://download.videolan.org/pub/videolan/vlc/last/win64/), falling back to the
      list of version folders if needed.
    - If the share already has that version, it stops.
    - Otherwise it downloads vlc-<ver>-win64.msi / vlc-<ver>-win32.msi, checks each
      against the .sha256 file VideoLAN publishes next to it and against its
      Authenticode signature (VideoLAN), reads the MSI's ProductVersion, and publishes
      to a version folder.
    - Writes latest.json last, so clients never see a half-published version.
    - Keeps the newest -KeepVersions version folders.

    Folder layout:
        <DestinationPath>\3.0.24\vlc-3.0.24-win64.msi
        <DestinationPath>\3.0.24\vlc-3.0.24-win32.msi
        <DestinationPath>\latest.json
        <DestinationPath>\Logs\Sync-VLCRepo.log

    Must run on Windows (it reads the MSI version with the Windows Installer COM object).

.PARAMETER DestinationPath
    Folder (local path or UNC) where the installers are stored.
    Optional: if it's left out, the folder comes from the repo catalog
    (OTTOUpdate-Catalog.json): this app's Folder there (its full path), or
    <RepoRoot>\Applications\VLC if the app isn't in the catalog yet. The catalog is found
    automatically when this script runs from <RepoRoot>\Administrative\Sync;
    otherwise pass -CatalogPath.

.PARAMETER CatalogPath
    The repo catalog to take the folder from when -DestinationPath isn't given, e.g.
    \\fileserver\Software\OTTOUpdate-Catalog.json. Default: <RepoRoot>\OTTOUpdate-Catalog.json
    when this script is in <RepoRoot>\Administrative\Sync.

.PARAMETER Architectures
    Which builds to publish. Default: x64, x86. (VLC 3 has no ARM64 build; ARM64 PCs use x64.)

.PARAMETER Version
    Optional version (e.g. 3.0.24) to use instead of detecting the latest.

.PARAMETER KeepVersions
    How many version folders to keep. Default: 2.

.PARAMETER Proxy
    Proxy server for internet access, e.g. http://proxy.contoso.local:8080.

.PARAMETER ProxyUseDefaultCredentials
    Authenticate to the proxy as the account running the script.

.PARAMETER Force
    Download and republish even if the share already has this version.

.PARAMETER BuildIntunePackage
    After a successful sync, also build a Microsoft Intune Win32 app package from what is
    on the share: <IntuneOutputPath>\VLC\<version>\ gets VLC-<version>.intunewin,
    Detect-VLC.ps1 (custom detection script) and README-VLC.txt (the install/uninstall
    commands, return codes and detection settings to enter in Intune). Nothing is rebuilt
    if that version's package already exists (unless -Force). Needs <RepoRoot>\Administrative\Shared\OTTOUpdate-Common.ps1 and the app's client script (catalog ClientScript, normally Apps\VLC.ps1).

.PARAMETER IntuneOutputPath
    Where Intune packages are written. Default: <DestinationPath>\Intune

.PARAMETER ClientScriptPath
    Client script to put in the package. Default: the app's client script from the catalog (Apps\VLC.ps1 under <RepoRoot>\Administrative).

.PARAMETER IntuneWinAppUtilPath
    Path to IntuneWinAppUtil.exe (Microsoft Win32 Content Prep Tool). Default: the repo's
    shared copy, <RepoRoot>\Tools\IntuneWinAppUtil.exe (<RepoRoot> = the parent of
    -DestinationPath), which Update-IntuneWinAppUtil.ps1 downloads if it's missing.

.EXAMPLE
    .\Sync\VLC.ps1 -DestinationPath '\\fileserver\Software\Applications\VLC'

.EXAMPLE
    # Sync, then build the Intune package (.intunewin + detection script + README)
    .\Sync\VLC.ps1 -DestinationPath '\\fileserver\Software\Applications\VLC' -BuildIntunePackage
#>
[CmdletBinding()]
param(
    [string]$DestinationPath,

    [string]$CatalogPath,

    [ValidateSet('x64', 'x86')]
    [string[]]$Architectures = @('x64', 'x86'),

    [ValidatePattern('^\d+\.\d+\.\d+(\.\d+)?$')]
    [string]$Version,

    [ValidateRange(1, 20)]
    [int]$KeepVersions = 2,

    [string]$Proxy,

    [switch]$ProxyUseDefaultCredentials,

    [switch]$Force,

    # Intune Win32 package (see Shared\OTTOUpdate-Common.ps1)
    [switch]$BuildIntunePackage,
    [string]$IntuneOutputPath,
    [string]$ClientScriptPath,
    [string]$IntuneWinAppUtilPath
)
$script:SyncFailed = $false

# --- This app's definition -------------------------------------------------------------
# What OTTOUpdate needs to know about the app: its name, its scripts, and how Intune installs,
# detects and uninstalls it. It's copied into the repo catalog (OTTOUpdate-Catalog.json) the
# first time the app is synced (or by 'OTTOUpdate-Server.ps1 Register'); after that the
# catalog's copy is the one used, so change it there (e.g. with the catalog editor).
$OTTOAppDefinition = @{
    AppId        = 'VLC'
    Name         = 'VLC media player'
    SyncScript   = 'Sync\VLC.ps1'
    ClientScript = 'Apps\VLC.ps1'
    Intune       = @{
        # Install command arguments after the script name. '-SourcePath .' becomes the repo path
        # plus the package's own copy as the fallback.
        InstallCommand  = '-SourcePath . -Install'
        InstallVariants = @(
            '-SourcePath . -Install -ConvertToNativeArchitecture   (replace an installed copy of another architecture, e.g. 32-bit, with the build for this Windows)',
            '-SourcePath . -Install -CloseRunning'
        )
        # The app's Programs and Features entries (regular expressions), for detection logging and uninstall
        Match           = @{ Pattern = '^VLC media player'; Exclude = ''; KeyPattern = ''; Exe = '' }
        Detection       = @{
            # How it's detected, as written in Detect.log. Empty = the built-in check of the
            # Programs and Features entry (Match.Pattern) and, if newer, Match.Exe's file version
            Description     = ''
            # Several versions side by side, each compared with its own repo version ($Required)
            SeveralVersions = $false
            # What $Required is when the detection script's $Required line is left at $null
            DefaultRequired = '@()'
            # Runs before the repo is read; may Pass or Fail straight away
            PreCheck        = ''
            # Sets $have when the repo can't be read. Empty = the Programs and Features check
            Offline         = ''
            # The check: compares what's installed with $Manifest (the repo's latest.json) and
            # ends with Test-Current / Test-CurrentSet. Empty = the built-in check
            Code            = ''
        }
        Uninstall       = @{
            # Silent arguments for uninstallers that aren't MSI
            ExeArgs      = '/S'
            # A reason the app can't be uninstalled (the uninstall script then only logs it)
            NotSupported = ''
            # Runs instead of removing the matching Programs and Features entries
            Code         = ''
        }
    }
    Tasks        = @{}
}

# --- Where to sync: -DestinationPath, or this app's folder from the repo catalog ----------
if (-not $CatalogPath) {
    # This script in <RepoRoot>\Administrative\Sync -> <RepoRoot>\OTTOUpdate-Catalog.json
    $adminDir = Split-Path $PSScriptRoot -Parent
    if ((Split-Path $PSScriptRoot -Leaf) -eq 'Sync' -and (Split-Path $adminDir -Leaf) -eq 'Administrative') {
        $CatalogPath = Join-Path (Split-Path $adminDir -Parent) 'OTTOUpdate-Catalog.json'
    }
}
if (-not $DestinationPath) {
    if (-not $CatalogPath -or -not (Test-Path -LiteralPath $CatalogPath)) {
        Write-Host ("No -DestinationPath was given and no repo catalog was found" + $(if ($CatalogPath) { " at $CatalogPath" }) + ". " +
                    "Pass -DestinationPath <share>\VLC, or -CatalogPath <RepoRoot>\OTTOUpdate-Catalog.json " +
                    "(found automatically when this script runs from <RepoRoot>\Administrative\Sync).") -ForegroundColor Red
        exit 1
    }
    try { $catalogData = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $CatalogPath).ProviderPath) | ConvertFrom-Json }
    catch { Write-Host "The repo catalog $CatalogPath can't be read: $($_.Exception.Message). Pass -DestinationPath instead." -ForegroundColor Red; exit 1 }
    $catalogEntry = @($catalogData.Apps) | Where-Object { $_ -and [string]$_.AppId -eq 'VLC' } | Select-Object -First 1
    $catalogFolder = if ($catalogEntry -and $catalogEntry.Folder) { [string]$catalogEntry.Folder } else { 'Applications\VLC' }
    # Folder is the app's full path (e.g. \\fileserver\Software\Applications\Chrome); older catalogs hold a name under the repo root
    $DestinationPath = if ($catalogFolder -match '^\\\\' -or [IO.Path]::IsPathRooted($catalogFolder)) { $catalogFolder }
                       else { Join-Path (Split-Path (Resolve-Path -LiteralPath $CatalogPath).ProviderPath -Parent) $catalogFolder }
    Write-Host ("-DestinationPath from the repo catalog: $DestinationPath" + $(if (-not $catalogEntry) { " (VLC isn't in the catalog yet; it's added after this sync writes latest.json)" }))
}

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
try   { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13 }
catch { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 }

$BaseUrl       = 'https://download.videolan.org/pub/videolan/vlc'
$Platform      = @{ x64 = 'win64'; x86 = 'win32' }
$SignerPattern = 'VideoLAN'
$UserAgent     = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Sync-VLCRepo.ps1'

# Proxy for every web request in this script
if ($Proxy) {
    $PSDefaultParameterValues['Invoke-WebRequest:Proxy'] = $Proxy
    if ($ProxyUseDefaultCredentials) { $PSDefaultParameterValues['Invoke-WebRequest:ProxyUseDefaultCredentials'] = $true }
}
# VideoLAN's download server redirects to mirrors, some of which are plain http.
# PowerShell 7.4+ refuses https->http redirects unless told otherwise. That's safe here
# because every file is checked against VideoLAN's SHA-256 (fetched over https) and signature.
if ((Get-Command Invoke-WebRequest).Parameters.ContainsKey('AllowInsecureRedirect')) {
    $PSDefaultParameterValues['Invoke-WebRequest:AllowInsecureRedirect'] = $true
}

# --- Helpers -----------------------------------------------------------------
if (-not (Test-Path $DestinationPath)) { New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null }
$logDir = Join-Path $DestinationPath 'Logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$LogFile = Join-Path $logDir 'Sync-VLCRepo.log'

function Write-Log {
    param([string]$Message, [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    # Append to the log without ever failing the run: share the file with other
    # readers/writers and retry briefly if it's momentarily locked (e.g. antivirus).
    for ($try = 1; $try -le 10; $try++) {
        try {
            $fs = [IO.File]::Open($LogFile, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
            $sw = New-Object IO.StreamWriter($fs, (New-Object Text.UTF8Encoding($false)))
            try { $sw.WriteLine($line) } finally { $sw.Dispose() }
            break
        }
        catch { Start-Sleep -Milliseconds (100 * $try) }
    }
    switch ($Level) {
        'WARN'  { Write-Warning $Message }
        'ERROR' { Write-Host $line -ForegroundColor Red }
        default { Write-Host $line }
    }
}

function Get-ErrorDetail($ErrorRecord) {
    $msgs = @(); $e = $ErrorRecord.Exception
    while ($e) { $msgs += $e.Message; $e = $e.InnerException }
    return ($msgs | Select-Object -Unique) -join ' --> '
}

# --- Only one sync per share at a time -----------------------------------------
# Holds an exclusive lock file for the whole run; a second run exits quietly.
$script:SyncLock = $null
try {
    $script:SyncLock = [IO.File]::Open((Join-Path $logDir '.sync.lock'), [IO.FileMode]::OpenOrCreate,
                                       [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
}
catch {
    Write-Log 'Another run of this sync is already in progress for this share. Exiting.' 'WARN'
    exit 0
}

function ConvertTo-Version([string]$Text) {
    $m = [regex]::Match([string]$Text, '\d+(\.\d+){0,3}')
    if (-not $m.Success) { return $null }
    $parts = @($m.Value.Split('.')) + @('0', '0', '0', '0') | Select-Object -First 4
    return [version]($parts -join '.')
}

function Get-Page([string]$Url) {
    # Returns the response as text. PowerShell 7 hands back raw bytes when the server
    # labels a file as binary (VideoLAN's .sha256 files are), so decode those ourselves.
    $content = (Invoke-WebRequest -Uri $Url -UseBasicParsing -UserAgent $UserAgent).Content
    if ($content -is [byte[]]) { return [Text.Encoding]::UTF8.GetString($content) }
    return [string]$content
}

function Get-MsiProperty([string]$Path, [string]$Property) {
    $installer = New-Object -ComObject WindowsInstaller.Installer
    $db = $view = $rec = $null
    try {
        $db   = $installer.GetType().InvokeMember('OpenDatabase', 'InvokeMethod', $null, $installer, @($Path, 0))
        $view = $db.GetType().InvokeMember('OpenView', 'InvokeMethod', $null, $db, @("SELECT Value FROM Property WHERE Property='$Property'"))
        $view.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $view, $null) | Out-Null
        $rec  = $view.GetType().InvokeMember('Fetch', 'InvokeMethod', $null, $view, $null)
        $val  = if ($rec) { $rec.GetType().InvokeMember('StringData', 'GetProperty', $null, $rec, 1) } else { $null }
        $view.GetType().InvokeMember('Close', 'InvokeMethod', $null, $view, $null) | Out-Null
        return $val
    }
    finally {
        foreach ($o in @($rec, $view, $db, $installer)) {
            if ($o) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($o) }
        }
    }
}

function Get-LatestVlcVersion {
    # 1) The "last" folder always holds the current release
    try {
        $html = Get-Page "$BaseUrl/last/win64/"
        $m = [regex]::Match($html, 'vlc-(\d+\.\d+\.\d+(?:\.\d+)?)-win64\.msi')
        if ($m.Success) { return $m.Groups[1].Value }
        Write-Log 'No MSI found in the "last" folder listing.' 'WARN'
    }
    catch { Write-Log "Couldn't read the 'last' folder: $(Get-ErrorDetail $_)" 'WARN' }

    # 2) Fall back to the highest version folder that has a Windows MSI
    $html = Get-Page "$BaseUrl/"
    $versions = [regex]::Matches($html, 'href="(\d+\.\d+\.\d+(?:\.\d+)?)/"') |
        ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique |
        Sort-Object { ConvertTo-Version $_ } -Descending
    foreach ($v in $versions | Select-Object -First 5) {
        try {
            $listing = Get-Page "$BaseUrl/$v/win64/"
            if ($listing -match [regex]::Escape("vlc-$v-win64.msi")) { return $v }
        } catch { }
    }
    throw 'Could not determine the latest VLC version. Use -Version.'
}

# --- Main --------------------------------------------------------------------
$tempDir = Join-Path $env:TEMP "vlc-sync-$([guid]::NewGuid().ToString('N'))"
try {
    # latest.json as it was before this run, for the repo catalog (see the end of the script)
    $script:ManifestBefore = $null
    try {
        $manifestBeforePath = Join-Path $DestinationPath 'latest.json'
        if (Test-Path -LiteralPath $manifestBeforePath) { $script:ManifestBefore = Get-Content -LiteralPath $manifestBeforePath -Raw }
    }
    catch { }
    Write-Log "---- Sync started. Destination: $DestinationPath  Architectures: $($Architectures -join ', ')"
    New-Item -ItemType Directory -Path $tempDir | Out-Null

    $manifestPath = Join-Path $DestinationPath 'latest.json'
    $existing = $null
    if (Test-Path $manifestPath) {
        try { $existing = Get-Content $manifestPath -Raw | ConvertFrom-Json }
        catch { Write-Log "Existing manifest is unreadable and will be replaced: $_" 'WARN' }
    }
    Write-Log "Version on share: $(if ($existing) { $existing.Release } else { 'none' })"

    $release = if ($Version) { $Version } else { Get-LatestVlcVersion }
    Write-Log "Latest VLC release: $release"

    # --- Anything new? -------------------------------------------------------
    if ($existing -and -not $Force -and (ConvertTo-Version $existing.Release) -ge (ConvertTo-Version $release)) {
        $allPresent = $true
        foreach ($arch in $Architectures) {
            $e = $existing.Files.$arch
            if (-not $e -or -not (Test-Path -LiteralPath (Join-Path $DestinationPath $e.FileName))) { $allPresent = $false }
        }
        if ($allPresent) {
            Write-Log 'Share already has the latest release. Nothing to do.'
            exit 0
        }
    }

    # --- Download and verify -------------------------------------------------
    $found = @{}
    foreach ($arch in $Architectures) {
        $plat     = $Platform[$arch]
        $fileName = "vlc-$release-$plat.msi"
        $url      = "$BaseUrl/$release/$plat/$fileName"
        $local    = Join-Path $tempDir $fileName

        Write-Log "Downloading $url"
        try {
            # VideoLAN's published checksum ("<hash>  <file name>")
            $shaText  = Get-Page "$url.sha256"
            $expected = [regex]::Match($shaText, '\b([0-9a-fA-F]{64})\b').Groups[1].Value.ToUpper()
            if (-not $expected) {
                $preview = ($shaText -replace '\s+', ' ').Trim()
                if ($preview.Length -gt 150) { $preview = $preview.Substring(0, 150) + '...' }
                throw "Couldn't read the SHA-256 from $url.sha256 (got: '$preview')"
            }
            Invoke-WebRequest -Uri $url -OutFile $local -UseBasicParsing -UserAgent $UserAgent
        }
        catch {
            if ($arch -eq 'x86') { Write-Log "No 32-bit MSI for $release ($(Get-ErrorDetail $_)); skipping x86." 'WARN'; continue }
            throw
        }

        $hash = (Get-FileHash -LiteralPath $local -Algorithm SHA256).Hash
        if ($hash -ne $expected) { throw "SHA-256 mismatch for $fileName. VideoLAN lists $expected, got $hash." }

        $sig = Get-AuthenticodeSignature -FilePath $local
        if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch $SignerPattern) {
            throw "Signature check failed for $fileName (status: $($sig.Status), signer: $($sig.SignerCertificate.Subject))."
        }

        $productVersion = Get-MsiProperty $local 'ProductVersion'
        Write-Log "$arch : $fileName  ProductVersion $productVersion  SHA-256 OK  signed by $($sig.SignerCertificate.Subject)"
        $found[$arch] = @{ Path = $local; Name = $fileName; Hash = $hash; ProductVersion = $productVersion }
    }
    if ($found.Count -eq 0) { throw 'No installers were downloaded.' }

    $pv = @($found.Values | ForEach-Object { $_.ProductVersion } | Sort-Object -Unique)
    if ($pv.Count -gt 1) { throw "The builds report different ProductVersions: $($pv -join ', ')" }

    # --- Publish -------------------------------------------------------------
    $verFolder = Join-Path $DestinationPath $release
    $staging   = "$verFolder.partial"
    if (Test-Path $staging) { Remove-Item $staging -Recurse -Force }
    New-Item -ItemType Directory -Path $staging | Out-Null

    $files = [ordered]@{}
    foreach ($arch in $found.Keys) {
        Copy-Item -LiteralPath $found[$arch].Path -Destination (Join-Path $staging $found[$arch].Name)
        $files[$arch] = [ordered]@{ FileName = Join-Path $release $found[$arch].Name; Sha256 = $found[$arch].Hash }
    }
    if (Test-Path $verFolder) { Remove-Item $verFolder -Recurse -Force }
    Rename-Item -Path $staging -NewName $release

    $manifest = [ordered]@{
        Product   = 'VLC media player'
        Release   = $release        # e.g. 3.0.24 (used for folder/file names)
        Version   = $pv[0]          # MSI ProductVersion = what Programs and Features shows
        UpdatedAt = (Get-Date).ToString('o')
        Files     = $files
    }
    $tmp = "$manifestPath.tmp"
    $manifest | ConvertTo-Json -Depth 5 | Set-Content -Path $tmp -Encoding UTF8
    Move-Item -Path $tmp -Destination $manifestPath -Force
    Write-Log "Published VLC $release (ProductVersion $($pv[0])) and updated manifest."

    # --- Prune old versions --------------------------------------------------
    Get-ChildItem -Path $DestinationPath -Directory |
        Where-Object { $_.Name -match '^\d+(\.\d+){1,3}$' } |
        Sort-Object { [version]$_.Name } -Descending |
        Select-Object -Skip $KeepVersions |
        ForEach-Object {
            Write-Log "Removing old version folder $($_.Name)"
            Remove-Item $_.FullName -Recurse -Force
        }
    Get-ChildItem -Path $DestinationPath -Directory -Filter '*.partial' | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

    Write-Log '---- Sync finished successfully.'
    exit 0
}
catch {
    $script:SyncFailed = $true
    Write-Log "Sync failed: $(Get-ErrorDetail $_)" 'ERROR'
    exit 1
}
finally {
    Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    # --- Optional: Intune Win32 package (only after a successful sync) ------------
    if ($BuildIntunePackage -and -not $script:SyncFailed) {
        try {
            $intuneHelper = Join-Path (Split-Path $PSScriptRoot -Parent) 'Shared\OTTOUpdate-Common.ps1'
            if (-not (Test-Path -LiteralPath $intuneHelper)) { throw "OTTOUpdate-Common.ps1 was not found at $intuneHelper. Keep this script in <RepoRoot>\Administrative\Sync and the library in <RepoRoot>\Administrative\Shared." }
            . $intuneHelper
            Invoke-OTTOIntunePackageBuild -AppId 'VLC' -DestinationPath $DestinationPath -OutputPath $IntuneOutputPath `
                -ClientScriptPath $ClientScriptPath -IntuneWinAppUtilPath $IntuneWinAppUtilPath -Force:$Force -Log { param($m) Write-Log $m } `
                -Definition $OTTOAppDefinition -CatalogPath $CatalogPath
        }
        catch {
            Write-Log "Intune package build failed: $($_.Exception.Message)" 'ERROR'
            $script:IntuneFailed = $true
        }
    }
    # --- Record this run in the repo catalog (OTTOUpdate-Catalog.json) --------------------
    # Only when this script is run on its own; under OTTOUpdate-Server.ps1 Sync the server records it.
    $catalogHelper = Join-Path (Split-Path $PSScriptRoot -Parent) 'Shared\OTTOUpdate-Common.ps1'
    if (Test-Path -LiteralPath $catalogHelper) {
        try {
            . $catalogHelper
            Update-OTTOCatalogEntry -AppId 'VLC' -DestinationPath $DestinationPath -ManifestBefore $script:ManifestBefore `
                -Failed ([bool]($script:SyncFailed -or $script:IntuneFailed)) -Script 'Sync\VLC.ps1' `
                -BoundParameters $PSBoundParameters -CatalogPath $CatalogPath -Definition $OTTOAppDefinition -ScriptPath $PSCommandPath -Log { param($m, $l) Write-Log $m $l }
        }
        catch { Write-Log "Couldn't update the repo catalog: $($_.Exception.Message)" 'WARN' }
    }
    # Release the one-sync-per-share lock (it would otherwise stay held until this PowerShell
    # window closes, so a second run in the same window would think a sync is still running)
    if ($script:SyncLock) { $script:SyncLock.Dispose(); $script:SyncLock = $null }
    if ($script:IntuneFailed) { exit 1 }
}
