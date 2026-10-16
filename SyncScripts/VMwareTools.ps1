<#
.SYNOPSIS
    SERVER SCRIPT - Keeps a network share stocked with the latest VMware Tools for Windows
    installer, checked against Broadcom's (VMware's) code signature.

.DESCRIPTION
    - Finds the newest release in the public VMware Tools repository:
        https://packages-prod.broadcom.com/tools/releases/latest/windows/<x64|arm64>/
      (formerly packages.vmware.com), e.g. VMware-tools-13.1.5-25544008-x64.exe, or the
      release given with -Version (https://.../tools/releases/<version>/windows/...).
    - If the share already has that version and build, it stops.
    - Otherwise downloads the installer for each architecture, checks its Authenticode
      signature (Broadcom / VMware - the repository publishes no checksums, so the
      signature is the check) and publishes it to <DestinationPath>\<version>.<build>\ with
      its SHA-256 in latest.json, which the clients check before installing.
    - Writes latest.json last. Keeps the newest -KeepVersions version folders.

    VMware Tools 13 supports 64-bit Windows only (x64, and ARM64 for Windows 11 on Arm);
    there's no 32-bit build.

    Folder layout:
        <DestinationPath>\13.1.5.25544008\VMware-tools-13.1.5-25544008-x64.exe
        <DestinationPath>\latest.json
        <DestinationPath>\Logs\Sync-VMwareToolsRepo.log

.PARAMETER DestinationPath
    Folder (local path or UNC) where the installers are stored.
    Optional: if it's left out, the folder comes from the repo catalog
    (OTTOUpdate-Catalog.json): this app's Folder there (its full path), or
    <RepoRoot>\Applications\VMwareTools if the app isn't in the catalog yet. The catalog is found
    automatically when this script runs from <RepoRoot>\Administrative\Sync;
    otherwise pass -CatalogPath.

.PARAMETER CatalogPath
    The repo catalog to take the folder from when -DestinationPath isn't given, e.g.
    \\fileserver\Software\OTTOUpdate-Catalog.json. Default: <RepoRoot>\OTTOUpdate-Catalog.json
    when this script is in <RepoRoot>\Administrative\Sync.

.PARAMETER Architectures
    Which builds to keep: x64 and/or arm64. Default: x64. Add arm64 only if you run
    Windows 11 on Arm virtual machines.

.PARAMETER Version
    Keep a specific release instead of the newest, e.g. 13.1.5 (a folder name under
    .../tools/releases/). Useful to match what your ESXi hosts ship, or to hold back.

.PARAMETER BaseUrl
    The repository's releases folder. Default:
    https://packages-prod.broadcom.com/tools/releases (packages.vmware.com/tools/releases
    is the old address of the same files).

.PARAMETER KeepVersions
    How many version folders to keep. Default: 2.

.PARAMETER Proxy
    Proxy server for internet access, e.g. http://proxy.contoso.local:8080.

.PARAMETER ProxyUseDefaultCredentials
    Authenticate to the proxy as the account running the script.

.PARAMETER PageTimeoutSec
    Seconds to wait for a web page / for a download to start. Default: 60.

.PARAMETER StallTimeoutSec
    Give up on a download if no data arrives for this many seconds. Default: 120.

.PARAMETER Force
    Download and republish even if the share already has this version.

.PARAMETER BuildIntunePackage
    After a successful sync, also build a Microsoft Intune Win32 app package from what is
    on the share: <IntuneOutputPath>\VMwareTools\<version>\ gets VMwareTools-<version>.intunewin,
    Detect-VMwareTools.ps1 (custom detection script) and README-VMwareTools.txt (the
    install/uninstall commands, return codes and detection settings to enter in Intune).
    Nothing is rebuilt if that version's package already exists (unless -Force). Needs <RepoRoot>\Administrative\Shared\OTTOUpdate-Common.ps1 and the app's client script (catalog ClientScript, normally Apps\VMwareTools.ps1).

.PARAMETER IntuneOutputPath
    Where Intune packages are written. Default: <DestinationPath>\Intune

.PARAMETER ClientScriptPath
    Client script to put in the package. Default: the app's client script from the catalog (Apps\VMwareTools.ps1 under <RepoRoot>\Administrative).

