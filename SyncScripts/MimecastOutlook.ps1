<#
.SYNOPSIS
    SERVER SCRIPT - Keeps a network share stocked with the latest
    "Mimecast for Outlook" MSI installer (32-bit by default).

.DESCRIPTION
    Mimecast has no version API, and its download links change with every release.
    So this script:
    - Reads Mimecast's public "Mimecast Application Downloads" support article
      (through the Zendesk Help Center API) and pulls out the current "32-bit" link
      from the "Mimecast for Outlook" row.
    - If that link is the same one used last time and the files are still on the
      share, it stops - nothing new.
    - Otherwise it downloads the zip, extracts the MSI, checks its Authenticode
      signature (must be valid and signed by Mimecast), reads the real version
      from the MSI, and - if it's newer than what's on the share - publishes it to a
      version folder and updates latest.json.
    - Keeps the newest -KeepVersions version folders and deletes older ones.

    Folder layout it produces:
        <DestinationPath>\7.10.1.133\Mimecast for outlook 7.10.1.133 (32 Bit).msi
        <DestinationPath>\latest.json
        <DestinationPath>\Logs\Sync-MimecastOutlookRepo.log

    If Mimecast changes the downloads page and the link can't be found, pass the
    link yourself with -DownloadUrl (copy it from the downloads page).

    Must run on Windows (it uses the Windows Installer COM object to read the MSI version).

.PARAMETER DestinationPath
    Folder (local path or UNC) where the installers are stored.
    Optional: if it's left out, the folder comes from the repo catalog
    (OTTOUpdate-Catalog.json): this app's Folder there (its full path), or
    <RepoRoot>\Applications\MimecastOutlook if the app isn't in the catalog yet. The catalog is found
    automatically when this script runs from <RepoRoot>\Administrative\Sync;
    otherwise pass -CatalogPath.

.PARAMETER CatalogPath
    The repo catalog to take the folder from when -DestinationPath isn't given, e.g.
    \\fileserver\Software\OTTOUpdate-Catalog.json. Default: <RepoRoot>\OTTOUpdate-Catalog.json
    when this script is in <RepoRoot>\Administrative\Sync.

.PARAMETER Architectures
    Which builds to publish: x86 (32-bit Outlook) and/or x64 (64-bit Outlook). Default: x86.

.PARAMETER DownloadUrl
    Optional. Use this download link for x86 instead of reading it from the downloads page.

.PARAMETER KeepVersions
    How many version folders to keep (current one included). Default: 2.

.PARAMETER AllowUnsigned
    Accept an MSI that isn't validly signed by Mimecast (not recommended).

.PARAMETER Force
    Download and republish even if nothing appears to have changed.

.PARAMETER BuildIntunePackage
    After a successful sync, also build a Microsoft Intune Win32 app package from what is
    on the share: <IntuneOutputPath>\MimecastOutlook\<version>\ gets MimecastOutlook-<version>.intunewin,
    Detect-MimecastOutlook.ps1 (custom detection script) and README-MimecastOutlook.txt (the install/uninstall
    commands, return codes and detection settings to enter in Intune). Nothing is rebuilt
    if that version's package already exists (unless -Force). Needs <RepoRoot>\Administrative\Shared\OTTOUpdate-Common.ps1 and the app's client script (catalog ClientScript, normally Apps\MimecastOutlook.ps1).

.PARAMETER IntuneOutputPath
    Where Intune packages are written. Default: <DestinationPath>\Intune

.PARAMETER ClientScriptPath
    Client script to put in the package. Default: the app's client script from the catalog (Apps\MimecastOutlook.ps1 under <RepoRoot>\Administrative).

.PARAMETER IntuneWinAppUtilPath
    Path to IntuneWinAppUtil.exe (Microsoft Win32 Content Prep Tool). Default: the repo's
    shared copy, <RepoRoot>\Tools\IntuneWinAppUtil.exe (<RepoRoot> = the parent of
    -DestinationPath), which Update-IntuneWinAppUtil.ps1 downloads if it's missing.

.EXAMPLE
    .\Sync\MimecastOutlook.ps1 -DestinationPath '\\fileserver\Software\Applications\MimecastOutlook'

