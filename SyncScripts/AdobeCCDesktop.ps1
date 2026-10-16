<#
.SYNOPSIS
    SERVER SCRIPT - Publishes the newest Adobe Creative Cloud desktop app package from a
    drop folder to a network share for client machines.

.DESCRIPTION
    Adobe doesn't publish a downloadable Creative Cloud desktop app installer, and Remote
    Update Manager can't update the desktop app. Adobe's supported route is a package
    built in the Adobe Admin Console. So the workflow is:

      1. In the Admin Console, create a package that contains only the Creative Cloud
         desktop app (Packages > Create a package > Managed package, no apps added),
         for Windows 64-bit (and/or Windows ARM). Download it.
      2. Put the downloaded .zip (or the unzipped package folder) in -DropPath.
      3. Run this script (on a schedule is fine). It:
         - picks the newest package in the drop folder for each architecture
           (ARM64 if "ARM" is in the name, otherwise x64 - or set -Architecture),
         - skips it if it was already processed (name / size / date unchanged),
         - unpacks it, finds Build\setup.exe, checks its Adobe signature,
         - works out the Creative Cloud desktop app version inside (see below),
         - if newer than what's on the share, copies the package to
           <DestinationPath>\<arch>\<version>\ and updates latest.json (written last),
         - keeps the newest -KeepVersions versions per architecture.

    Working out the version: Admin Console packages don't state the desktop app version
    in one fixed place, so the script tries, in order: the file names in the package
    (e.g. ACCCx6_10_0_xxx), then the version of the Creative Cloud program files in the
    package, then the package's XML/JSON manifests. It logs what it used. If it can't
    tell, pass the version yourself with -Version (check Help > About in the Creative
    Cloud app on a machine where the package was installed).

    Folder layout:
        <DropPath>\CC_Desktop_Only_en_US_WIN_64.zip            (you put this here)
        <DestinationPath>\x64\6.10.0.123\Build\setup.exe       (published package)
        <DestinationPath>\latest.json
        <DestinationPath>\Logs\Sync-AdobeCCDesktopRepo.log

.PARAMETER DestinationPath
    Folder (local path or UNC) where packages are published for clients.
    Optional: if it's left out, the folder comes from the repo catalog
    (OTTOUpdate-Catalog.json): this app's Folder there (its full path), or
    <RepoRoot>\Applications\AdobeCCDesktop if the app isn't in the catalog yet. The catalog is found
    automatically when this script runs from <RepoRoot>\Administrative\Sync;
    otherwise pass -CatalogPath.

.PARAMETER CatalogPath
    The repo catalog to take the folder from when -DestinationPath isn't given, e.g.
    \\fileserver\Software\OTTOUpdate-Catalog.json. Default: <RepoRoot>\OTTOUpdate-Catalog.json
    when this script is in <RepoRoot>\Administrative\Sync.

.PARAMETER DropPath
    Folder where you put packages downloaded from the Admin Console.

.PARAMETER Architecture
    Treat every package in the drop folder as this architecture instead of guessing
    from the name. Normally leave unset.

.PARAMETER Version
    The Creative Cloud desktop app version in the newest package, if auto-detection
    can't find it (e.g. 6.10.0.123). Applies to the package being processed.

.PARAMETER KeepVersions
    How many versions to keep per architecture. Default: 2.

.PARAMETER Force
    Republish even if the newest package was already processed.

.PARAMETER BuildIntunePackage
    After a successful sync, also build a Microsoft Intune Win32 app package from what is
    on the share: <IntuneOutputPath>\AdobeCCDesktop\<version>\ gets AdobeCCDesktop-<version>.intunewin,
    Detect-AdobeCCDesktop.ps1 (custom detection script) and README-AdobeCCDesktop.txt (the install/uninstall
    commands, return codes and detection settings to enter in Intune). Nothing is rebuilt
    if that version's package already exists (unless -Force). Needs <RepoRoot>\Administrative\Shared\OTTOUpdate-Common.ps1 and the app's client script (catalog ClientScript, normally Apps\AdobeCCDesktop.ps1).

.PARAMETER IntuneOutputPath
    Where Intune packages are written. Default: <DestinationPath>\Intune

.PARAMETER ClientScriptPath
    Client script to put in the package. Default: the app's client script from the catalog (Apps\AdobeCCDesktop.ps1 under <RepoRoot>\Administrative).