.PARAMETER IntuneWinAppUtilPath
    Path to IntuneWinAppUtil.exe (Microsoft Win32 Content Prep Tool). Default: the repo's
    shared copy, <RepoRoot>\Tools\IntuneWinAppUtil.exe (<RepoRoot> = the parent of
    -DestinationPath), which Update-IntuneWinAppUtil.ps1 downloads if it's missing.

.EXAMPLE
    .\Sync\VMwareTools.ps1 -DestinationPath '\\fileserver\Software\Applications\VMwareTools'

.EXAMPLE
    # A specific release
    .\Sync\VMwareTools.ps1 -DestinationPath '\\fileserver\Software\Applications\VMwareTools' -Version 13.1.5

.EXAMPLE
    # Sync, then build the Intune package (.intunewin + detection script + README)
    .\Sync\VMwareTools.ps1 -DestinationPath '\\fileserver\Software\Applications\VMwareTools' -BuildIntunePackage
#>
[CmdletBinding()]
param(
    [string]$DestinationPath,

    [string]$CatalogPath,

    [ValidateSet('x64', 'arm64')]
    [string[]]$Architectures = @('x64'),

    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string]$Version,

    [string]$BaseUrl = 'https://packages-prod.broadcom.com/tools/releases',

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
    AppId        = 'VMwareTools'
    Name         = 'VMware Tools'
    SyncScript   = 'Sync\VMwareTools.ps1'
    ClientScript = 'Apps\VMwareTools.ps1'
    Intune       = @{
        # Install command arguments after the script name. '-SourcePath .' becomes the repo path
        # plus the package's own copy as the fallback.
        InstallCommand  = '-SourcePath . -Install'
        InstallVariants = @(
            '-SourcePath . -Install -MsiProperties ADDLOCAL=ALL   (new installs get every component, the "Complete" setup type)',
            '-SourcePath .   (update existing installs only)'
        )
        # The app's Programs and Features entries (regular expressions), for detection logging and uninstall
        Match           = @{ Pattern = '^VMware Tools$'; Exclude = ''; KeyPattern = ''; Exe = 'VMware\VMware Tools\vmtoolsd.exe' }
        Detection       = @{
            # How it's detected, as written in Detect.log. Empty = the built-in check of the
            # Programs and Features entry (Match.Pattern) and, if newer, Match.Exe's file version
            Description     = 'Programs and Features entry "VMware Tools", or the file version of vmtoolsd.exe if newer (VMware virtual machines only)'
            # Several versions side by side, each compared with its own repo version ($Required)
            SeveralVersions = $false
            # What $Required is when the detection script's $Required line is left at $null
            DefaultRequired = '@()'
            # Runs before the repo is read; may Pass or Fail straight away
            PreCheck        = @'
# Only VMware virtual machines need VMware Tools: anything else counts as "detected"
$cs = Get-CimInstance Win32_ComputerSystem; $bios = Get-CimInstance Win32_BIOS
Note "Hardware: $($cs.Manufacturer) $($cs.Model) (BIOS $($bios.Manufacturer), serial $($bios.SerialNumber))"
if ("$($cs.Manufacturer) $($cs.Model) $($bios.Manufacturer) $($bios.SerialNumber)" -notmatch 'VMware') {
    Pass "this computer isn't a VMware virtual machine ($($cs.Manufacturer) $($cs.Model)), so VMware Tools doesn't apply"
}
'@
            # Sets $have when the repo can't be read. Empty = the Programs and Features check
            Offline         = ''
            # The check: compares what's installed with $Manifest (the repo's latest.json) and
            # ends with Test-Current / Test-CurrentSet. Empty = the built-in check
            Code            = @'
$best = Get-Uninstall | Where-Object { $_.Name -match $App.Pattern } | Sort-Object Version -Descending | Select-Object -First 1
$have = $best.VersionText
$exeVer = @((Get-PF64), (Get-PF86)) | Where-Object { $_ } | ForEach-Object { Get-FileVer (Join-Path $_ $App.Exe) } |
          Where-Object { $_ } | Sort-Object -Descending | Select-Object -First 1
if ($exeVer -and (-not $have -or $exeVer -gt (ConvertTo-Version $have))) { $have = "$exeVer" }
Test-Current $AppName $have (Select-ArchEntry $Manifest.Files).Version
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
                    "Pass -DestinationPath <share>\VMwareTools, or -CatalogPath <RepoRoot>\OTTOUpdate-Catalog.json " +
                    "(found automatically when this script runs from <RepoRoot>\Administrative\Sync).") -ForegroundColor Red
        exit 1
    }
    try { $catalogData = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $CatalogPath).ProviderPath) | ConvertFrom-Json }
    catch { Write-Host "The repo catalog $CatalogPath can't be read: $($_.Exception.Message). Pass -DestinationPath instead." -ForegroundColor Red; exit 1 }
    $catalogEntry = @($catalogData.Apps) | Where-Object { $_ -and [string]$_.AppId -eq 'VMwareTools' } | Select-Object -First 1
    $catalogFolder = if ($catalogEntry -and $catalogEntry.Folder) { [string]$catalogEntry.Folder } else { 'Applications\VMwareTools' }
    # Folder is the app's full path (e.g. \\fileserver\Software\Applications\Chrome); older catalogs hold a name under the repo root
    $DestinationPath = if ($catalogFolder -match '^\\\\' -or [IO.Path]::IsPathRooted($catalogFolder)) { $catalogFolder }
                       else { Join-Path (Split-Path (Resolve-Path -LiteralPath $CatalogPath).ProviderPath -Parent) $catalogFolder }
    Write-Host ("-DestinationPath from the repo catalog: $DestinationPath" + $(if (-not $catalogEntry) { " (VMware Tools isn't in the catalog yet; it's added after this sync writes latest.json)" }))
}

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
try   { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13 }
catch { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 }