.EXAMPLE
    # Sync, then build the Intune package (.intunewin + detection script + README)
    .\Sync\MimecastOutlook.ps1 -DestinationPath '\\fileserver\Software\Applications\MimecastOutlook' -BuildIntunePackage
#>
[CmdletBinding()]
param(
    [string]$DestinationPath,

    [string]$CatalogPath,

    [ValidateSet('x86', 'x64')]
    [string[]]$Architectures = @('x86'),

    [string]$DownloadUrl,

    [ValidateRange(1, 20)]
    [int]$KeepVersions = 2,

    [switch]$AllowUnsigned,

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
    AppId        = 'MimecastOutlook'
    Name         = 'Mimecast for Outlook'
    SyncScript   = 'Sync\MimecastOutlook.ps1'
    ClientScript = 'Apps\MimecastOutlook.ps1'
    Intune       = @{
        # Install command arguments after the script name. '-SourcePath .' becomes the repo path
        # plus the package's own copy as the fallback.
        InstallCommand  = '-SourcePath . -Install'
        InstallVariants = @(
            '-SourcePath . -Install -CloseOutlook   (closes Outlook without warning)'
        )
        # The app's Programs and Features entries (regular expressions), for detection logging and uninstall
        Match           = @{ Pattern = '^Mimecast for Outlook'; Exclude = ''; KeyPattern = ''; Exe = '' }
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
            ExeArgs      = ''
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
                    "Pass -DestinationPath <share>\MimecastOutlook, or -CatalogPath <RepoRoot>\OTTOUpdate-Catalog.json " +
                    "(found automatically when this script runs from <RepoRoot>\Administrative\Sync).") -ForegroundColor Red
        exit 1
    }
    try { $catalogData = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $CatalogPath).ProviderPath) | ConvertFrom-Json }
    catch { Write-Host "The repo catalog $CatalogPath can't be read: $($_.Exception.Message). Pass -DestinationPath instead." -ForegroundColor Red; exit 1 }
    $catalogEntry = @($catalogData.Apps) | Where-Object { $_ -and [string]$_.AppId -eq 'MimecastOutlook' } | Select-Object -First 1
    $catalogFolder = if ($catalogEntry -and $catalogEntry.Folder) { [string]$catalogEntry.Folder } else { 'Applications\MimecastOutlook' }
    # Folder is the app's full path (e.g. \\fileserver\Software\Applications\Chrome); older catalogs hold a name under the repo root
    $DestinationPath = if ($catalogFolder -match '^\\\\' -or [IO.Path]::IsPathRooted($catalogFolder)) { $catalogFolder }
                       else { Join-Path (Split-Path (Resolve-Path -LiteralPath $CatalogPath).ProviderPath -Parent) $catalogFolder }
    Write-Host ("-DestinationPath from the repo catalog: $DestinationPath" + $(if (-not $catalogEntry) { " (MimecastOutlook isn't in the catalog yet; it's added after this sync writes latest.json)" }))
}

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$ArticleApiUrl  = 'https://mimecastsupport.zendesk.com/api/v2/help_center/en-us/articles/36587212390291.json'
$LinkText       = @{ x86 = '32-bit'; x64 = '64-bit' }
$SignerPattern  = 'Mimecast'

# --- Helpers -----------------------------------------------------------------
if (-not (Test-Path $DestinationPath)) { New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null }
$logDir = Join-Path $DestinationPath 'Logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$LogFile = Join-Path $logDir 'Sync-MimecastOutlookRepo.log'

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