.PARAMETER IntuneWinAppUtilPath
    Path to IntuneWinAppUtil.exe (Microsoft Win32 Content Prep Tool). Default: the repo's
    shared copy, <RepoRoot>\Tools\IntuneWinAppUtil.exe (<RepoRoot> = the parent of
    -DestinationPath), which Update-IntuneWinAppUtil.ps1 downloads if it's missing.

.EXAMPLE
    .\Sync\AdobeCCDesktop.ps1 -DestinationPath '\\fileserver\Software\Applications\AdobeCC' -DropPath '\\fileserver\Software\AdobeCC-Drop'

.EXAMPLE
    # Sync, then build the Intune package (.intunewin + detection script + README)
    .\Sync\AdobeCCDesktop.ps1 -DestinationPath '\\fileserver\Software\Applications\AdobeCC' -BuildIntunePackage
#>
[CmdletBinding()]
param(
    [string]$DestinationPath,

    [string]$CatalogPath,

    [Parameter(Mandatory)]
    [string]$DropPath,

    [ValidateSet('x64', 'arm64')]
    [string]$Architecture,

    [ValidatePattern('^\d+\.\d+(\.\d+){0,2}$')]
    [string]$Version,

    [ValidateRange(1, 10)]
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
    AppId        = 'AdobeCCDesktop'
    Name         = 'Adobe Creative Cloud desktop app'
    SyncScript   = 'Sync\AdobeCCDesktop.ps1'
    ClientScript = 'Apps\AdobeCCDesktop.ps1'
    Intune       = @{
        # Install command arguments after the script name. '-SourcePath .' becomes the repo path
        # plus the package's own copy as the fallback.
        InstallCommand  = '-SourcePath . -Install -CloseRunning'
        InstallVariants = @(
            '-SourcePath . -Install   (skips while Creative Cloud is running; returns 2 = retry)'
        )
        # The app's Programs and Features entries (regular expressions), for detection logging and uninstall
        Match           = @{ Pattern = '^Adobe Creative Cloud$'; Exclude = ''; KeyPattern = ''; Exe = '' }
        Detection       = @{
            # How it's detected, as written in Detect.log. Empty = the built-in check of the
            # Programs and Features entry (Match.Pattern) and, if newer, Match.Exe's file version
            Description     = 'Programs and Features entry'
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
            Code            = @'
$best = Get-Uninstall | Where-Object { $_.Name -match $App.Pattern } | Sort-Object Version -Descending | Select-Object -First 1
Test-Current $AppName $best.VersionText (Select-ArchEntry $Manifest.Files).Version
'@
        }
        Uninstall       = @{
            # Silent arguments for uninstallers that aren't MSI
            ExeArgs      = '-uninstall'
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
                    "Pass -DestinationPath <share>\AdobeCCDesktop, or -CatalogPath <RepoRoot>\OTTOUpdate-Catalog.json " +
                    "(found automatically when this script runs from <RepoRoot>\Administrative\Sync).") -ForegroundColor Red
        exit 1
    }
    try { $catalogData = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $CatalogPath).ProviderPath) | ConvertFrom-Json }
    catch { Write-Host "The repo catalog $CatalogPath can't be read: $($_.Exception.Message). Pass -DestinationPath instead." -ForegroundColor Red; exit 1 }
    $catalogEntry = @($catalogData.Apps) | Where-Object { $_ -and [string]$_.AppId -eq 'AdobeCCDesktop' } | Select-Object -First 1
    $catalogFolder = if ($catalogEntry -and $catalogEntry.Folder) { [string]$catalogEntry.Folder } else { 'Applications\AdobeCCDesktop' }
    # Folder is the app's full path (e.g. \\fileserver\Software\Applications\Chrome); older catalogs hold a name under the repo root
    $DestinationPath = if ($catalogFolder -match '^\\\\' -or [IO.Path]::IsPathRooted($catalogFolder)) { $catalogFolder }
                       else { Join-Path (Split-Path (Resolve-Path -LiteralPath $CatalogPath).ProviderPath -Parent) $catalogFolder }
    Write-Host ("-DestinationPath from the repo catalog: $DestinationPath" + $(if (-not $catalogEntry) { " (AdobeCCDesktop isn't in the catalog yet; it's added after this sync writes latest.json)" }))
}