$ArchDir       = @{ x64 = 'x64'; arm64 = 'arm64' }
$ArchSuffix    = @{ x64 = 'x64|x86_64'; arm64 = 'arm64|aarch64' }   # file name endings VMware has used
$SignerPattern = 'Broadcom|VMware'
$UserAgent     = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Sync-VMwareToolsRepo.ps1'

if ($Proxy) {
    $PSDefaultParameterValues['Invoke-WebRequest:Proxy'] = $Proxy
    if ($ProxyUseDefaultCredentials) { $PSDefaultParameterValues['Invoke-WebRequest:ProxyUseDefaultCredentials'] = $true }
}

# --- Helpers -----------------------------------------------------------------
if (-not (Test-Path $DestinationPath)) { New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null }
$logDir = Join-Path $DestinationPath 'Logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$LogFile = Join-Path $logDir 'Sync-VMwareToolsRepo.log'

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

function Get-Page([string]$Url) {
    Write-Log "Reading $Url"
    $content = (Invoke-WebRequest -Uri $Url -UseBasicParsing -UserAgent $UserAgent -TimeoutSec $PageTimeoutSec).Content
    if ($content -is [byte[]]) { return [Text.Encoding]::UTF8.GetString($content) }
    return [string]$content
}

function Save-Download([string]$Url, [string]$OutFile) {
    # Streams a file to disk, logging progress every 30 s; gives up if no data arrives
    # for $StallTimeoutSec, so a stuck transfer can't hang the script.
    Add-Type -AssemblyName System.Net.Http
    $handler = New-Object System.Net.Http.HttpClientHandler
    if ($Proxy) {
        $wp = New-Object System.Net.WebProxy($Proxy)
        $wp.UseDefaultCredentials = [bool]$ProxyUseDefaultCredentials
        $handler.Proxy = $wp
        $handler.UseProxy = $true
    }
    $client = New-Object System.Net.Http.HttpClient($handler)
    $client.Timeout = [System.Threading.Timeout]::InfiniteTimeSpan
    [void]$client.DefaultRequestHeaders.TryAddWithoutValidation('User-Agent', $UserAgent)

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
                $rate = ($done / 1MB) / [math]::Max(1, ((Get-Date) - $start).TotalSeconds)
                if ($total) { Write-Log ("  {0:N0} of {1:N0} MB ({2:N0}%), {3:N1} MB/s" -f ($done / 1MB), ($total / 1MB), (100 * $done / $total), $rate) }
                else        { Write-Log ("  {0:N0} MB, {1:N1} MB/s" -f ($done / 1MB), $rate) }
                $nextLog = (Get-Date).AddSeconds(30)
            }
        }
        if ($total -and $done -ne $total) { throw ("Download incomplete: got {0:N0} of {1:N0} bytes." -f $done, $total) }
        Write-Log ("  finished: {0:N1} MB in {1:N0} s" -f ($done / 1MB), ((Get-Date) - $start).TotalSeconds)
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

