<#
.SYNOPSIS
    SERVER SCRIPT - Keeps a network share stocked with the latest RingCentral desktop app
    auto-update MSI (the "Squirrel" machine-wide installer).

.DESCRIPTION
    RingCentral publishes the auto-update MSI at fixed "latest" links:
        x64:   https://app.ringcentral.com/download/squirrel-windows/RingCentral-Setup.msi
        ARM64: https://app.ringcentral.com/download/squirrel-windows-arm64/RingCentral-Setup-arm64.msi
    There's no version API, so this script:
    - Sends a HEAD request for each link and skips the download if the file hasn't
      changed since the last run (ETag / Last-Modified / size).
    - Otherwise downloads it, checks its Authenticode signature (RingCentral), and reads
      the real version, product name and UpgradeCode from the MSI. The client uses the
      UpgradeCode to recognise installed copies of this exact product.
    - If the version is newer than the share's, publishes it to a version folder and
      updates latest.json (written last).
    - Keeps the newest -KeepVersions version folders.

    Folder layout:
        <DestinationPath>\26.3.20.xxx\RingCentral-Setup.msi
        <DestinationPath>\26.3.20.xxx\RingCentral-Setup-arm64.msi
        <DestinationPath>\latest.json
        <DestinationPath>\Logs\Sync-RingCentralRepo.log

    Must run on Windows (it reads MSI details with the Windows Installer COM object).

.PARAMETER DestinationPath
    Folder (local path or UNC) where the installers are stored.
    Optional: if it's left out, the folder comes from the repo catalog
    (OTTOUpdate-Catalog.json): this app's Folder there (its full path), or
    <RepoRoot>\Applications\RingCentral if the app isn't in the catalog yet. The catalog is found
    automatically when this script runs from <RepoRoot>\Administrative\Sync;
    otherwise pass -CatalogPath.

.PARAMETER CatalogPath
    The repo catalog to take the folder from when -DestinationPath isn't given, e.g.
    \\fileserver\Software\OTTOUpdate-Catalog.json. Default: <RepoRoot>\OTTOUpdate-Catalog.json
    when this script is in <RepoRoot>\Administrative\Sync.

.PARAMETER Architectures
    Which builds to publish. Default: x64, arm64.

.PARAMETER KeepVersions
    How many version folders to keep. Default: 2.

.PARAMETER Proxy
    Proxy server for internet access, e.g. http://proxy.contoso.local:8080.

.PARAMETER ProxyUseDefaultCredentials
    Authenticate to the proxy as the account running the script.

.PARAMETER Force
    Download and republish even if nothing appears to have changed.

.PARAMETER BuildIntunePackage
    After a successful sync, also build a Microsoft Intune Win32 app package from what is
    on the share: <IntuneOutputPath>\RingCentral\<version>\ gets RingCentral-<version>.intunewin,
    Detect-RingCentral.ps1 (custom detection script) and README-RingCentral.txt (the install/uninstall
    commands, return codes and detection settings to enter in Intune). Nothing is rebuilt
    if that version's package already exists (unless -Force). Needs <RepoRoot>\Administrative\Shared\OTTOUpdate-Common.ps1 and the app's client script (catalog ClientScript, normally Apps\RingCentral.ps1).

.PARAMETER IntuneOutputPath
    Where Intune packages are written. Default: <DestinationPath>\Intune

.PARAMETER ClientScriptPath
    Client script to put in the package. Default: the app's client script from the catalog (Apps\RingCentral.ps1 under <RepoRoot>\Administrative).

.PARAMETER IntuneWinAppUtilPath
    Path to IntuneWinAppUtil.exe (Microsoft Win32 Content Prep Tool). Default: the repo's
    shared copy, <RepoRoot>\Tools\IntuneWinAppUtil.exe (<RepoRoot> = the parent of
    -DestinationPath), which Update-IntuneWinAppUtil.ps1 downloads if it's missing.

.EXAMPLE
    .\Sync\RingCentral.ps1 -DestinationPath '\\fileserver\Software\Applications\RingCentral'

