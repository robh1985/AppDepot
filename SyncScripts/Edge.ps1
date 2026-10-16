<#
.SYNOPSIS
    SERVER SCRIPT - Keeps a network share stocked with the latest Microsoft Edge for
    Business (Enterprise) MSI installers, Stable channel.

.DESCRIPTION
    Microsoft publishes every Edge Enterprise release, with its download link and SHA-256
    hash, in its Edge release feed (the same feed the "Microsoft Edge for Business" download
    page uses):
        https://edgeupdates.microsoft.com/api/products?view=enterprise
    This script:
    - Reads the feed and picks the newest Stable Windows release for each architecture
      (x64, x86, ARM64): MicrosoftEdgeEnterpriseX64.msi / X86.msi / ARM64.msi.
    - Skips an architecture if the share already has that version.
    - Otherwise downloads the MSI (progress logging, stall timeout), checks the SHA-256
      against the feed, checks the Authenticode signature (Microsoft Corporation), and
      publishes it to <DestinationPath>\<version>\.
    - Writes latest.json last. Keeps the newest -KeepVersions version folders.

    Folder layout:
        <DestinationPath>\154.0.4258.48\MicrosoftEdgeEnterpriseX64.msi  (X86, ARM64)
        <DestinationPath>\latest.json
        <DestinationPath>\Logs\Sync-EdgeRepo.log

.PARAMETER DestinationPath
    Folder (local path or UNC) where the installers are stored.
    Optional: if it's left out, the folder comes from the repo catalog
    (OTTOUpdate-Catalog.json): this app's Folder there (its full path), or
    <RepoRoot>\Applications\Edge if the app isn't in the catalog yet. The catalog is found
    automatically when this script runs from <RepoRoot>\Administrative\Sync;
    otherwise pass -CatalogPath.

.PARAMETER CatalogPath
    The repo catalog to take the folder from when -DestinationPath isn't given, e.g.
    \\fileserver\Software\OTTOUpdate-Catalog.json. Default: <RepoRoot>\OTTOUpdate-Catalog.json
    when this script is in <RepoRoot>\Administrative\Sync.

.PARAMETER Architectures
    Which builds to keep. Default: x64, arm64, x86 (x86 lets clients update 32-bit Edge in
    place, and covers 32-bit Windows).

.PARAMETER KeepVersions
    How many version folders to keep. Default: 2.

.PARAMETER Proxy
    Proxy server for internet access, e.g. http://proxy.contoso.local:8080.

.PARAMETER ProxyUseDefaultCredentials
    Authenticate to the proxy as the account running the script.

.PARAMETER PageTimeoutSec
    Seconds to wait for a server to respond / a download to start. Default: 60.

.PARAMETER StallTimeoutSec
    Give up on a download if no data arrives for this many seconds. Default: 120.

.PARAMETER Force
    Download and republish even if the share already has the latest version.

.PARAMETER BuildIntunePackage
    After a successful sync, also build a Microsoft Intune Win32 app package from what is
    on the share: <IntuneOutputPath>\Edge\<version>\ gets Edge-<version>.intunewin,
    Detect-Edge.ps1 (custom detection script) and README-Edge.txt (the install/uninstall
    commands, return codes and detection settings to enter in Intune). Nothing is rebuilt
    if that version's package already exists (unless -Force). Needs <RepoRoot>\Administrative\Shared\OTTOUpdate-Common.ps1 and the app's client script (catalog ClientScript, normally Apps\Edge.ps1).

.PARAMETER IntuneOutputPath
    Where Intune packages are written. Default: <DestinationPath>\Intune

.PARAMETER ClientScriptPath
    Client script to put in the package. Default: the app's client script from the catalog (Apps\Edge.ps1 under <RepoRoot>\Administrative).

.PARAMETER IntuneWinAppUtilPath
    Path to IntuneWinAppUtil.exe (Microsoft Win32 Content Prep Tool). Default: the repo's
    shared copy, <RepoRoot>\Tools\IntuneWinAppUtil.exe (<RepoRoot> = the parent of
    -DestinationPath), which Update-IntuneWinAppUtil.ps1 downloads if it's missing.

.EXAMPLE
    .\Sync\Edge.ps1 -DestinationPath '\\fileserver\Software\Applications\Edge'