$ErrorActionPreference = 'Stop'
$SignerPattern = 'Adobe'

# --- Helpers -----------------------------------------------------------------
if (-not (Test-Path $DestinationPath)) { New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null }
$logDir = Join-Path $DestinationPath 'Logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$LogFile = Join-Path $logDir 'Sync-AdobeCCDesktopRepo.log'

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

function Get-PackageArch([string]$Name) {
    if ($Architecture) { return $Architecture }
    if ($Name -match 'ARM') { 'arm64' } else { 'x64' }
}

function Get-DropStamp($Item) {
    if ($Item.PSIsContainer) {
        $files = @(Get-ChildItem -LiteralPath $Item.FullName -Recurse -File)
        $size  = ($files | Measure-Object Length -Sum).Sum
        $date  = ($files | Sort-Object LastWriteTimeUtc | Select-Object -Last 1).LastWriteTimeUtc
        return '{0}|dir|{1}|{2}|{3:o}' -f $Item.Name, $files.Count, $size, $date
    }
    return '{0}|{1}|{2:o}' -f $Item.Name, $Item.Length, $Item.LastWriteTimeUtc
}

function Find-CCDesktopVersion([string]$Root) {
    # Returns @{ Version = [version]; Method = '...' } or $null
    $all = @(Get-ChildItem -LiteralPath $Root -Recurse -File -ErrorAction SilentlyContinue)

    # 1) File/folder names such as ACCCx6_10_0_123.zip or ACC_6.10.0.123
    $cands = foreach ($f in $all) {
        $m = [regex]::Match($f.FullName, '(?i)ACCC?x?[_\-\s]?(\d+)[._](\d+)[._](\d+)[._](\d+)')
        if ($m.Success) { [version]('{0}.{1}.{2}.{3}' -f $m.Groups[1].Value, $m.Groups[2].Value, $m.Groups[3].Value, $m.Groups[4].Value) }
    }
    $best = $cands | Where-Object { $_.Major -ge 4 -and $_.Major -lt 50 } | Sort-Object -Descending | Select-Object -First 1
    if ($best) { return @{ Version = $best; Method = 'file name in package' } }

    # 2) Version of the Creative Cloud desktop program files in the package
    $exeNames = 'Creative Cloud.exe', 'Creative Cloud Installer.exe', 'Set-up.exe', 'Creative Cloud Helper.exe'
    $cands = foreach ($f in $all | Where-Object { $exeNames -contains $_.Name }) {
        $vi = $f.VersionInfo
        if ($vi.ProductName -match 'Creative Cloud' -or $vi.FileDescription -match 'Creative Cloud') {
            ConvertTo-Version $(if ($vi.ProductVersion) { $vi.ProductVersion } else { $vi.FileVersion })
        }
    }
    $best = $cands | Where-Object { $_ -and $_.Major -ge 4 -and $_.Major -lt 50 } | Sort-Object -Descending | Select-Object -First 1
    if ($best) { return @{ Version = $best; Method = 'Creative Cloud program file version' } }

    # 3) XML/JSON manifests that mention the desktop app (SAP code KCCC / ACC)
    $cands = foreach ($f in $all | Where-Object { $_.Extension -in '.xml', '.json' -and $_.Length -lt 5MB }) {
        $text = Get-Content -LiteralPath $f.FullName -Raw -ErrorAction SilentlyContinue
        if ($text -and $text -match 'KCCC|"ACC"|Creative Cloud') {
            foreach ($m in [regex]::Matches($text, '(?is)(?:KCCC|"ACC"|Creative Cloud).{0,300}?(?:version|ProductVersion|BaseVersion)["'':=>\s]+"?(\d+\.\d+\.\d+(?:\.\d+)?)')) {
                ConvertTo-Version $m.Groups[1].Value
            }
        }
    }
    $best = $cands | Where-Object { $_ -and $_.Major -ge 4 -and $_.Major -lt 50 } | Sort-Object -Descending | Select-Object -First 1
    if ($best) { return @{ Version = $best; Method = 'package manifest' } }

    return $null
}