.EXAMPLE
    # Sync, then build the Intune package (.intunewin + detection script + README)
    .\Sync\RingCentral.ps1 -DestinationPath '\\fileserver\Software\Applications\RingCentral' -BuildIntunePackage
#>
[CmdletBinding()]
param(
    [string]$DestinationPath,

    [string]$CatalogPath,

    [ValidateSet('x64', 'arm64')]
    [string[]]$Architectures = @('x64', 'arm64'),

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
    AppId        = 'RingCentral'
    Name         = 'RingCentral (auto-update MSI)'
    SyncScript   = 'Sync\RingCentral.ps1'
    ClientScript = 'Apps\RingCentral.ps1'
    Intune       = @{
        # Install command arguments after the script name. '-SourcePath .' becomes the repo path
        # plus the package's own copy as the fallback.
        InstallCommand  = '-SourcePath . -Install'
        InstallVariants = @(
            '-SourcePath . -Install -ConvertToNativeArchitecture   (replace an installed copy of another architecture, e.g. 32-bit, with the build for this Windows)',
            '-SourcePath . -Install -CloseRunning'
        )
        # The app's Programs and Features entries (regular expressions), for detection logging and uninstall
        Match           = @{ Pattern = '^RingCentral'; Exclude = 'Meeting|Teams|VDI|Plugin|Phone|Video|Rooms|Outlook|Embeddable|Classic|Service|Add-?in|Chrome|Edge'; KeyPattern = ''; Exe = '' }
        Detection       = @{
            # How it's detected, as written in Detect.log. Empty = the built-in check of the
            # Programs and Features entry (Match.Pattern) and, if newer, Match.Exe's file version
            Description     = 'MSI upgrade code of the auto-update MSI (any architecture)'
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
# Any build's auto-update MSI counts (installed copies are updated in their own architecture)
$entries = @($Manifest.Files.PSObject.Properties | ForEach-Object { $_.Value })
$best = @($entries | ForEach-Object { $_.UpgradeCode } | Sort-Object -Unique | ForEach-Object { Get-RelatedProducts $_ }) |
        Sort-Object Version -Descending | Select-Object -First 1
$want = $entries | ForEach-Object { $_.ProductVersion } | Sort-Object { ConvertTo-Version $_ } | Select-Object -First 1
Test-Current 'RingCentral (auto-update MSI)' $best.VersionText $want
'@
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
                    "Pass -DestinationPath <share>\RingCentral, or -CatalogPath <RepoRoot>\OTTOUpdate-Catalog.json " +
                    "(found automatically when this script runs from <RepoRoot>\Administrative\Sync).") -ForegroundColor Red
        exit 1
    }
    try { $catalogData = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $CatalogPath).ProviderPath) | ConvertFrom-Json }
    catch { Write-Host "The repo catalog $CatalogPath can't be read: $($_.Exception.Message). Pass -DestinationPath instead." -ForegroundColor Red; exit 1 }
    $catalogEntry = @($catalogData.Apps) | Where-Object { $_ -and [string]$_.AppId -eq 'RingCentral' } | Select-Object -First 1
    $catalogFolder = if ($catalogEntry -and $catalogEntry.Folder) { [string]$catalogEntry.Folder } else { 'Applications\RingCentral' }
    # Folder is the app's full path (e.g. \\fileserver\Software\Applications\Chrome); older catalogs hold a name under the repo root
    $DestinationPath = if ($catalogFolder -match '^\\\\' -or [IO.Path]::IsPathRooted($catalogFolder)) { $catalogFolder }
                       else { Join-Path (Split-Path (Resolve-Path -LiteralPath $CatalogPath).ProviderPath -Parent) $catalogFolder }
    Write-Host ("-DestinationPath from the repo catalog: $DestinationPath" + $(if (-not $catalogEntry) { " (RingCentral isn't in the catalog yet; it's added after this sync writes latest.json)" }))
}

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
try   { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13 }
catch { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 }

