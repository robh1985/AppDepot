<#
.SYNOPSIS
    SERVER SCRIPT - Keeps a network share stocked with the latest Notepad++ MSI installers.

.DESCRIPTION
    - Asks the GitHub Releases API for the newest Notepad++ release.
    - Compares it with the version already in the destination folder (from latest.json).
    - If the folder has no installer, or an older one, downloads the MSI for each
      requested architecture, verifies it (GitHub SHA-256 digest + Authenticode
      signature), and writes a latest.json manifest that client machines read.
    - Downloads go to a temporary .partial file and the manifest is replaced as a
      single step at the end, so clients never see a half-written installer.
    - Older versions beyond -KeepVersions are removed.

    Folder layout it produces:
        <DestinationPath>\npp.8.7.1.Installer.x64.msi
        <DestinationPath>\npp.8.7.1.Installer.arm64.msi
        <DestinationPath>\latest.json
        <DestinationPath>\Logs\Sync-NotepadPlusPlusRepo.log

.PARAMETER DestinationPath
    Folder (local path or UNC) where the installers are stored.
    Example: D:\Software\NotepadPlusPlus  or  \\fileserver\Software\Applications\NotepadPlusPlus
    Optional: if it's left out, the folder comes from the repo catalog
    (OTTOUpdate-Catalog.json): this app's Folder there (its full path), or
    <RepoRoot>\Applications\NotepadPlusPlus if the app isn't in the catalog yet. The catalog is found
    automatically when this script runs from <RepoRoot>\Administrative\Sync;
    otherwise pass -CatalogPath.

.PARAMETER CatalogPath
    The repo catalog to take the folder from when -DestinationPath isn't given, e.g.
    \\fileserver\Software\OTTOUpdate-Catalog.json. Default: <RepoRoot>\OTTOUpdate-Catalog.json
    when this script is in <RepoRoot>\Administrative\Sync.

.PARAMETER Architectures
    Which MSI builds to keep. Default: x64, arm64, x86 (x86 lets clients update 32-bit
    Notepad++ in place, and covers 32-bit Windows).

.PARAMETER KeepVersions
    How many versions to keep in the folder (current one included). Default: 2.

.PARAMETER Force
    Download again even if the folder already has the latest version.

.PARAMETER BuildIntunePackage
    After a successful sync, also build a Microsoft Intune Win32 app package from what is
    on the share: <IntuneOutputPath>\NotepadPlusPlus\<version>\ gets NotepadPlusPlus-<version>.intunewin,
    Detect-NotepadPlusPlus.ps1 (custom detection script) and README-NotepadPlusPlus.txt (the install/uninstall
    commands, return codes and detection settings to enter in Intune). Nothing is rebuilt
    if that version's package already exists (unless -Force). Needs <RepoRoot>\Administrative\Shared\OTTOUpdate-Common.ps1 and the app's client script (catalog ClientScript, normally Apps\NotepadPlusPlus.ps1).

.PARAMETER IntuneOutputPath
    Where Intune packages are written. Default: <DestinationPath>\Intune

.PARAMETER ClientScriptPath
    Client script to put in the package. Default: the app's client script from the catalog (Apps\NotepadPlusPlus.ps1 under <RepoRoot>\Administrative).

.PARAMETER IntuneWinAppUtilPath
    Path to IntuneWinAppUtil.exe (Microsoft Win32 Content Prep Tool). Default: the repo's
    shared copy, <RepoRoot>\Tools\IntuneWinAppUtil.exe (<RepoRoot> = the parent of
    -DestinationPath), which Update-IntuneWinAppUtil.ps1 downloads if it's missing.

.EXAMPLE
    .\Sync\NotepadPlusPlus.ps1 -DestinationPath '\\fileserver\Software\Applications\NotepadPlusPlus'

.EXAMPLE
    # Sync, then build the Intune package (.intunewin + detection script + README)
    .\Sync\NotepadPlusPlus.ps1 -DestinationPath '\\fileserver\Software\Applications\NotepadPlusPlus' -BuildIntunePackage