# --- Main --------------------------------------------------------------------
function Find-Installer([string]$ReleaseUrl, [string]$Arch) {
    # The newest VMware-tools-<version>-<build>-<arch>.exe in a release's windows/<arch>/ folder
    $page = "$ReleaseUrl/windows/$($ArchDir[$Arch])/"
    try { $html = Get-Page $page }
    catch { Write-Log "  $Arch : can't read $page ($(Get-ErrorDetail $_))." 'WARN'; return $null }
    $rx = 'VMware-tools-(\d+\.\d+\.\d+)-(\d+)-(' + $ArchSuffix[$Arch] + ')\.exe'
    $hits = [regex]::Matches($html, $rx) | ForEach-Object {
        [pscustomobject]@{
            Name    = $_.Value
            Release = $_.Groups[1].Value
            Build   = $_.Groups[2].Value
            Version = "$($_.Groups[1].Value).$($_.Groups[2].Value)"
            Url     = $page + $_.Value
        }
    } | Sort-Object { [version]$_.Version } -Descending
    if (-not $hits) { Write-Log "  $Arch : no VMware Tools installer listed in $page." 'WARN'; return $null }
    return @($hits)[0]
}

$tempDir = Join-Path $env:TEMP "vmwaretools-sync-$([guid]::NewGuid().ToString('N'))"
try {
    # latest.json as it was before this run, for the repo catalog (see the end of the script)
    $script:ManifestBefore = $null
    try {
        $manifestBeforePath = Join-Path $DestinationPath 'latest.json'
        if (Test-Path -LiteralPath $manifestBeforePath) { $script:ManifestBefore = Get-Content -LiteralPath $manifestBeforePath -Raw }
    }
    catch { }
    Write-Log "---- Sync started. Destination: $DestinationPath  Architectures: $($Architectures -join ', ')$(if ($Version) { "  Version: $Version" })"
    New-Item -ItemType Directory -Path $tempDir | Out-Null

    $manifestPath = Join-Path $DestinationPath 'latest.json'
    $existing = $null
    if (Test-Path $manifestPath) {
        try { $existing = Get-Content $manifestPath -Raw | ConvertFrom-Json }
        catch { Write-Log "Existing manifest is unreadable and will be replaced: $_" 'WARN' }
    }
    Write-Log "Version on share: $(if ($existing) { $existing.Version } else { 'none' })"

    # --- Latest (or requested) release ----------------------------------------
    $base = $BaseUrl.TrimEnd('/')
    $releaseUrl = if ($Version) { "$base/$Version" } else { "$base/latest" }
    $found = [ordered]@{}
    foreach ($a in $Architectures) {
        $f = Find-Installer $releaseUrl $a
        if ($f) { $found[$a] = $f; Write-Log "  $a : $($f.Name)" }
    }
    if ($found.Count -eq 0 -and -not $PSBoundParameters.ContainsKey('BaseUrl')) {
        # The repository's old address serves the same files
        $releaseUrl = $releaseUrl -replace '^https://packages-prod\.broadcom\.com/', 'https://packages.vmware.com/'
        Write-Log "Nothing found; trying the repository's old address, $releaseUrl" 'WARN'
        foreach ($a in $Architectures) {
            $f = Find-Installer $releaseUrl $a
            if ($f) { $found[$a] = $f; Write-Log "  $a : $($f.Name)" }
        }
    }
    if ($found.Count -eq 0) { throw "No VMware Tools installers found under $releaseUrl/windows/ (check -Version / -BaseUrl, or the proxy)." }
    $newest = @($found.Values | Sort-Object { [version]$_.Version } -Descending)[0]
    foreach ($a in @($found.Keys)) {
        if ($found[$a].Version -ne $newest.Version) {
            Write-Log "  $a : only $($found[$a].Version) is listed, not $($newest.Version); leaving $a out." 'WARN'
            $found.Remove($a)
        }
    }
    $release = $newest.Version          # e.g. 13.1.5.25544008
    Write-Log "VMware Tools $(if ($Version) { $Version } else { 'latest' }): $($newest.Release) build $($newest.Build)"

    # --- Anything new? -------------------------------------------------------
    if ($existing -and -not $Force -and $existing.Version -eq $release) {
        $allPresent = $true
        foreach ($a in $found.Keys) {
            $e = $existing.Files.$a
            if (-not $e -or -not (Test-Path -LiteralPath (Join-Path $DestinationPath $e.FileName))) { $allPresent = $false }
        }
        if ($allPresent) {
            Write-Log 'Share already has this version. Nothing to do.'
            exit 0
        }
    }

    # --- Download and verify -------------------------------------------------
    $got = [ordered]@{}
    foreach ($a in $found.Keys) {
        $f = $found[$a]
        $local = Join-Path $tempDir $f.Name
        Write-Log "Downloading $a : $($f.Url)"
        try { Save-Download -Url $f.Url -OutFile $local }
        catch { Write-Log "  failed: $(Get-ErrorDetail $_); skipping $a." 'WARN'; continue }
        $sig = Get-AuthenticodeSignature -FilePath $local
        if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch $SignerPattern) {
            throw "Signature check failed for $a (status: $($sig.Status), signer: $($sig.SignerCertificate.Subject))."
        }
        $hash = (Get-FileHash -LiteralPath $local -Algorithm SHA256).Hash
        Write-Log "  $a : signed by $($sig.SignerCertificate.Subject); SHA-256 $hash"
        $got[$a] = @{ Path = $local; Name = $f.Name; Hash = $hash; Url = $f.Url }
    }
    if ($got.Count -eq 0) { throw 'No installers were downloaded.' }

    # --- Publish -------------------------------------------------------------
    $verFolder = Join-Path $DestinationPath $release
    $staging   = "$verFolder.partial"
    if (Test-Path $staging) { Remove-Item $staging -Recurse -Force }
    New-Item -ItemType Directory -Path $staging | Out-Null
    $files = [ordered]@{}
    foreach ($a in $got.Keys) {
        Copy-Item -LiteralPath $got[$a].Path -Destination (Join-Path $staging $got[$a].Name)
        $files[$a] = [ordered]@{ FileName = Join-Path $release $got[$a].Name; Sha256 = $got[$a].Hash; Version = $release; SourceUrl = $got[$a].Url }
    }
    if (Test-Path $verFolder) { Remove-Item $verFolder -Recurse -Force }
    Rename-Item -Path $staging -NewName $release

    $manifest = [ordered]@{
        Product   = 'VMware Tools'
        Release   = $newest.Release                          # e.g. 13.1.5
        Build     = $newest.Build                            # e.g. 25544008
        Version   = $release                                 # 13.1.5.25544008 - matches Programs and Features
        UpdatedAt = (Get-Date).ToString('o')
        Files     = $files
    }
    $tmp = "$manifestPath.tmp"
    $manifest | ConvertTo-Json -Depth 5 | Set-Content -Path $tmp -Encoding UTF8
    Move-Item -Path $tmp -Destination $manifestPath -Force
    Write-Log "Published VMware Tools $release ($($files.Keys -join ', ')) and updated manifest."

    # --- Prune old versions --------------------------------------------------
    Get-ChildItem -Path $DestinationPath -Directory |
        Where-Object { $_.Name -match '^\d+(\.\d+){1,3}$' } |
        Sort-Object { [version]$_.Name } -Descending |
        Select-Object -Skip $KeepVersions |
        ForEach-Object { Write-Log "Removing old version folder $($_.Name)"; Remove-Item $_.FullName -Recurse -Force }
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
            Invoke-OTTOIntunePackageBuild -AppId 'VMwareTools' -DestinationPath $DestinationPath -OutputPath $IntuneOutputPath `
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
            Update-OTTOCatalogEntry -AppId 'VMwareTools' -DestinationPath $DestinationPath -ManifestBefore $script:ManifestBefore `
                -Failed ([bool]($script:SyncFailed -or $script:IntuneFailed)) -Script 'Sync\VMwareTools.ps1' `
                -BoundParameters $PSBoundParameters -CatalogPath $CatalogPath -Definition $OTTOAppDefinition -ScriptPath $PSCommandPath -Log { param($m, $l) Write-Log $m $l }
        }
        catch { Write-Log "Couldn't update the repo catalog: $($_.Exception.Message)" 'WARN' }
    }
    # Release the one-sync-per-share lock (it would otherwise stay held until this PowerShell
    # window closes, so a second run in the same window would think a sync is still running)
    if ($script:SyncLock) { $script:SyncLock.Dispose(); $script:SyncLock = $null }
    if ($script:IntuneFailed) { exit 1 }
}