# --- Main --------------------------------------------------------------------
$tempDir = Join-Path $env:TEMP "adobecc-sync-$([guid]::NewGuid().ToString('N'))"
try {
    # latest.json as it was before this run, for the repo catalog (see the end of the script)
    $script:ManifestBefore = $null
    try {
        $manifestBeforePath = Join-Path $DestinationPath 'latest.json'
        if (Test-Path -LiteralPath $manifestBeforePath) { $script:ManifestBefore = Get-Content -LiteralPath $manifestBeforePath -Raw }
    }
    catch { }
    Write-Log "---- Sync started. Drop folder: $DropPath  Destination: $DestinationPath"
    if (-not (Test-Path $DropPath)) { throw "Drop folder not found: $DropPath" }
    New-Item -ItemType Directory -Path $tempDir | Out-Null
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $manifestPath = Join-Path $DestinationPath 'latest.json'
    $existing = $null
    if (Test-Path $manifestPath) {
        try { $existing = Get-Content $manifestPath -Raw | ConvertFrom-Json }
        catch { Write-Log "Existing manifest is unreadable and will be replaced: $_" 'WARN' }
    }

    # Current manifest entries (kept for architectures we don't touch this run)
    $files = [ordered]@{}
    if ($existing -and $existing.Files) {
        foreach ($p in $existing.Files.PSObject.Properties) { $files[$p.Name] = $p.Value }
    }

    # Candidate packages: .zip files, or folders that contain Build\setup.exe
    $items = @(Get-ChildItem -LiteralPath $DropPath | Where-Object {
        (-not $_.PSIsContainer -and $_.Extension -eq '.zip') -or
        ($_.PSIsContainer -and (Get-ChildItem -LiteralPath $_.FullName -Recurse -Filter 'setup.exe' -File -ErrorAction SilentlyContinue |
                                Where-Object { $_.Directory.Name -eq 'Build' } | Select-Object -First 1))
    })
    if ($items.Count -eq 0) {
        Write-Log 'No packages in the drop folder. Nothing to do.'
        exit 0
    }

    $changed = $false
    foreach ($group in ($items | Group-Object { Get-PackageArch $_.Name })) {
        $arch = $group.Name
        $item = $group.Group | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
        $stamp = Get-DropStamp $item
        Write-Log "[$arch] Newest package in drop folder: $($item.Name)"

        $prev = $files[$arch]
        if ($prev -and $prev.SourceStamp -eq $stamp -and -not $Force -and
            (Test-Path -LiteralPath (Join-Path $DestinationPath $prev.SetupPath))) {
            Write-Log "[$arch] Already published as version $($prev.Version). Nothing to do."
            continue
        }

        # --- Unpack --------------------------------------------------------------
        $work = Join-Path $tempDir $arch
        if ($item.PSIsContainer) {
            $pkgRoot = $item.FullName
        }
        else {
            Write-Log "[$arch] Unpacking $($item.Name) ($([math]::Round($item.Length / 1MB)) MB)..."
            [IO.Compression.ZipFile]::ExtractToDirectory($item.FullName, $work)
            $pkgRoot = $work
        }

        $setup = Get-ChildItem -LiteralPath $pkgRoot -Recurse -Filter 'setup.exe' -File |
                 Where-Object { $_.Directory.Name -eq 'Build' } | Select-Object -First 1
        if (-not $setup) { throw "[$arch] $($item.Name) has no Build\setup.exe - is it an Admin Console package?" }
        $pkgDir = $setup.Directory.Parent.FullName        # the folder that contains Build\
        $pkgName = $setup.Directory.Parent.Name

        $sig = Get-AuthenticodeSignature -FilePath $setup.FullName
        if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch $SignerPattern) {
            throw "[$arch] Build\setup.exe signature check failed (status: $($sig.Status), signer: $($sig.SignerCertificate.Subject))."
        }

        # --- Version -------------------------------------------------------------
        if ($Version) {
            $pkgVersion = ConvertTo-Version $Version
            Write-Log "[$arch] Using -Version $pkgVersion"
        }
        else {
            $found = Find-CCDesktopVersion $pkgDir
            if (-not $found) {
                throw "[$arch] Couldn't work out the Creative Cloud desktop app version in $($item.Name). Re-run with -Version (e.g. -Version 6.10.0.123)."
            }
            $pkgVersion = $found.Version
            Write-Log "[$arch] Creative Cloud desktop app version $pkgVersion (from $($found.Method))"
        }

        $prevVersion = if ($prev) { ConvertTo-Version $prev.Version } else { $null }
        if ($prevVersion -and $pkgVersion -lt $prevVersion -and -not $Force) {
            Write-Log "[$arch] Package version $pkgVersion is older than the share's $prevVersion. Not publishing." 'WARN'
            continue
        }

        # --- Publish -------------------------------------------------------------
        $verName   = $pkgVersion.ToString()
        $archDir   = Join-Path $DestinationPath $arch
        if (-not (Test-Path $archDir)) { New-Item -ItemType Directory -Path $archDir | Out-Null }
        $verFolder = Join-Path $archDir $verName
        $staging   = "$verFolder.partial"
        if (Test-Path $staging) { Remove-Item $staging -Recurse -Force }
        Write-Log "[$arch] Copying package to share..."
        Copy-Item -LiteralPath $pkgDir -Destination $staging -Recurse
        if (Test-Path $verFolder) { Remove-Item $verFolder -Recurse -Force }
        Rename-Item -Path $staging -NewName $verName

        $pubFiles  = @(Get-ChildItem -LiteralPath $verFolder -Recurse -File)
        $pubSetup  = Join-Path $verFolder 'Build\setup.exe'
        $msi       = Get-ChildItem -LiteralPath (Join-Path $verFolder 'Build') -Filter '*.msi' -File | Select-Object -First 1
        $files[$arch] = [ordered]@{
            Version     = $verName
            PackageName = $pkgName
            Folder      = Join-Path $arch $verName
            SetupPath   = Join-Path $arch (Join-Path $verName 'Build\setup.exe')
            MsiName     = if ($msi) { $msi.Name } else { $null }
            SetupSha256 = (Get-FileHash -LiteralPath $pubSetup -Algorithm SHA256).Hash
            FileCount   = $pubFiles.Count
            TotalBytes  = ($pubFiles | Measure-Object Length -Sum).Sum
            SourceName  = $item.Name
            SourceStamp = $stamp
        }
        Write-Log ("[{0}] Published {1} as version {2} ({3} files, {4:N0} MB)." -f $arch, $pkgName, $verName, $pubFiles.Count, ($files[$arch].TotalBytes / 1MB))
        $changed = $true

        # Prune old versions for this architecture
        Get-ChildItem -Path $archDir -Directory |
            Where-Object { $_.Name -match '^\d+(\.\d+){1,3}$' } |
            Sort-Object { [version]$_.Name } -Descending |
            Select-Object -Skip $KeepVersions |
            ForEach-Object {
                Write-Log "[$arch] Removing old version folder $($_.Name)"
                Remove-Item $_.FullName -Recurse -Force
            }
        Get-ChildItem -Path $archDir -Directory -Filter '*.partial' | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }

    if ($changed) {
        $manifest = [ordered]@{
            Product   = 'Adobe Creative Cloud desktop app'
            UpdatedAt = (Get-Date).ToString('o')
            Files     = $files
        }
        $tmp = "$manifestPath.tmp"
        $manifest | ConvertTo-Json -Depth 5 | Set-Content -Path $tmp -Encoding UTF8
        Move-Item -Path $tmp -Destination $manifestPath -Force
        Write-Log "Manifest updated ($(($files.Keys | ForEach-Object { "$_ $($files[$_].Version)" }) -join ', '))."
    }

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
            Invoke-OTTOIntunePackageBuild -AppId 'AdobeCCDesktop' -DestinationPath $DestinationPath -OutputPath $IntuneOutputPath `
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
            Update-OTTOCatalogEntry -AppId 'AdobeCCDesktop' -DestinationPath $DestinationPath -ManifestBefore $script:ManifestBefore `
                -Failed ([bool]($script:SyncFailed -or $script:IntuneFailed)) -Script 'Sync\AdobeCCDesktop.ps1' `
                -BoundParameters $PSBoundParameters -CatalogPath $CatalogPath -Definition $OTTOAppDefinition -ScriptPath $PSCommandPath -Log { param($m, $l) Write-Log $m $l }
        }
        catch { Write-Log "Couldn't update the repo catalog: $($_.Exception.Message)" 'WARN' }
    }
    # Release the one-sync-per-share lock (it would otherwise stay held until this PowerShell
    # window closes, so a second run in the same window would think a sync is still running)
    if ($script:SyncLock) { $script:SyncLock.Dispose(); $script:SyncLock = $null }
    if ($script:IntuneFailed) { exit 1 }
}
