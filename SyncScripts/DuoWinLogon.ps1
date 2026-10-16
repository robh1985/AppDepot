<#
.SYNOPSIS
    SERVER SCRIPT - Keeps a network share stocked with the latest
    "Duo Authentication for Windows Logon" MSI installers.

.DESCRIPTION
    Duo has no version API, so this script:
    - Sends a HEAD request for Duo's MSI package
      (https://dl.duosecurity.com/DuoWinLogon_MSIs_Policies_and_Documentation-latest.zip)
      and skips the download if the file hasn't changed since the last run.
    - Otherwise downloads and extracts the zip, reads the real version from the MSI,
      checks each MSI's Authenticode signature (must be valid and signed by Duo/Cisco),
      and - if it's newer than what's on the share - publishes it to a version folder.
    - Also keeps the Microsoft Visual C++ Redistributable on the share, because the
      Duo MSIs (unlike Duo's EXE installer) need it installed first.
    - Writes a latest.json manifest last, so clients never see a half-published version.
    - Keeps the newest -KeepVersions version folders and deletes older ones.

    Duo says not to rename its MSI files, so each version gets its own folder:
        <DestinationPath>\6.0.0\DuoWindowsLogon64.msi   (plus the zip's policy templates/docs)
        <DestinationPath>\VCRedist\vc_redist.x64.exe
        <DestinationPath>\latest.json
        <DestinationPath>\Logs\Sync-DuoWinLogonRepo.log

    Must run on Windows (it uses the Windows Installer COM object to read the MSI version).
    Does NOT need your Duo keys - those are only used by the client script for new installs.

.PARAMETER DestinationPath
    Folder (local path or UNC) where the installers are stored.
    Optional: if it's left out, the folder comes from the repo catalog
    (OTTOUpdate-Catalog.json): this app's Folder there (its full path), or
    <RepoRoot>\Applications\DuoWinLogon if the app isn't in the catalog yet. The catalog is found
    automatically when this script runs from <RepoRoot>\Administrative\Sync;
    otherwise pass -CatalogPath.

.PARAMETER CatalogPath
    The repo catalog to take the folder from when -DestinationPath isn't given, e.g.
    \\fileserver\Software\OTTOUpdate-Catalog.json. Default: <RepoRoot>\OTTOUpdate-Catalog.json
    when this script is in <RepoRoot>\Administrative\Sync.

.PARAMETER Architectures
    Which MSI builds to publish. Default: x64, arm64.

.PARAMETER KeepVersions
    How many Duo version folders to keep (current one included). Default: 2.

.PARAMETER Force
    Download and republish even if nothing appears to have changed.

.PARAMETER BuildIntunePackage
    After a successful sync, also build a Microsoft Intune Win32 app package from what is
    on the share: <IntuneOutputPath>\DuoWinLogon\<version>\ gets DuoWinLogon-<version>.intunewin,
    Detect-DuoWinLogon.ps1 (custom detection script) and README-DuoWinLogon.txt (the install/uninstall
    commands, return codes and detection settings to enter in Intune). Nothing is rebuilt
    if that version's package already exists (unless -Force). Needs <RepoRoot>\Administrative\Shared\OTTOUpdate-Common.ps1 and the app's client script (catalog ClientScript, normally Apps\DuoWinLogon.ps1).

.PARAMETER IntuneOutputPath
    Where Intune packages are written. Default: <DestinationPath>\Intune

.PARAMETER ClientScriptPath
    Client script to put in the package. Default: the app's client script from the catalog (Apps\DuoWinLogon.ps1 under <RepoRoot>\Administrative).

.PARAMETER IntuneWinAppUtilPath
    Path to IntuneWinAppUtil.exe (Microsoft Win32 Content Prep Tool). Default: the repo's
    shared copy, <RepoRoot>\Tools\IntuneWinAppUtil.exe (<RepoRoot> = the parent of
    -DestinationPath), which Update-IntuneWinAppUtil.ps1 downloads if it's missing.

.EXAMPLE
    .\Sync\DuoWinLogon.ps1 -DestinationPath '\\fileserver\Software\Applications\DuoWinLogon'

.EXAMPLE
    # Sync, then build the Intune package (.intunewin + detection script + README)
    .\Sync\DuoWinLogon.ps1 -DestinationPath '\\fileserver\Software\Applications\DuoWinLogon' -BuildIntunePackage
#>
[CmdletBinding()]
param(
    [string]$DestinationPath,

    [string]$CatalogPath,

    [ValidateSet('x64', 'arm64', 'x86')]
    [string[]]$Architectures = @('x64', 'arm64'),

    [ValidateRange(1, 20)]
    [int]$KeepVersions = 2,

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
    AppId        = 'DuoWinLogon'
    Name         = 'Duo Authentication for Windows Logon'
    SyncScript   = 'Sync\DuoWinLogon.ps1'
    ClientScript = 'Apps\DuoWinLogon.ps1'
    Intune       = @{
        # Install command arguments after the script name. '-SourcePath .' becomes the repo path
        # plus the package's own copy as the fallback.
        InstallCommand  = '-SourcePath . -Install -IntegrationKey <IKEY> -SecretKey <SKEY> -ApiHost <api-xxxx.duosecurity.com>'
        InstallVariants = @(
            '-SourcePath .   (update existing installs only; no keys needed)'
        )
        # The app's Programs and Features entries (regular expressions), for detection logging and uninstall
        Match           = @{ Pattern = '^Duo Authentication for Windows Logon'; Exclude = ''; KeyPattern = ''; Exe = '' }
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
                    "Pass -DestinationPath <share>\DuoWinLogon, or -CatalogPath <RepoRoot>\OTTOUpdate-Catalog.json " +
                    "(found automatically when this script runs from <RepoRoot>\Administrative\Sync).") -ForegroundColor Red
        exit 1
    }
    try { $catalogData = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $CatalogPath).ProviderPath) | ConvertFrom-Json }
    catch { Write-Host "The repo catalog $CatalogPath can't be read: $($_.Exception.Message). Pass -DestinationPath instead." -ForegroundColor Red; exit 1 }
    $catalogEntry = @($catalogData.Apps) | Where-Object { $_ -and [string]$_.AppId -eq 'DuoWinLogon' } | Select-Object -First 1
    $catalogFolder = if ($catalogEntry -and $catalogEntry.Folder) { [string]$catalogEntry.Folder } else { 'Applications\DuoWinLogon' }
    # Folder is the app's full path (e.g. \\fileserver\Software\Applications\Chrome); older catalogs hold a name under the repo root
    $DestinationPath = if ($catalogFolder -match '^\\\\' -or [IO.Path]::IsPathRooted($catalogFolder)) { $catalogFolder }
                       else { Join-Path (Split-Path (Resolve-Path -LiteralPath $CatalogPath).ProviderPath -Parent) $catalogFolder }
    Write-Host ("-DestinationPath from the repo catalog: $DestinationPath" + $(if (-not $catalogEntry) { " (DuoWinLogon isn't in the catalog yet; it's added after this sync writes latest.json)" }))
}

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$DuoZipUrl = 'https://dl.duosecurity.com/DuoWinLogon_MSIs_Policies_and_Documentation-latest.zip'
$MsiNames  = @{ x64 = 'DuoWindowsLogon64.msi'; arm64 = 'DuoWindowsLogonARM64.msi'; x86 = 'DuoWindowsLogon32.msi' }
$VcUrls    = @{
    x64   = 'https://aka.ms/vs/17/release/vc_redist.x64.exe'
    arm64 = 'https://aka.ms/vs/17/release/vc_redist.arm64.exe'
    x86   = 'https://aka.ms/vs/17/release/vc_redist.x86.exe'
}
$DuoSignerPattern = 'Duo Security|Cisco'
$MsSignerPattern  = 'O=Microsoft Corporation'