.EXAMPLE
    # Sync, then build the Intune package (.intunewin + detection script + README)
    .\Sync\Edge.ps1 -DestinationPath '\\fileserver\Software\Applications\Edge' -BuildIntunePackage
#>
[CmdletBinding()]
param(
    [string]$DestinationPath,

    [string]$CatalogPath,

    [ValidateSet('x64', 'x86', 'arm64')]
    [string[]]$Architectures = @('x64', 'arm64', 'x86'),

    [ValidateRange(1, 20)]
    [int]$KeepVersions = 2,

    [string]$Proxy,

    [switch]$ProxyUseDefaultCredentials,

    [ValidateRange(10, 600)]
    [int]$PageTimeoutSec = 60,

    [ValidateRange(30, 1800)]
    [int]$StallTimeoutSec = 120,

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
    AppId        = 'Edge'
    Name         = 'Microsoft Edge'
    SyncScript   = 'Sync\Edge.ps1'
    ClientScript = 'Apps\Edge.ps1'
    Intune       = @{
        # Install command arguments after the script name. '-SourcePath .' becomes the repo path
        # plus the package's own copy as the fallback.
        InstallCommand  = '-SourcePath . -Install'
        InstallVariants = @(
            '-SourcePath . -Install -MsiProperties DONOTCREATEDESKTOPSHORTCUT=TRUE   (no desktop shortcut)',
            '-SourcePath . -Install -ConvertToNativeArchitecture   (replace an installed copy of another architecture, e.g. 32-bit, with the build for this Windows)'
        )
        # The app's Programs and Features entries (regular expressions), for detection logging and uninstall
        Match           = @{ Pattern = '^Microsoft Edge$'; Exclude = ''; KeyPattern = ''; Exe = '' }
        Detection       = @{
            # How it's detected, as written in Detect.log. Empty = the built-in check of the
            # Programs and Features entry (Match.Pattern) and, if newer, Match.Exe's file version
            Description     = 'file version of msedge.exe / new_msedge.exe, and the EdgeUpdate version'
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
# Newest of msedge.exe, an update waiting for Edge to restart (new_msedge.exe), and Edge's
# own updater record - so a computer isn't reported as old just because Edge is still open
$vers = @()
foreach ($dir in @((Get-PF86), (Get-PF64)) | Where-Object { $_ } | Select-Object -Unique) {
    foreach ($n in 'msedge.exe', 'new_msedge.exe') { $vers += Get-FileVer (Join-Path $dir "Microsoft\Edge\Application\$n") }
}
if ($vers | Where-Object { $_ }) {
    foreach ($view in [Microsoft.Win32.RegistryView]::Registry32, [Microsoft.Win32.RegistryView]::Registry64) {
        try {
            $k = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, $view).OpenSubKey('SOFTWARE\Microsoft\EdgeUpdate\Clients\{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}')
            if ($k) { $pv = [string]$k.GetValue('pv'); Note "  EdgeUpdate ($view) pv: $pv"; $vers += ConvertTo-Version $pv }
        } catch { }
    }
}
$best = $vers | Where-Object { $_ } | Sort-Object -Descending | Select-Object -First 1
$want = @($Manifest.Files.PSObject.Properties | ForEach-Object { $_.Value.Version }) | Sort-Object { ConvertTo-Version $_ } | Select-Object -First 1
Test-Current $AppName $(if ($best) { "$best" }) $want
'@
        }
        Uninstall       = @{
            # Silent arguments for uninstallers that aren't MSI
            ExeArgs      = ''
            # A reason the app can't be uninstalled (the uninstall script then only logs it)
            NotSupported = 'Microsoft Edge is part of Windows and can''t be uninstalled this way. Don''t assign this app as "Uninstall".'
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
                    "Pass -DestinationPath <share>\Edge, or -CatalogPath <RepoRoot>\OTTOUpdate-Catalog.json " +
                    "(found automatically when this script runs from <RepoRoot>\Administrative\Sync).") -ForegroundColor Red
        exit 1
    }
    try { $catalogData = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $CatalogPath).ProviderPath) | ConvertFrom-Json }
    catch { Write-Host "The repo catalog $CatalogPath can't be read: $($_.Exception.Message). Pass -DestinationPath instead." -ForegroundColor Red; exit 1 }
    $catalogEntry = @($catalogData.Apps) | Where-Object { $_ -and [string]$_.AppId -eq 'Edge' } | Select-Object -First 1
    $catalogFolder = if ($catalogEntry -and $catalogEntry.Folder) { [string]$catalogEntry.Folder } else { 'Applications\Edge' }
    # Folder is the app's full path (e.g. \\fileserver\Software\Applications\Chrome); older catalogs hold a name under the repo root
    $DestinationPath = if ($catalogFolder -match '^\\\\' -or [IO.Path]::IsPathRooted($catalogFolder)) { $catalogFolder }
                       else { Join-Path (Split-Path (Resolve-Path -LiteralPath $CatalogPath).ProviderPath -Parent) $catalogFolder }
    Write-Host ("-DestinationPath from the repo catalog: $DestinationPath" + $(if (-not $catalogEntry) { " (Edge isn't in the catalog yet; it's added after this sync writes latest.json)" }))
}

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
try   { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13 }
catch { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 }