#>
[CmdletBinding()]
param(
    [string]$DestinationPath,

    [string]$CatalogPath,

    [ValidateSet('x64', 'arm64', 'x86')]
    [string[]]$Architectures = @('x64', 'arm64', 'x86'),

    [ValidateRange(1, 50)]
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
    AppId        = 'NotepadPlusPlus'
    Name         = 'Notepad++'
    SyncScript   = 'Sync\NotepadPlusPlus.ps1'
    ClientScript = 'Apps\NotepadPlusPlus.ps1'
    Intune       = @{
        # Install command arguments after the script name. '-SourcePath .' becomes the repo path
        # plus the package's own copy as the fallback.
        InstallCommand  = '-SourcePath . -Install -CloseRunning'
        InstallVariants = @(
            '-SourcePath . -Install -ConvertToNativeArchitecture   (replace an installed copy of another architecture, e.g. 32-bit, with the build for this Windows)',
            '-SourcePath . -Install   (skip while Notepad++ is open; returns 2 = retry)'
        )
        # The app's Programs and Features entries (regular expressions), for detection logging and uninstall
        Match           = @{ Pattern = '^Notepad\+\+'; Exclude = ''; KeyPattern = ''; Exe = 'Notepad++\notepad++.exe' }
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
                    "Pass -DestinationPath <share>\NotepadPlusPlus, or -CatalogPath <RepoRoot>\OTTOUpdate-Catalog.json " +
                    "(found automatically when this script runs from <RepoRoot>\Administrative\Sync).") -ForegroundColor Red
        exit 1
    }
    try { $catalogData = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $CatalogPath).ProviderPath) | ConvertFrom-Json }
    catch { Write-Host "The repo catalog $CatalogPath can't be read: $($_.Exception.Message). Pass -DestinationPath instead." -ForegroundColor Red; exit 1 }
    $catalogEntry = @($catalogData.Apps) | Where-Object { $_ -and [string]$_.AppId -eq 'NotepadPlusPlus' } | Select-Object -First 1
    $catalogFolder = if ($catalogEntry -and $catalogEntry.Folder) { [string]$catalogEntry.Folder } else { 'Applications\NotepadPlusPlus' }
    # Folder is the app's full path (e.g. \\fileserver\Software\Applications\Chrome); older catalogs hold a name under the repo root
    $DestinationPath = if ($catalogFolder -match '^\\\\' -or [IO.Path]::IsPathRooted($catalogFolder)) { $catalogFolder }
                       else { Join-Path (Split-Path (Resolve-Path -LiteralPath $CatalogPath).ProviderPath -Parent) $catalogFolder }
    Write-Host ("-DestinationPath from the repo catalog: $DestinationPath" + $(if (-not $catalogEntry) { " (NotepadPlusPlus isn't in the catalog yet; it's added after this sync writes latest.json)" }))
}

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$ManifestName = 'latest.json'

# --- Helpers -----------------------------------------------------------------
if (-not (Test-Path $DestinationPath)) { New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null }
$logDir = Join-Path $DestinationPath 'Logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$LogFile = Join-Path $logDir 'Sync-NotepadPlusPlusRepo.log'

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
    # 'v8.7.1' / '8.7' / '8.7.1.0' -> comparable 4-part [version]
    $m = [regex]::Match([string]$Text, '\d+(\.\d+){0,3}')
    if (-not $m.Success) { return $null }
    $parts = @($m.Value.Split('.')) + @('0', '0', '0', '0') | Select-Object -First 4
    return [version]($parts -join '.')
}

function Find-MsiAsset($Release, [string]$Arch) {
    $msis = @($Release.assets | Where-Object { $_.name -match '\.msi$' })
    switch ($Arch) {
        'x64'   { $msis | Where-Object { $_.name -match '(x64|amd64)\.msi$' } | Select-Object -First 1 }
        'arm64' { $msis | Where-Object { $_.name -match 'arm64\.msi$' }       | Select-Object -First 1 }
        'x86'   { $msis | Where-Object { $_.name -notmatch '(x64|amd64|arm64)\.msi$' } | Select-Object -First 1 }
    }
}