# --- Helpers -----------------------------------------------------------------
if (-not (Test-Path $DestinationPath)) { New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null }
$logDir = Join-Path $DestinationPath 'Logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$LogFile = Join-Path $logDir 'Sync-DuoWinLogonRepo.log'

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

function Get-RemoteStamp([string]$Url) {
    # A fingerprint of the remote file (ETag / Last-Modified / size) so unchanged files aren't re-downloaded.
    try {
        $r = Invoke-WebRequest -Uri $Url -Method Head -UseBasicParsing
        $h = $r.Headers
        return '{0}|{1}|{2}' -f $h['ETag'], $h['Last-Modified'], $h['Content-Length']
    }
    catch {
        Write-Log "HEAD request failed for $Url ($($_.Exception.Message)); will download to check." 'WARN'
        return $null
    }
}

function Get-MsiProperty([string]$Path, [string]$Property) {
    $installer = New-Object -ComObject WindowsInstaller.Installer
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

function Assert-Signature([string]$Path, [string]$SignerPattern) {
    $sig = Get-AuthenticodeSignature -FilePath $Path
    if ($sig.Status -ne 'Valid') { throw "Signature on $(Split-Path $Path -Leaf) is not valid (status: $($sig.Status))." }
    if ($sig.SignerCertificate.Subject -notmatch $SignerPattern) {
        throw "Unexpected signer on $(Split-Path $Path -Leaf): $($sig.SignerCertificate.Subject)"
    }
    return $sig.SignerCertificate.Subject
}

# --- Main --------------------------------------------------------------------
$tempDir = Join-Path $env:TEMP "duo-sync-$([guid]::NewGuid().ToString('N'))"
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

    function Test-ExistingFilesPresent {
        if (-not $existing) { return $false }
        foreach ($arch in $Architectures) {
            $d = $existing.Files.$arch; $v = $existing.VCRedist.$arch
            if (-not $d -or -not (Test-Path (Join-Path $DestinationPath $d.FileName))) { return $false }
            if (-not $v -or -not (Test-Path (Join-Path $DestinationPath $v.FileName))) { return $false }
        }
        return $true
    }

    # ---------------- Duo MSI package ----------------
    $duoStamp   = Get-RemoteStamp $DuoZipUrl
    $duoChanged = $Force -or -not $duoStamp -or -not $existing -or ($existing.DuoSourceStamp -ne $duoStamp) -or -not (Test-ExistingFilesPresent)

    $newVersion = $existingVersion
    $duoFiles   = [ordered]@{}
    $published  = $false

    if (-not $duoChanged) {
        Write-Log 'Duo package unchanged since last sync.'
        foreach ($arch in $Architectures) { $duoFiles[$arch] = $existing.Files.$arch }
    }
    else {
        $zipPath = Join-Path $tempDir 'duo.zip'
        Write-Log 'Downloading Duo MSI package...'
        Invoke-WebRequest -Uri $DuoZipUrl -OutFile $zipPath -UseBasicParsing
        $extractDir = Join-Path $tempDir 'extract'
        Expand-Archive -Path $zipPath -DestinationPath $extractDir -Force

        # Find and check each MSI
        $found = @{}
        foreach ($arch in $Architectures) {
            $msi = Get-ChildItem -Path $extractDir -Recurse -File -Filter $MsiNames[$arch] | Select-Object -First 1
            if (-not $msi) { Write-Log "Package has no $($MsiNames[$arch]); skipping $arch." 'WARN'; continue }
            $signer = Assert-Signature $msi.FullName $DuoSignerPattern
            $ver    = ConvertTo-Version (Get-MsiProperty $msi.FullName 'ProductVersion')
            Write-Log "$($msi.Name): version $ver, signed by $signer"
            $found[$arch] = @{ File = $msi; Version = $ver }
        }
        if ($found.Count -eq 0) { throw 'The Duo package contained none of the requested MSIs.' }

        $versions = @($found.Values | ForEach-Object { $_.Version } | Sort-Object -Unique)
        if ($versions.Count -gt 1) { throw "MSIs in the package report different versions: $($versions -join ', ')" }
        $pkgVersion = $versions[0]
        Write-Log "Duo package version: $pkgVersion"

        if ($existingVersion -and $pkgVersion -le $existingVersion -and (Test-ExistingFilesPresent) -and -not $Force) {
            Write-Log 'Share already has this version (or newer).'
            foreach ($arch in $Architectures) { $duoFiles[$arch] = $existing.Files.$arch }
        }
        else {
            # Publish: copy the whole extracted package (MSIs + policy templates + docs) into a version folder
            $verFolderName = $pkgVersion.ToString(3)
            $verFolder     = Join-Path $DestinationPath $verFolderName
            $staging       = "$verFolder.partial"
            if (Test-Path $staging) { Remove-Item $staging -Recurse -Force }
            Copy-Item -Path $extractDir -Destination $staging -Recurse
            if (Test-Path $verFolder) { Remove-Item $verFolder -Recurse -Force }
            Rename-Item -Path $staging -NewName $verFolderName

            # Locate each MSI in the PUBLISHED folder and build its path relative to the share.
            # (Both paths come from the same listing, so short/long path forms can't get mixed up.)
            $verBase = (Get-Item -LiteralPath $verFolder).FullName.TrimEnd('\')
            foreach ($arch in $found.Keys) {
                $pubMsi = Get-ChildItem -LiteralPath $verBase -Recurse -File -Filter $MsiNames[$arch] | Select-Object -First 1
                if (-not $pubMsi) { throw "$($MsiNames[$arch]) not found in $verFolder after publishing." }
                $rel  = Join-Path $verFolderName $pubMsi.FullName.Substring($verBase.Length).TrimStart('\')
                $full = Join-Path $DestinationPath $rel
                if (-not (Test-Path -LiteralPath $full)) { throw "Computed path does not exist: $full" }
                $hash = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash
                $duoFiles[$arch] = [ordered]@{ FileName = $rel; Sha256 = $hash }
                Write-Log "  $arch -> $rel"
            }
            $newVersion = $pkgVersion
            $published  = $true
            Write-Log "Published Duo $pkgVersion to $verFolder"
        }
    }

    # ---------------- Visual C++ Redistributable ----------------
    $vcDir = Join-Path $DestinationPath 'VCRedist'
    if (-not (Test-Path $vcDir)) { New-Item -ItemType Directory -Path $vcDir | Out-Null }
    $vcFiles   = [ordered]@{}
    $vcChanged = $false

    foreach ($arch in $Architectures) {
        $url       = $VcUrls[$arch]
        $fileName  = "vc_redist.$arch.exe"
        $finalPath = Join-Path $vcDir $fileName
        $prev      = if ($existing) { $existing.VCRedist.$arch } else { $null }
        $stamp     = Get-RemoteStamp $url

        if (-not $Force -and $prev -and $stamp -and $prev.SourceStamp -eq $stamp -and (Test-Path $finalPath)) {
            $vcFiles[$arch] = $prev
            continue
        }

        Write-Log "Downloading $fileName..."
        $partial = "$finalPath.partial"
        Invoke-WebRequest -Uri $url -OutFile $partial -UseBasicParsing
        [void](Assert-Signature $partial $MsSignerPattern)
        $vcVersion = (Get-Item $partial).VersionInfo.ProductVersion
        Move-Item -Path $partial -Destination $finalPath -Force
        $vcFiles[$arch] = [ordered]@{
            FileName    = Join-Path 'VCRedist' $fileName
            Version     = $vcVersion
            Sha256      = (Get-FileHash -Path $finalPath -Algorithm SHA256).Hash
            SourceStamp = $stamp
        }
        $vcChanged = $true
        Write-Log "VC++ Redistributable $arch updated to $vcVersion"
    }

    # ---------------- Manifest ----------------
    if ($published -or $vcChanged -or -not $existing -or ($duoStamp -and $existing.DuoSourceStamp -ne $duoStamp)) {
        if (-not $newVersion) { throw 'No Duo version is available to publish.' }
        $manifest = [ordered]@{
            Product        = 'Duo Authentication for Windows Logon'
            Version        = $newVersion.ToString(3)
            UpdatedAt      = (Get-Date).ToString('o')
            DuoSourceStamp = $duoStamp
            Files          = $duoFiles
            VCRedist       = $vcFiles
        }
        $tmp = "$manifestPath.tmp"
        $manifest | ConvertTo-Json -Depth 6 | Set-Content -Path $tmp -Encoding UTF8
        Move-Item -Path $tmp -Destination $manifestPath -Force
        Write-Log "Manifest written: Duo $($manifest.Version)"
    }
    else {
        Write-Log 'Nothing changed. Share is up to date.'
    }

    # ---------------- Prune old Duo versions ----------------
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
            Invoke-OTTOIntunePackageBuild -AppId 'DuoWinLogon' -DestinationPath $DestinationPath -OutputPath $IntuneOutputPath `
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
            Update-OTTOCatalogEntry -AppId 'DuoWinLogon' -DestinationPath $DestinationPath -ManifestBefore $script:ManifestBefore `
                -Failed ([bool]($script:SyncFailed -or $script:IntuneFailed)) -Script 'Sync\DuoWinLogon.ps1' `
                -BoundParameters $PSBoundParameters -CatalogPath $CatalogPath -Definition $OTTOAppDefinition -ScriptPath $PSCommandPath -Log { param($m, $l) Write-Log $m $l }
        }
        catch { Write-Log "Couldn't update the repo catalog: $($_.Exception.Message)" 'WARN' }
    }
    # Release the one-sync-per-share lock (it would otherwise stay held until this PowerShell
    # window closes, so a second run in the same window would think a sync is still running)
    if ($script:SyncLock) { $script:SyncLock.Dispose(); $script:SyncLock = $null }
    if ($script:IntuneFailed) { exit 1 }
}