# Apply proxy settings to every web request in this script
if ($Proxy) {
    $PSDefaultParameterValues['Invoke-RestMethod:Proxy'] = $Proxy
    if ($ProxyUseDefaultCredentials) { $PSDefaultParameterValues['Invoke-RestMethod:ProxyUseDefaultCredentials'] = $true }
}

$FeedUrl       = 'https://edgeupdates.microsoft.com/api/products?view=enterprise'
$Channel       = 'Stable'
$SignerPattern = 'O=Microsoft Corporation'
$UserAgent     = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Sync-EdgeRepo.ps1'

# --- Helpers -----------------------------------------------------------------
if (-not (Test-Path $DestinationPath)) { New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null }
$logDir = Join-Path $DestinationPath 'Logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$LogFile = Join-Path $logDir 'Sync-EdgeRepo.log'

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

function Get-ErrorDetail($ErrorRecord) {
    $msgs = @(); $e = $ErrorRecord.Exception
    while ($e) { $msgs += $e.Message; $e = $e.InnerException }
    return ($msgs | Select-Object -Unique) -join ' --> '
}

function ConvertTo-Version([string]$Text) {
    $m = [regex]::Match([string]$Text, '\d+(\.\d+){0,3}')
    if (-not $m.Success) { return $null }
    $parts = @($m.Value.Split('.')) + @('0', '0', '0', '0') | Select-Object -First 4
    return [version]($parts -join '.')
}

function New-HttpClient {
    Add-Type -AssemblyName System.Net.Http
    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.AllowAutoRedirect = $true
    if ($Proxy) {
        $wp = New-Object System.Net.WebProxy($Proxy)
        $wp.UseDefaultCredentials = [bool]$ProxyUseDefaultCredentials
        $handler.Proxy = $wp
        $handler.UseProxy = $true
    }
    $client = New-Object System.Net.Http.HttpClient($handler)
    $client.Timeout = [System.Threading.Timeout]::InfiniteTimeSpan
    [void]$client.DefaultRequestHeaders.TryAddWithoutValidation('User-Agent', $UserAgent)
    return $client
}

function Save-Download([string]$Url, [string]$OutFile) {
    # Streams a file to disk; gives up if no data arrives for $StallTimeoutSec.
    $client = New-HttpClient
    $resp = $in = $out = $null
    try {
        $task = $client.GetAsync($Url, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead)
        if (-not $task.Wait([TimeSpan]::FromSeconds($PageTimeoutSec))) { throw "No response within $PageTimeoutSec seconds." }
        $resp = $task.Result
        if (-not $resp.IsSuccessStatusCode) { throw "Server returned $([int]$resp.StatusCode) $($resp.ReasonPhrase)." }
        $total = $resp.Content.Headers.ContentLength
        $in    = $resp.Content.ReadAsStreamAsync().Result
        $out   = [IO.File]::Create($OutFile)
        $buf   = New-Object byte[] (1MB)
        $done  = [long]0
        $start = Get-Date
        $nextLog = $start.AddSeconds(30)
        while ($true) {
            $read = $in.ReadAsync($buf, 0, $buf.Length)
            if (-not $read.Wait([TimeSpan]::FromSeconds($StallTimeoutSec))) {
                throw ("Download stalled: no data for {0} s after {1:N0} MB." -f $StallTimeoutSec, ($done / 1MB))
            }
            $n = $read.Result
            if ($n -le 0) { break }
            $out.Write($buf, 0, $n)
            $done += $n
            if ((Get-Date) -ge $nextLog) {
                Write-Log ("  {0:N0} MB, {1:N1} MB/s" -f ($done / 1MB), (($done / 1MB) / [math]::Max(1, ((Get-Date) - $start).TotalSeconds)))
                $nextLog = (Get-Date).AddSeconds(30)
            }
        }
        if ($total -and $done -ne $total) { throw ("Download incomplete: got {0:N0} of {1:N0} bytes." -f $done, $total) }
    }
    catch {
        if ($out) { $out.Dispose(); $out = $null }
        Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue
        throw
    }
    finally {
        if ($out)  { $out.Dispose() }
        if ($in)   { $in.Dispose() }
        if ($resp) { $resp.Dispose() }
        $client.Dispose()
    }
}