function Get-DownloadLinks {
    # Returns @{ x86 = 'https://...'; x64 = 'https://...' } from the Mimecast downloads article
    $article = Invoke-RestMethod -Uri $ArticleApiUrl -Headers @{ 'User-Agent' = 'Sync-MimecastOutlookRepo.ps1' }
    $body = [string]$article.article.body
    if (-not $body) { throw 'The Mimecast downloads article came back empty.' }

    # Isolate the table row for "Mimecast for Outlook" (heading text is exactly that)
    $rowMatch = [regex]::Match($body, '(?is)>\s*Mimecast for Outlook\s*</h\d>.*?</tr>')
    if (-not $rowMatch.Success) { throw 'Could not find the "Mimecast for Outlook" row on the downloads page. Use -DownloadUrl.' }
    $row = $rowMatch.Value

    $links = @{}
    foreach ($arch in $LinkText.Keys) {
        $pattern = '(?is)<a\s[^>]*href="([^"]+)"[^>]*>\s*' + [regex]::Escape($LinkText[$arch]) + '\s*</a>'
        $m = [regex]::Match($row, $pattern)
        if ($m.Success) { $links[$arch] = [Net.WebUtility]::HtmlDecode($m.Groups[1].Value) }
    }
    return $links
}

# --- Main --------------------------------------------------------------------
$tempDir = Join-Path $env:TEMP "mimecast-sync-$([guid]::NewGuid().ToString('N'))"
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
    $existingVersion = if ($existing) { ConvertTo-Version $existing.Version } else { $null }
    Write-Log "Version on share: $(if ($existingVersion) { $existingVersion } else { 'none' })"

    # --- Find the current download links ------------------------------------
    $links = @{}
    try { $links = Get-DownloadLinks }
    catch { if (-not $DownloadUrl) { throw } ; Write-Log "Couldn't read the downloads page ($($_.Exception.Message)); using -DownloadUrl." 'WARN' }
    if ($DownloadUrl) { $links['x86'] = $DownloadUrl }

    foreach ($arch in $Architectures) {
        if (-not $links[$arch]) { throw "No $($LinkText[$arch]) download link found for Mimecast for Outlook." }
        Write-Log "$arch download link: $($links[$arch])"
    }

    # --- Anything new? ------------------------------------------------------
    $unchanged = $existing -and -not $Force
    if ($unchanged) {
        foreach ($arch in $Architectures) {
            $e = $existing.Files.$arch
            if (-not $e -or $e.SourceUrl -ne $links[$arch] -or -not (Test-Path -LiteralPath (Join-Path $DestinationPath $e.FileName))) {
                $unchanged = $false
            }
        }
    }
    if ($unchanged) {
        Write-Log 'Download links are unchanged and files are present. Nothing to do.'
        exit 0
    }

    # --- Download, extract and check each build -----------------------------
    $found = @{}
    foreach ($arch in $Architectures) {
        $zip = Join-Path $tempDir "mimecast-$arch.zip"
        Write-Log "Downloading $arch package..."
        Invoke-WebRequest -Uri $links[$arch] -OutFile $zip -UseBasicParsing -UserAgent 'Mozilla/5.0'

        # Mimecast links usually serve a zip, but handle a bare MSI too
        $extract = Join-Path $tempDir "extract-$arch"
        New-Item -ItemType Directory -Path $extract | Out-Null
        $isZip = $false
        try {
            $bytes = [IO.File]::ReadAllBytes($zip)[0..1]
            $isZip = ($bytes[0] -eq 0x50 -and $bytes[1] -eq 0x4B)   # "PK"
        } catch { }
        if ($isZip) { Expand-Archive -Path $zip -DestinationPath $extract -Force }
        else        { Copy-Item $zip (Join-Path $extract "mimecast-$arch.msi") }

        $msis = @(Get-ChildItem -LiteralPath $extract -Recurse -File -Filter '*.msi')
        if ($msis.Count -eq 0) { throw "The $arch package contains no MSI (is the link still pointing at an installer?)." }
        $msi = if ($msis.Count -eq 1) { $msis[0] } else {
            $want = if ($arch -eq 'x86') { '32' } else { '64' }
            $msis | Where-Object { $_.Name -match $want } | Select-Object -First 1
        }
        if (-not $msi) { throw "Couldn't pick the $arch MSI from: $(($msis.Name) -join ', ')" }

        $sig = Get-AuthenticodeSignature -FilePath $msi.FullName
        $signedOk = $sig.Status -eq 'Valid' -and $sig.SignerCertificate.Subject -match $SignerPattern
        if (-not $signedOk) {
            $detail = "status: $($sig.Status), signer: $($sig.SignerCertificate.Subject)"
            if ($AllowUnsigned) { Write-Log "MSI signature check failed ($detail); accepting because -AllowUnsigned was used." 'WARN' }
            else { throw "MSI signature check failed for $($msi.Name) ($detail)." }
        }

        $productName = Get-MsiProperty $msi.FullName 'ProductName'
        $version     = ConvertTo-Version (Get-MsiProperty $msi.FullName 'ProductVersion')
        if ($productName -notmatch 'Mimecast') { throw "Unexpected MSI product name '$productName'." }
        Write-Log "$arch MSI: $($msi.Name)  Product: $productName  Version: $version  Signed: $signedOk"

        $found[$arch] = @{ Msi = $msi; Version = $version; Signed = $signedOk; ProductName = $productName }
    }

    $versions = @($found.Values | ForEach-Object { $_.Version } | Sort-Object -Unique)
    if ($versions.Count -gt 1) { throw "The builds report different versions: $($versions -join ', ')" }
    $pkgVersion = $versions[0]

    if ($existingVersion -and $pkgVersion -lt $existingVersion -and -not $Force) {
        throw "Downloaded version $pkgVersion is OLDER than the share's $existingVersion. Not publishing."
    }

    # --- Publish to a version folder -----------------------------------------
    $verName   = $pkgVersion.ToString()
    $verFolder = Join-Path $DestinationPath $verName
    $staging   = "$verFolder.partial"
    if (Test-Path $staging) { Remove-Item $staging -Recurse -Force }
    New-Item -ItemType Directory -Path $staging | Out-Null

    $files = [ordered]@{}
    foreach ($arch in $found.Keys) {
        $msi = $found[$arch].Msi
        Copy-Item -LiteralPath $msi.FullName -Destination (Join-Path $staging $msi.Name)
        $files[$arch] = [ordered]@{
            FileName    = Join-Path $verName $msi.Name
            Sha256      = (Get-FileHash -LiteralPath $msi.FullName -Algorithm SHA256).Hash
            Signed      = $found[$arch].Signed
            ProductName = $found[$arch].ProductName
            SourceUrl   = $links[$arch]
        }
    }
    if (Test-Path $verFolder) { Remove-Item $verFolder -Recurse -Force }
    Rename-Item -Path $staging -NewName $verName
    Write-Log "Published Mimecast for Outlook $pkgVersion to $verFolder"

    # --- Manifest (written last) ---------------------------------------------
    $manifest = [ordered]@{
        Product   = 'Mimecast for Outlook'
        Version   = $verName
        UpdatedAt = (Get-Date).ToString('o')
        Files     = $files
    }
    $tmp = "$manifestPath.tmp"
    $manifest | ConvertTo-Json -Depth 5 | Set-Content -Path $tmp -Encoding UTF8
    Move-Item -Path $tmp -Destination $manifestPath -Force
    Write-Log "Manifest written: version $verName ($($files.Keys -join ', '))"

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
    Write-Log "Sync failed: $($_.Exception.Message)" 'ERROR'
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
            Invoke-OTTOIntunePackageBuild -AppId 'MimecastOutlook' -DestinationPath $DestinationPath -OutputPath $IntuneOutputPath `
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
            Update-OTTOCatalogEntry -AppId 'MimecastOutlook' -DestinationPath $DestinationPath -ManifestBefore $script:ManifestBefore `
                -Failed ([bool]($script:SyncFailed -or $script:IntuneFailed)) -Script 'Sync\MimecastOutlook.ps1' `
                -BoundParameters $PSBoundParameters -CatalogPath $CatalogPath -Definition $OTTOAppDefinition -ScriptPath $PSCommandPath -Log { param($m, $l) Write-Log $m $l }
        }
        catch { Write-Log "Couldn't update the repo catalog: $($_.Exception.Message)" 'WARN' }
    }
    # Release the one-sync-per-share lock (it would otherwise stay held until this PowerShell
    # window closes, so a second run in the same window would think a sync is still running)
    if ($script:SyncLock) { $script:SyncLock.Dispose(); $script:SyncLock = $null }
    if ($script:IntuneFailed) { exit 1 }
}