$Urls = @{
    x64   = 'https://app.ringcentral.com/download/squirrel-windows/RingCentral-Setup.msi'
    arm64 = 'https://app.ringcentral.com/download/squirrel-windows-arm64/RingCentral-Setup-arm64.msi'
}
$SignerPattern  = 'RingCentral'
$UserAgent      = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36'
$BrowserHeaders = @{ 'Accept' = '*/*'; 'Accept-Language' = 'en-US,en;q=0.9' }

if ($Proxy) {
    $PSDefaultParameterValues['Invoke-WebRequest:Proxy'] = $Proxy
    if ($ProxyUseDefaultCredentials) { $PSDefaultParameterValues['Invoke-WebRequest:ProxyUseDefaultCredentials'] = $true }
}

# --- Helpers -----------------------------------------------------------------
if (-not (Test-Path $DestinationPath)) { New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null }
$logDir = Join-Path $DestinationPath 'Logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$LogFile = Join-Path $logDir 'Sync-RingCentralRepo.log'

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

function Get-RemoteStamp([string]$Url) {
    try {
        $r = Invoke-WebRequest -Uri $Url -Method Head -UseBasicParsing -UserAgent $UserAgent -Headers $BrowserHeaders
        $h = $r.Headers
        $val = { param($n) $v = $h[$n]; if ($v -is [array]) { $v -join ',' } else { [string]$v } }
        return '{0}|{1}|{2}' -f (& $val 'ETag'), (& $val 'Last-Modified'), (& $val 'Content-Length')
    }
    catch {
        Write-Log "HEAD request failed for $Url ($(Get-ErrorDetail $_)); will download to check." 'WARN'
        return $null
    }
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

# --- Main --------------------------------------------------------------------
$tempDir = Join-Path $env:TEMP "ringcentral-sync-$([guid]::NewGuid().ToString('N'))"
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
    Write-Log "Version on share: $(if ($existingVersion) { $existing.Version } else { 'none' })"

    # --- Anything changed upstream? ------------------------------------------
    $stamps = @{}
    $changed = $Force -or -not $existing
    foreach ($arch in $Architectures) {
        $stamps[$arch] = Get-RemoteStamp $Urls[$arch]
        $e = if ($existing) { $existing.Files.$arch } else { $null }
        if (-not $stamps[$arch] -or -not $e -or $e.SourceStamp -ne $stamps[$arch] -or
            -not (Test-Path -LiteralPath (Join-Path $DestinationPath $e.FileName))) { $changed = $true }
    }
    if (-not $changed) {
        Write-Log 'Download links unchanged and files present. Nothing to do.'
        exit 0
    }

    # --- Download and inspect ------------------------------------------------
    $found = [ordered]@{}
    foreach ($arch in $Architectures) {
        $url      = $Urls[$arch]
        $fileName = Split-Path ([Uri]$url).AbsolutePath -Leaf
        $local    = Join-Path $tempDir $fileName
        Write-Log "Downloading $url"
        try { Invoke-WebRequest -Uri $url -OutFile $local -UseBasicParsing -UserAgent $UserAgent -Headers $BrowserHeaders }
        catch { Write-Log "  failed: $(Get-ErrorDetail $_); skipping $arch." 'WARN'; continue }

        $sig = Get-AuthenticodeSignature -FilePath $local
        if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch $SignerPattern) {
            throw "Signature check failed for $fileName ($arch) (status: $($sig.Status), signer: $($sig.SignerCertificate.Subject))."
        }
        $info = @{
            Path           = $local
            Name           = $fileName
            ProductName    = Get-MsiProperty $local 'ProductName'
            ProductVersion = Get-MsiProperty $local 'ProductVersion'
            UpgradeCode    = ([string](Get-MsiProperty $local 'UpgradeCode')).ToUpper()
            Hash           = (Get-FileHash -LiteralPath $local -Algorithm SHA256).Hash
            Stamp          = $stamps[$arch]
        }
        Write-Log "$arch : $($info.ProductName) $($info.ProductVersion)  UpgradeCode $($info.UpgradeCode)  signed by $($sig.SignerCertificate.Subject)"
        $found[$arch] = $info
    }
    if ($found.Count -eq 0) { throw 'No installers were downloaded.' }

    $versions = @($found.Values | ForEach-Object { ConvertTo-Version $_.ProductVersion } | Sort-Object -Unique)
    if ($versions.Count -gt 1) { Write-Log "Builds report different versions ($($versions -join ', ')); using the highest for the folder name." 'WARN' }
    $pkgVersion = $versions | Sort-Object -Descending | Select-Object -First 1
    $release    = @($found.Values)[0].ProductVersion
    if ($versions.Count -gt 1) { $release = $pkgVersion.ToString() }

    # Same version, only the link fingerprint changed: just refresh the stamps
    if ($existingVersion -and $pkgVersion -le $existingVersion -and -not $Force) {
        $allPresent = $true
        foreach ($arch in $Architectures) {
            $e = $existing.Files.$arch
            if (-not $e -or -not (Test-Path -LiteralPath (Join-Path $DestinationPath $e.FileName))) { $allPresent = $false }
        }
        if ($allPresent) {
            foreach ($arch in $found.Keys) { $existing.Files.$arch.SourceStamp = $found[$arch].Stamp }
            $tmp = "$manifestPath.tmp"
            $existing | ConvertTo-Json -Depth 5 | Set-Content -Path $tmp -Encoding UTF8
            Move-Item -Path $tmp -Destination $manifestPath -Force
            Write-Log "Downloaded version $pkgVersion is not newer than the share's. Nothing to publish."
            exit 0
        }
    }

    # --- Publish -------------------------------------------------------------
    $verFolder = Join-Path $DestinationPath $release
    $staging   = "$verFolder.partial"
    if (Test-Path $staging) { Remove-Item $staging -Recurse -Force }
    New-Item -ItemType Directory -Path $staging | Out-Null

    $files = [ordered]@{}
    foreach ($arch in $found.Keys) {
        Copy-Item -LiteralPath $found[$arch].Path -Destination (Join-Path $staging $found[$arch].Name)
        $files[$arch] = [ordered]@{
            FileName       = Join-Path $release $found[$arch].Name
            Sha256         = $found[$arch].Hash
            ProductName    = $found[$arch].ProductName
            ProductVersion = $found[$arch].ProductVersion
            UpgradeCode    = $found[$arch].UpgradeCode
            SourceStamp    = $found[$arch].Stamp
        }
    }
    if (Test-Path $verFolder) { Remove-Item $verFolder -Recurse -Force }
    Rename-Item -Path $staging -NewName $release

    $manifest = [ordered]@{
        Product   = 'RingCentral desktop app (auto-update MSI)'
        Version   = $release
        UpdatedAt = (Get-Date).ToString('o')
        Files     = $files
    }
    $tmp = "$manifestPath.tmp"
    $manifest | ConvertTo-Json -Depth 5 | Set-Content -Path $tmp -Encoding UTF8
    Move-Item -Path $tmp -Destination $manifestPath -Force
    Write-Log "Published RingCentral $release ($($files.Keys -join ', ')) and updated manifest."

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
            Invoke-OTTOIntunePackageBuild -AppId 'RingCentral' -DestinationPath $DestinationPath -OutputPath $IntuneOutputPath `
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
            Update-OTTOCatalogEntry -AppId 'RingCentral' -DestinationPath $DestinationPath -ManifestBefore $script:ManifestBefore `
                -Failed ([bool]($script:SyncFailed -or $script:IntuneFailed)) -Script 'Sync\RingCentral.ps1' `
                -BoundParameters $PSBoundParameters -CatalogPath $CatalogPath -Definition $OTTOAppDefinition -ScriptPath $PSCommandPath -Log { param($m, $l) Write-Log $m $l }
        }
        catch { Write-Log "Couldn't update the repo catalog: $($_.Exception.Message)" 'WARN' }
    }
    # Release the one-sync-per-share lock (it would otherwise stay held until this PowerShell
    # window closes, so a second run in the same window would think a sync is still running)
    if ($script:SyncLock) { $script:SyncLock.Dispose(); $script:SyncLock = $null }
    if ($script:IntuneFailed) { exit 1 }
}