function Get-EdgeReleases {
    # Newest Stable Windows MSI per architecture from Microsoft's Edge release feed
    $feed = Invoke-RestMethod -Uri $FeedUrl -TimeoutSec $PageTimeoutSec -Headers @{ 'User-Agent' = $UserAgent }
    # Assign first, then enumerate: 5.1 and 7 differ in how a JSON array comes down the pipeline
    $product = @($feed) | ForEach-Object { $_ } | Where-Object { $_.Product -eq $Channel } | Select-Object -First 1
    if (-not $product) { throw "The Edge release feed has no '$Channel' channel." }
    $out = @{}
    foreach ($r in @($product.Releases) | ForEach-Object { $_ }) {
        if ($r.Platform -ne 'Windows') { continue }
        $arch = ([string]$r.Architecture).ToLower()
        if ($arch -notin 'x64', 'x86', 'arm64') { continue }
        $msi = @($r.Artifacts) | Where-Object { $_.ArtifactName -eq 'msi' } | Select-Object -First 1
        if (-not $msi -or -not $msi.Location) { continue }
        $prev = $out[$arch]
        if ($prev -and (ConvertTo-Version $prev.Version) -ge (ConvertTo-Version $r.ProductVersion)) { continue }
        $out[$arch] = [pscustomobject]@{
            Version   = [string]$r.ProductVersion
            Url       = [string]$msi.Location
            Sha256    = if ($msi.HashAlgorithm -match 'SHA256' -and $msi.Hash) { ([string]$msi.Hash).ToUpper() } else { $null }
            Size      = $msi.SizeInBytes
            Published = $r.PublishedTime
            Name      = Split-Path ([Uri]$msi.Location).AbsolutePath -Leaf
        }
    }
    return $out
}