# --- Main --------------------------------------------------------------------
try {
    # latest.json as it was before this run, for the repo catalog (see the end of the script)
    $script:ManifestBefore = $null
    try {
        $manifestBeforePath = Join-Path $DestinationPath 'latest.json'
        if (Test-Path -LiteralPath $manifestBeforePath) { $script:ManifestBefore = Get-Content -LiteralPath $manifestBeforePath -Raw }
    }
    catch { }
    Write-Log "---- Sync started. Destination: $DestinationPath  Architectures: $($Architectures -join ', ')"

    $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/notepad-plus-plus/notepad-plus-plus/releases/latest' `
                                 -Headers @{ 'User-Agent' = 'Sync-NotepadPlusPlusRepo.ps1'; 'Accept' = 'application/vnd.github+json' }
    $latestVersion = ConvertTo-Version $release.tag_name
    if (-not $latestVersion) { throw "Couldn't parse a version from release tag '$($release.tag_name)'." }
    Write-Log "Latest release on GitHub: $($release.tag_name) ($latestVersion)"

    # What's already in the folder?
    $manifestPath = Join-Path $DestinationPath $ManifestName
    $existing = $null
    if (Test-Path $manifestPath) {
        try { $existing = Get-Content $manifestPath -Raw | ConvertFrom-Json }
        catch { Write-Log "Existing manifest is unreadable and will be replaced: $_" 'WARN' }
    }

    $existingVersion = if ($existing) { ConvertTo-Version $existing.Version } else { $null }
    Write-Log "Version in folder: $(if ($existingVersion) { $existingVersion } else { 'none' })"

    # Up to date only if version matches AND every requested arch file is present
    $allPresent = $false
    if ($existing -and $existingVersion -ge $latestVersion) {
        $allPresent = $true
        foreach ($arch in $Architectures) {
            $entry = $existing.Files.$arch
            if (-not $entry -or -not (Test-Path (Join-Path $DestinationPath $entry.FileName))) { $allPresent = $false }
        }
    }
    if ($allPresent -and -not $Force) {
        Write-Log 'Folder already has the latest version. Nothing to do.'
        exit 0
    }

    # Download each architecture
    $files = [ordered]@{}
    foreach ($arch in $Architectures) {
        $asset = Find-MsiAsset $release $arch
        if (-not $asset) {
            Write-Log "No $arch MSI in release $($release.tag_name). Assets: $(($release.assets.name) -join ', ')" 'WARN'
            continue
        }

        $finalPath   = Join-Path $DestinationPath $asset.name
        $partialPath = "$finalPath.partial"

        Write-Log "Downloading $($asset.name) ($([math]::Round($asset.size / 1MB, 1)) MB)..."
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $partialPath -UseBasicParsing

        $hash = (Get-FileHash -Path $partialPath -Algorithm SHA256).Hash

        if ($asset.PSObject.Properties.Name -contains 'digest' -and $asset.digest -match '^sha256:([0-9a-fA-F]{64})$') {
            if ($hash -ne $Matches[1].ToUpper()) {
                Remove-Item $partialPath -Force
                throw "SHA-256 mismatch for $($asset.name). Expected $($Matches[1]), got $hash."
            }
            Write-Log 'SHA-256 matches GitHub digest.'
        }

        $sig = Get-AuthenticodeSignature -FilePath $partialPath
        if ($sig.Status -ne 'Valid') {
            Remove-Item $partialPath -Force
            throw "Signature on $($asset.name) is not valid (status: $($sig.Status))."
        }
        Write-Log "Signature valid: $($sig.SignerCertificate.Subject)"

        Move-Item -Path $partialPath -Destination $finalPath -Force
        $files[$arch] = [ordered]@{ FileName = $asset.name; Sha256 = $hash; Size = $asset.size }
    }

    if ($files.Count -eq 0) { throw 'No installers were downloaded.' }

    # Write the manifest atomically (temp file, then replace)
    $manifest = [ordered]@{
        Version     = $latestVersion.ToString()
        ReleaseTag  = $release.tag_name
        PublishedAt = $release.published_at
        DownloadedAt = (Get-Date).ToString('o')
        Files       = $files
    }
    $tmpManifest = "$manifestPath.tmp"
    $manifest | ConvertTo-Json -Depth 5 | Set-Content -Path $tmpManifest -Encoding UTF8
    Move-Item -Path $tmpManifest -Destination $manifestPath -Force
    Write-Log "Manifest updated: version $latestVersion ($($files.Keys -join ', '))"

    # Prune old versions
    $byVersion = Get-ChildItem -Path $DestinationPath -Filter 'npp.*.msi' -File |
        Group-Object { ConvertTo-Version ($_.Name -replace '^npp\.', '') } |
        Sort-Object { [version]$_.Name } -Descending
    $byVersion | Select-Object -Skip $KeepVersions | ForEach-Object {
        foreach ($f in $_.Group) {
            Write-Log "Removing old installer $($f.Name)"
            Remove-Item $f.FullName -Force
        }
    }
    Get-ChildItem -Path $DestinationPath -Filter '*.partial' -File | Remove-Item -Force -ErrorAction SilentlyContinue

    Write-Log '---- Sync finished successfully.'
    exit 0
}
catch {
    $script:SyncFailed = $true
    Write-Log "Sync failed: $($_.Exception.Message)" 'ERROR'
    exit 1
}
finally {
    # --- Optional: Intune Win32 package (only after a successful sync) ------------
    if ($BuildIntunePackage -and -not $script:SyncFailed) {
        try {
            $intuneHelper = Join-Path (Split-Path $PSScriptRoot -Parent) 'Shared\OTTOUpdate-Common.ps1'
            if (-not (Test-Path -LiteralPath $intuneHelper)) { throw "OTTOUpdate-Common.ps1 was not found at $intuneHelper. Keep this script in <RepoRoot>\Administrative\Sync and the library in <RepoRoot>\Administrative\Shared." }
            . $intuneHelper
            Invoke-OTTOIntunePackageBuild -AppId 'NotepadPlusPlus' -DestinationPath $DestinationPath -OutputPath $IntuneOutputPath `
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
            Update-OTTOCatalogEntry -AppId 'NotepadPlusPlus' -DestinationPath $DestinationPath -ManifestBefore $script:ManifestBefore `
                -Failed ([bool]($script:SyncFailed -or $script:IntuneFailed)) -Script 'Sync\NotepadPlusPlus.ps1' `
                -BoundParameters $PSBoundParameters -CatalogPath $CatalogPath -Definition $OTTOAppDefinition -ScriptPath $PSCommandPath -Log { param($m, $l) Write-Log $m $l }
        }
        catch { Write-Log "Couldn't update the repo catalog: $($_.Exception.Message)" 'WARN' }
    }
    # Release the one-sync-per-share lock (it would otherwise stay held until this PowerShell
    # window closes, so a second run in the same window would think a sync is still running)
    if ($script:SyncLock) { $script:SyncLock.Dispose(); $script:SyncLock = $null }
    if ($script:IntuneFailed) { exit 1 }
}