# --- Main --------------------------------------------------------------------
$tempDir = Join-Path $env:TEMP "edge-sync-$([guid]::NewGuid().ToString('N'))"
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
    Write-Log "Version on share: $(if ($existing) { $existing.Version } else { 'none' })"

    Write-Log "Reading the Edge release feed ($Channel channel)..."
    $releases = Get-EdgeReleases
    Write-Log "Feed: $(($releases.Keys | Sort-Object | ForEach-Object { "$_ $($releases[$_].Version)" }) -join ', ')"

    $files = [ordered]@{}
    if ($existing -and $existing.Files) { foreach ($p in $existing.Files.PSObject.Properties) { if ($Architectures -contains $p.Name) { $files[$p.Name] = $p.Value } } }
    $changed = $false

    foreach ($arch in $Architectures) {
        $rel = $releases[$arch]
        if (-not $rel) { Write-Log "  $arch : no Stable MSI in the feed." 'WARN'; continue }
        try {
            $prev = $files[$arch]
            if (-not $Force -and $prev -and $prev.Version -eq $rel.Version -and (Test-Path -LiteralPath (Join-Path $DestinationPath $prev.FileName))) {
                Write-Log "  $arch : Edge $($rel.Version) already on the share."
                continue
            }
            if ($prev -and (ConvertTo-Version $rel.Version) -lt (ConvertTo-Version $prev.Version) -and -not $Force) {
                Write-Log "  $arch : the feed's $($rel.Version) is older than the share's $($prev.Version). Not publishing." 'WARN'
                continue
            }
            if (-not $rel.Sha256) { throw 'the feed gives no SHA-256 for this MSI.' }

            $local = Join-Path $tempDir $rel.Name
            Write-Log ("  {0} : downloading Edge {1} ({2:N0} MB)" -f $arch, $rel.Version, ($rel.Size / 1MB))
            Save-Download -Url $rel.Url -OutFile $local
            $hash = (Get-FileHash -LiteralPath $local -Algorithm SHA256).Hash
            if ($hash -ne $rel.Sha256) { throw "SHA-256 mismatch. Feed: $($rel.Sha256)  Downloaded: $hash" }
            $sig = Get-AuthenticodeSignature -FilePath $local
            if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch $SignerPattern) {
                throw "signature check failed (status: $($sig.Status), signer: $($sig.SignerCertificate.Subject))."
            }

            $verDir = Join-Path $DestinationPath $rel.Version
            New-Item -ItemType Directory -Path $verDir -Force | Out-Null
            $final = Join-Path $verDir $rel.Name
            Copy-Item -LiteralPath $local -Destination "$final.partial" -Force
            Move-Item -LiteralPath "$final.partial" -Destination $final -Force
            $files[$arch] = [ordered]@{
                FileName    = Join-Path $rel.Version $rel.Name
                Version     = $rel.Version
                Sha256      = $hash
                PublishedAt = $rel.Published
                SourceUrl   = $rel.Url
            }
            $changed = $true
            Write-Log "  $arch : published $($rel.Name) (Edge $($rel.Version)); SHA-256 matches the feed; signed by $($sig.SignerCertificate.Subject)."
        }
        catch { Write-Log "  $arch failed: $(Get-ErrorDetail $_). Keeping what's on the share." 'WARN' }
    }
    if ($files.Count -eq 0) { throw 'No Edge installers are available.' }

    if ($changed -or -not $existing) {
        $top = $files.Values | ForEach-Object { $_.Version } | Sort-Object { ConvertTo-Version $_ } -Descending | Select-Object -First 1
        $manifest = [ordered]@{
            Product   = 'Microsoft Edge for Business (Enterprise MSI, machine-wide)'
            Channel   = $Channel
            Version   = $top
            UpdatedAt = (Get-Date).ToString('o')
            Files     = $files
        }
        $tmp = "$manifestPath.tmp"
        $manifest | ConvertTo-Json -Depth 5 | Set-Content -Path $tmp -Encoding UTF8
        Move-Item -Path $tmp -Destination $manifestPath -Force
        Write-Log "Manifest updated: $(($files.Keys | ForEach-Object { "$_ $($files[$_].Version)" }) -join ', ')."
    }
    else { Write-Log 'Nothing changed.' }

    # --- Prune old version folders (never ones in use) -------------------------
    $inUse = @($files.Values | ForEach-Object { Split-Path $_.FileName -Parent } | Sort-Object -Unique)
    Get-ChildItem -Path $DestinationPath -Directory |
        Where-Object { $_.Name -match '^\d+(\.\d+){3}$' -and $inUse -notcontains $_.Name } |
        Sort-Object { ConvertTo-Version $_.Name } -Descending |
        Select-Object -Skip ([math]::Max(0, $KeepVersions - $inUse.Count)) |
        ForEach-Object { Write-Log "Removing old version folder $($_.Name)"; Remove-Item $_.FullName -Recurse -Force }

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
            Invoke-OTTOIntunePackageBuild -AppId 'Edge' -DestinationPath $DestinationPath -OutputPath $IntuneOutputPath `
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
            Update-OTTOCatalogEntry -AppId 'Edge' -DestinationPath $DestinationPath -ManifestBefore $script:ManifestBefore `
                -Failed ([bool]($script:SyncFailed -or $script:IntuneFailed)) -Script 'Sync\Edge.ps1' `
                -BoundParameters $PSBoundParameters -CatalogPath $CatalogPath -Definition $OTTOAppDefinition -ScriptPath $PSCommandPath -Log { param($m, $l) Write-Log $m $l }
        }
        catch { Write-Log "Couldn't update the repo catalog: $($_.Exception.Message)" 'WARN' }
    }
    # Release the one-sync-per-share lock (it would otherwise stay held until this PowerShell
    # window closes, so a second run in the same window would think a sync is still running)
    if ($script:SyncLock) { $script:SyncLock.Dispose(); $script:SyncLock = $null }
    if ($script:IntuneFailed) { exit 1 }
}
