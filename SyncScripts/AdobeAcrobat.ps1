<#
.SYNOPSIS
    SERVER SCRIPT - Keeps a network share stocked with the latest Adobe Acrobat (Pro) and
    Acrobat Reader updates (DC / Continuous track).

.DESCRIPTION
    Adobe updates Acrobat and Reader with cumulative .msp patch files that update the
    installed product in place. This script:
    - Reads Adobe's Acrobat release notes index and finds the newest Continuous-track
      update (e.g. "26.002.21931 Out of cycle update").
    - If the share already has that version, it stops.
    - Otherwise it opens that update's release notes page and downloads the .msp files
      listed there for each package you want (see -Packages), e.g.:
          acrobat-x64     AcrobatDCx64Upd<ver>.msp      Acrobat Pro 64-bit
          acrobat-x86     AcrobatDCUpd<ver>.msp         Acrobat Pro 32-bit
          reader-x64      AcroRdrDCx64Upd<ver>.msp      Reader 64-bit
          reader-x64-mui  AcroRdrDCx64Upd<ver>_MUI.msp  Reader 64-bit, multi-language
          reader-x86      AcroRdrDCUpd<ver>.msp         Reader 32-bit
          reader-x86-mui  AcroRdrDCUpd<ver>_MUI.msp     Reader 32-bit, multi-language
    - Checks each file's Authenticode signature (Adobe), and reads from the patch itself
      which installed products it applies to (its target ProductCodes). The client uses
      that list to pick the right patch for whatever is installed.
    - Writes latest.json last, and keeps the newest -KeepVersions version folders.

    The patches are large (roughly 0.5-1 GB each), so only download the packages your
    machines actually need.

    Folder layout:
        <DestinationPath>\26.002.21931\AcrobatDCx64Upd2600221931.msp  (etc.)
        <DestinationPath>\latest.json
        <DestinationPath>\Logs\Sync-AdobeAcrobatRepo.log

    Must run on Windows (it reads the patch details with the Windows Installer COM object).

.PARAMETER DestinationPath
    Folder (local path or UNC) where the updates are stored.
    Optional: if it's left out, the folder comes from the repo catalog
    (OTTOUpdate-Catalog.json): this app's Folder there (its full path), or
    <RepoRoot>\Applications\AdobeAcrobat if the app isn't in the catalog yet. The catalog is found
    automatically when this script runs from <RepoRoot>\Administrative\Sync;
    otherwise pass -CatalogPath.

.PARAMETER CatalogPath
    The repo catalog to take the folder from when -DestinationPath isn't given, e.g.
    \\fileserver\Software\OTTOUpdate-Catalog.json. Default: <RepoRoot>\OTTOUpdate-Catalog.json
    when this script is in <RepoRoot>\Administrative\Sync.

.PARAMETER Packages
    Which update packages to keep. Default: all six.

.PARAMETER Installers
    Full installers to keep on the share so clients can do NEW installs (the client's
    -Install switch). Default: reader-x64, acrobat-x64. Options:
        reader-x64 / reader-x86   Adobe's full offline Reader installer for the current
                                  release (AcroRdrDC[x64]<ver>_<lang>.exe). If Adobe hasn't
                                  published one for an out-of-cycle release, the previous
                                  one is kept - the client patches it up after installing.
        acrobat-x64 / acrobat-x86 Adobe's full Acrobat installer
                                  (Acrobat_DC_Web[_x64]_WWMUI.zip from trials.adobe.com),
                                  unpacked. It's an older base version; the client applies
                                  the current update right after installing. Users sign in
                                  with their Adobe ID to license Acrobat Pro.
    Pass an empty list (-Installers @()) to keep update packages only.

.PARAMETER ReaderLanguage
    Language of the full Reader installer: MUI (multi-language, default) or en_US.

.PARAMETER Version
    Optional version (e.g. 26.002.21931) to use instead of detecting the latest.

.PARAMETER KeepVersions
    How many version folders to keep. Default: 2.

.PARAMETER AllowUnsigned
    Accept a patch that isn't validly signed by Adobe (not recommended).

.PARAMETER Proxy
    Proxy server for internet access, e.g. http://proxy.contoso.local:8080.

.PARAMETER ProxyUseDefaultCredentials
    Authenticate to the proxy as the account running the script.

.PARAMETER PageTimeoutSec
    Seconds to wait for a web page, or for a download to start. Default: 60.

.PARAMETER StallTimeoutSec
    Give up on a download if no data arrives for this many seconds. Default: 120.
    Downloads log their progress every 30 seconds.

.PARAMETER Force
    Download and republish even if the share already has this version.

.PARAMETER BuildIntunePackage
    After a successful sync, also build a Microsoft Intune Win32 app package from what is
    on the share: <IntuneOutputPath>\AdobeAcrobat\<version>\ gets AdobeAcrobat-<version>.intunewin,
    Detect-AdobeAcrobat.ps1 (custom detection script) and README-AdobeAcrobat.txt (the install/uninstall
    commands, return codes and detection settings to enter in Intune). Nothing is rebuilt
    if that version's package already exists (unless -Force). Needs <RepoRoot>\Administrative\Shared\OTTOUpdate-Common.ps1 and the app's client script (catalog ClientScript, normally Apps\AdobeAcrobat.ps1).

.PARAMETER IntuneOutputPath
    Where Intune packages are written. Default: <DestinationPath>\Intune

.PARAMETER ClientScriptPath
    Client script to put in the package. Default: the app's client script from the catalog (Apps\AdobeAcrobat.ps1 under <RepoRoot>\Administrative).

.PARAMETER IntuneWinAppUtilPath
    Path to IntuneWinAppUtil.exe (Microsoft Win32 Content Prep Tool). Default: the repo's
    shared copy, <RepoRoot>\Tools\IntuneWinAppUtil.exe (<RepoRoot> = the parent of
    -DestinationPath), which Update-IntuneWinAppUtil.ps1 downloads if it's missing.

.EXAMPLE
    .\Sync\AdobeAcrobat.ps1 -DestinationPath '\\fileserver\Software\Applications\AdobeAcrobat'

.EXAMPLE
    # Only 64-bit Acrobat Pro and 32-bit multi-language Reader
    .\Sync\AdobeAcrobat.ps1 -DestinationPath '\\fileserver\Software\Applications\AdobeAcrobat' -Packages acrobat-x64, reader-x86-mui

.EXAMPLE
    # Sync, then build the Intune package (.intunewin + detection script + README)
    .\Sync\AdobeAcrobat.ps1 -DestinationPath '\\fileserver\Software\Applications\AdobeAcrobat' -BuildIntunePackage
#>
[CmdletBinding()]
param(
    [string]$DestinationPath,

    [string]$CatalogPath,

    [ValidateSet('acrobat-x64', 'acrobat-x86', 'reader-x64', 'reader-x64-mui', 'reader-x86', 'reader-x86-mui')]
    [string[]]$Packages = @('acrobat-x64', 'acrobat-x86', 'reader-x64', 'reader-x64-mui', 'reader-x86', 'reader-x86-mui'),

    # Full installers kept for NEW installs (the client's -Install switch)
    [ValidateSet('reader-x64', 'reader-x86', 'acrobat-x64', 'acrobat-x86')]
    [string[]]$Installers = @('reader-x64', 'acrobat-x64'),

    [ValidateSet('MUI', 'en_US')]
    [string]$ReaderLanguage = 'MUI',

    [ValidatePattern('^\d{2}\.\d{3}\.\d{5}$')]
    [string]$Version,

    [ValidateRange(1, 10)]
    [int]$KeepVersions = 2,

    [switch]$AllowUnsigned,

    [string]$Proxy,

    [switch]$ProxyUseDefaultCredentials,

    # Seconds to wait for a web page / for a download to start
    [ValidateRange(10, 600)]
    [int]$PageTimeoutSec = 60,

    # Give up on a download if no data arrives for this many seconds
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
    AppId        = 'AdobeAcrobat'
    Name         = 'Adobe Acrobat / Acrobat Reader'
    SyncScript   = 'Sync\AdobeAcrobat.ps1'
    ClientScript = 'Apps\AdobeAcrobat.ps1'
    Intune       = @{
        # Install command arguments after the script name. '-SourcePath .' becomes the repo path
        # plus the package's own copy as the fallback.
        InstallCommand  = '-SourcePath . -Install Reader'
        InstallVariants = @(
            '-SourcePath . -Install AcrobatPro',
            '-SourcePath .   (update existing installs only)'
        )
        # The app's Programs and Features entries (regular expressions), for detection logging and uninstall
        Match           = @{ Pattern = 'Acrobat'; Exclude = ''; KeyPattern = '^\{AC76BA86-'; Exe = '' }
        Detection       = @{
            # How it's detected, as written in Detect.log. Empty = the built-in check of the
            # Programs and Features entry (Match.Pattern) and, if newer, Match.Exe's file version
            Description     = 'Programs and Features entry for Acrobat/Reader (Adobe product code)'
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
$best = Get-Uninstall | Where-Object { $_.KeyName -match $App.KeyPattern -and $_.Name -match $App.Pattern } |
        Sort-Object Version -Descending | Select-Object -First 1
Test-Current $(if ($best) { $best.Name } else { 'Acrobat/Reader' }) $best.VersionText $Manifest.Version
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
                    "Pass -DestinationPath <share>\AdobeAcrobat, or -CatalogPath <RepoRoot>\OTTOUpdate-Catalog.json " +
                    "(found automatically when this script runs from <RepoRoot>\Administrative\Sync).") -ForegroundColor Red
        exit 1
    }
    try { $catalogData = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $CatalogPath).ProviderPath) | ConvertFrom-Json }
    catch { Write-Host "The repo catalog $CatalogPath can't be read: $($_.Exception.Message). Pass -DestinationPath instead." -ForegroundColor Red; exit 1 }
    $catalogEntry = @($catalogData.Apps) | Where-Object { $_ -and [string]$_.AppId -eq 'AdobeAcrobat' } | Select-Object -First 1
    $catalogFolder = if ($catalogEntry -and $catalogEntry.Folder) { [string]$catalogEntry.Folder } else { 'Applications\AdobeAcrobat' }
    # Folder is the app's full path (e.g. \\fileserver\Software\Applications\Chrome); older catalogs hold a name under the repo root
    $DestinationPath = if ($catalogFolder -match '^\\\\' -or [IO.Path]::IsPathRooted($catalogFolder)) { $catalogFolder }
                       else { Join-Path (Split-Path (Resolve-Path -LiteralPath $CatalogPath).ProviderPath -Parent) $catalogFolder }
    Write-Host ("-DestinationPath from the repo catalog: $DestinationPath" + $(if (-not $catalogEntry) { " (AdobeAcrobat isn't in the catalog yet; it's added after this sync writes latest.json)" }))
}

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
try   { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13 }
catch { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 }

$IndexUrl      = 'https://www.adobe.com/devnet-docs/acrobatetk/tools/ReleaseNotesDC/index.html'
$SignerPattern = 'Adobe'
# www.adobe.com's bot protection drops connections from requests that don't look like a browser
$UserAgent     = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36 Edg/128.0.0.0'
$BrowserHeaders = @{
    'Accept'          = 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8'
    'Accept-Language' = 'en-US,en;q=0.9'
}
# Fallback version source: Adobe's Reader download service (a different system from www.adobe.com)
$ProductsApiUrl = 'https://rdc.adobe.io/reader/products?lang=mui&site=enterprise&os=Windows%2011&api_key=dc-get-adobereader-cdn'

# Package definitions: file name pattern (<v> = version digits) and friendly names
$PackageInfo = [ordered]@{
    'acrobat-x64'    = @{ File = 'AcrobatDCx64Upd<v>.msp';      Product = 'Acrobat Pro'; Arch = 'x64'; Dir = 'acrobat' }
    'acrobat-x86'    = @{ File = 'AcrobatDCUpd<v>.msp';         Product = 'Acrobat Pro'; Arch = 'x86'; Dir = 'acrobat' }
    'reader-x64'     = @{ File = 'AcroRdrDCx64Upd<v>.msp';      Product = 'Reader';      Arch = 'x64'; Dir = 'acrobat' }
    'reader-x64-mui' = @{ File = 'AcroRdrDCx64Upd<v>_MUI.msp';  Product = 'Reader MUI';  Arch = 'x64'; Dir = 'acrobat' }
    'reader-x86'     = @{ File = 'AcroRdrDCUpd<v>.msp';         Product = 'Reader';      Arch = 'x86'; Dir = 'reader'  }
    'reader-x86-mui' = @{ File = 'AcroRdrDCUpd<v>_MUI.msp';     Product = 'Reader MUI';  Arch = 'x86'; Dir = 'reader'  }
}

if ($Proxy) {
    $PSDefaultParameterValues['Invoke-WebRequest:Proxy'] = $Proxy
    if ($ProxyUseDefaultCredentials) { $PSDefaultParameterValues['Invoke-WebRequest:ProxyUseDefaultCredentials'] = $true }
}

# --- Helpers -----------------------------------------------------------------
if (-not (Test-Path $DestinationPath)) { New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null }
$logDir = Join-Path $DestinationPath 'Logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$LogFile = Join-Path $logDir 'Sync-AdobeAcrobatRepo.log'

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

function Get-Page([string]$Url, [int]$Attempts = 3) {
    Write-Log "Reading $Url"
    for ($n = 1; $n -le $Attempts; $n++) {
        try {
            # Time limit: some bot protection holds connections open instead of refusing them
            $content = (Invoke-WebRequest -Uri $Url -UseBasicParsing -UserAgent $UserAgent -Headers $BrowserHeaders -TimeoutSec $PageTimeoutSec).Content
            if ($content -is [byte[]]) { return [Text.Encoding]::UTF8.GetString($content) }
            return [string]$content
        }
        catch {
            if ($n -eq $Attempts) { throw }
            Write-Log "  attempt $n for $Url failed ($(Get-ErrorDetail $_)); retrying..." 'WARN'
            Start-Sleep -Seconds (5 * $n)
        }
    }
}

function Save-Download([string]$Url, [string]$OutFile) {
    # Streams a large file to disk, logging progress every 30 seconds, and gives up if
    # no data arrives for $StallTimeoutSec (so a stuck transfer can't hang the script).
    Add-Type -AssemblyName System.Net.Http
    $handler = New-Object System.Net.Http.HttpClientHandler
    if ($Proxy) {
        $wp = New-Object System.Net.WebProxy($Proxy)
        $wp.UseDefaultCredentials = [bool]$ProxyUseDefaultCredentials
        $handler.Proxy = $wp
        $handler.UseProxy = $true
    }
    $client = New-Object System.Net.Http.HttpClient($handler)
    $client.Timeout = [System.Threading.Timeout]::InfiniteTimeSpan   # stalls are handled below
    [void]$client.DefaultRequestHeaders.TryAddWithoutValidation('User-Agent', $UserAgent)
    [void]$client.DefaultRequestHeaders.TryAddWithoutValidation('Accept', '*/*')

    $resp = $in = $out = $null
    try {
        $task = $client.GetAsync($Url, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead)
        if (-not $task.Wait([TimeSpan]::FromSeconds($PageTimeoutSec))) { throw "No response from the server within $PageTimeoutSec seconds." }
        $resp = $task.Result
        if (-not $resp.IsSuccessStatusCode) { throw "Server returned $([int]$resp.StatusCode) $($resp.ReasonPhrase)." }

        $total = $resp.Content.Headers.ContentLength
        $in    = $resp.Content.ReadAsStreamAsync().Result
        $out   = [IO.File]::Create($OutFile)
        $buf   = New-Object byte[] (1MB)
        $done  = [long]0
        $start = Get-Date
        $nextLog = $start.AddSeconds(30)
        Write-Log $(if ($total) { "  size: {0:N0} MB" -f ($total / 1MB) } else { '  size: unknown' })

        while ($true) {
            $read = $in.ReadAsync($buf, 0, $buf.Length)
            if (-not $read.Wait([TimeSpan]::FromSeconds($StallTimeoutSec))) {
                throw ("Download stalled: no data for {0} seconds after {1:N0} MB." -f $StallTimeoutSec, ($done / 1MB))
            }
            $n = $read.Result
            if ($n -le 0) { break }
            $out.Write($buf, 0, $n)
            $done += $n
            if ((Get-Date) -ge $nextLog) {
                $secs = [math]::Max(1, ((Get-Date) - $start).TotalSeconds)
                $rate = ($done / 1MB) / $secs
                if ($total) { Write-Log ("  {0:N0} of {1:N0} MB ({2:N0}%), {3:N1} MB/s" -f ($done / 1MB), ($total / 1MB), (100 * $done / $total), $rate) }
                else        { Write-Log ("  {0:N0} MB, {1:N1} MB/s" -f ($done / 1MB), $rate) }
                $nextLog = (Get-Date).AddSeconds(30)
            }
        }
        if ($total -and $done -ne $total) { throw ("Download incomplete: got {0:N0} of {1:N0} bytes." -f $done, $total) }
        Write-Log ("  finished: {0:N0} MB in {1:N0} s" -f ($done / 1MB), ((Get-Date) - $start).TotalSeconds)
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

function Get-RemoteStamp([string]$Url) {
    try {
        $r = Invoke-WebRequest -Uri $Url -Method Head -UseBasicParsing -UserAgent $UserAgent -TimeoutSec $PageTimeoutSec
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

function Test-AdobeSigned([string]$Path) {
    $sig = Get-AuthenticodeSignature -FilePath $Path
    $ok  = $sig.Status -eq 'Valid' -and $sig.SignerCertificate.Subject -match $SignerPattern
    if (-not $ok) {
        $detail = "status: $($sig.Status), signer: $($sig.SignerCertificate.Subject)"
        if ($AllowUnsigned) { Write-Log "$(Split-Path $Path -Leaf) signature check failed ($detail); accepting because -AllowUnsigned was used." 'WARN' }
        else { throw "$(Split-Path $Path -Leaf) signature check failed ($detail)." }
    }
    return $ok
}

function Sync-FullInstallers($Existing, [string]$Release, [string]$Digits) {
    # Keeps Adobe's full installers on the share for new installs.
    # Returns @{ Out = [ordered] manifest entries; Changed = $true/$false }
    $out = [ordered]@{}
    if ($Existing -and $Existing.Installers) {
        foreach ($p in $Existing.Installers.PSObject.Properties) { $out[$p.Name] = $p.Value }
    }
    $changed = $false
    $instRoot = Join-Path $DestinationPath 'Installers'

    foreach ($key in $Installers) {
        $prev = $out[$key]
        $keyDir = Join-Path $instRoot $key
        try {
            if ($key -like 'reader-*') {
                # --- Full Reader installer for this release ----------------------
                $isX64 = $key -eq 'reader-x64'
                $file  = if ($isX64) { "AcroRdrDCx64$($Digits)_$ReaderLanguage.exe" } else { "AcroRdrDC$($Digits)_$ReaderLanguage.exe" }
                $dir   = if ($isX64) { 'acrobat' } else { 'reader' }
                if (-not $Force -and $prev -and $prev.Version -eq $Release -and $prev.Language -eq $ReaderLanguage -and
                    (Test-Path -LiteralPath (Join-Path $DestinationPath $prev.FileName))) {
                    Write-Log "Installer $key : already have $Release."
                    continue
                }
                $local = Join-Path $tempDir $file
                $ok = $false
                foreach ($h in 'ardownload3.adobe.com', 'ardownload2.adobe.com') {
                    $url = "https://$h/pub/adobe/$dir/win/AcrobatDC/$Digits/$file"
                    try { Write-Log "Downloading full installer $url"; Save-Download -Url $url -OutFile $local; $ok = $true; break }
                    catch { Write-Log "  failed: $(Get-ErrorDetail $_)" 'WARN' }
                }
                if (-not $ok) {
                    Write-Log "Installer $key : Adobe has no full installer for $Release (normal for some out-of-cycle releases). Keeping $(if ($prev) { $prev.Version } else { 'none' }); clients patch it up after installing." 'WARN'
                    continue
                }
                $signed = Test-AdobeSigned $local
                $verDir = Join-Path $keyDir $Release
                New-Item -ItemType Directory -Path $verDir -Force | Out-Null
                Copy-Item -LiteralPath $local -Destination (Join-Path $verDir "$file.partial") -Force
                Move-Item -LiteralPath (Join-Path $verDir "$file.partial") -Destination (Join-Path $verDir $file) -Force
                $out[$key] = [ordered]@{
                    Type     = 'exe'
                    Product  = 'Reader'
                    Arch     = if ($isX64) { 'x64' } else { 'x86' }
                    Language = $ReaderLanguage
                    Version  = $Release
                    FileName = Join-Path 'Installers' (Join-Path $key (Join-Path $Release $file))
                    Sha256   = (Get-FileHash -LiteralPath $local -Algorithm SHA256).Hash
                    Signed   = $signed
                }
                $changed = $true
                Write-Log "Installer $key : published Reader $Release ($ReaderLanguage)."
            }
            else {
                # --- Full Acrobat installer (zip from trials.adobe.com) ----------
                $isX64 = $key -eq 'acrobat-x64'
                $url   = if ($isX64) { 'https://trials.adobe.com/AdobeProducts/APRO/Acrobat_HelpX/win32/Acrobat_DC_Web_x64_WWMUI.zip' }
                         else        { 'https://trials.adobe.com/AdobeProducts/APRO/Acrobat_HelpX/win32/Acrobat_DC_Web_WWMUI.zip' }
                $stamp = Get-RemoteStamp $url
                if (-not $Force -and $prev -and $stamp -and $prev.SourceStamp -eq $stamp -and
                    (Test-Path -LiteralPath (Join-Path $DestinationPath $prev.SetupPath))) {
                    Write-Log "Installer $key : unchanged (base version $($prev.Version))."
                    continue
                }
                $zip = Join-Path $tempDir "$key.zip"
                Write-Log "Downloading full Acrobat installer $url (large)"
                Save-Download -Url $url -OutFile $zip
                $extract = Join-Path $tempDir "$key-extract"
                Add-Type -AssemblyName System.IO.Compression.FileSystem
                [IO.Compression.ZipFile]::ExtractToDirectory($zip, $extract)
                Remove-Item -LiteralPath $zip -Force

                # The setup.exe that sits next to AcroPro.msi
                $msi = Get-ChildItem -LiteralPath $extract -Recurse -Filter 'AcroPro.msi' -File | Select-Object -First 1
                if (-not $msi) { throw "AcroPro.msi not found in the Acrobat download." }
                $setup = Join-Path $msi.DirectoryName 'setup.exe'
                if (-not (Test-Path -LiteralPath $setup)) { throw "setup.exe not found next to AcroPro.msi." }
                $signed = Test-AdobeSigned $setup
                $baseVer = Get-MsiProperty $msi.FullName 'ProductVersion'
                Write-Log "Installer $key : Acrobat base version $baseVer"

                # Publish the folder that contains setup.exe
                $verDir  = Join-Path $keyDir $baseVer
                $staging = "$verDir.partial"
                if (-not (Test-Path $keyDir)) { New-Item -ItemType Directory -Path $keyDir -Force | Out-Null }
                if (Test-Path $staging) { Remove-Item $staging -Recurse -Force }
                Copy-Item -LiteralPath $msi.DirectoryName -Destination $staging -Recurse
                if (Test-Path $verDir) { Remove-Item $verDir -Recurse -Force }
                Rename-Item -Path $staging -NewName $baseVer
                Remove-Item -LiteralPath $extract -Recurse -Force -ErrorAction SilentlyContinue

                $pubFiles = @(Get-ChildItem -LiteralPath $verDir -Recurse -File)
                $out[$key] = [ordered]@{
                    Type        = 'folder'
                    Product     = 'Acrobat Pro'
                    Arch        = if ($isX64) { 'x64' } else { 'x86' }
                    Version     = $baseVer
                    Folder      = Join-Path 'Installers' (Join-Path $key $baseVer)
                    SetupPath   = Join-Path 'Installers' (Join-Path $key (Join-Path $baseVer 'setup.exe'))
                    SetupSha256 = (Get-FileHash -LiteralPath (Join-Path $verDir 'setup.exe') -Algorithm SHA256).Hash
                    FileCount   = $pubFiles.Count
                    TotalBytes  = ($pubFiles | Measure-Object Length -Sum).Sum
                    Signed      = $signed
                    SourceStamp = $stamp
                }
                $changed = $true
                Write-Log ("Installer {0} : published Acrobat base {1} ({2} files, {3:N0} MB)." -f $key, $baseVer, $pubFiles.Count, ($out[$key].TotalBytes / 1MB))
            }

            # Keep only the version folder now in use for this installer
            $inUse = Split-Path (Split-Path $(if ($out[$key].SetupPath) { $out[$key].SetupPath } else { $out[$key].FileName }) -Parent) -Leaf
            Get-ChildItem -LiteralPath $keyDir -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -ne $inUse } |
                ForEach-Object { Write-Log "Installer $key : removing old folder $($_.Name)"; Remove-Item $_.FullName -Recurse -Force }
        }
        catch {
            Write-Log "Installer $key failed: $(Get-ErrorDetail $_). Keeping what's on the share." 'WARN'
        }
    }
    return @{ Out = $out; Changed = $changed }
}

function Get-PatchTargets([string]$Path) {
    # A patch's summary information "Template" field (property 7) lists the ProductCodes it can update
    $installer = New-Object -ComObject WindowsInstaller.Installer
    $si = $null
    try {
        $si = $installer.GetType().InvokeMember('SummaryInformation', 'GetProperty', $null, $installer, @($Path, 0))
        $template = [string]$si.GetType().InvokeMember('Property', 'GetProperty', $null, $si, 7)
        return @($template -split ';' | ForEach-Object { $_.Trim().ToUpper() } | Where-Object { $_ -match '^\{[0-9A-F\-]{36}\}$' })
    }
    finally {
        foreach ($o in @($si, $installer)) { if ($o) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($o) } }
    }
}

function Get-LatestFromProductsApi {
    # {"products":{"reader":[{"displayName":"Reader 2026.002.21931 MUI for Windows-64bit","version":"26.002.21931"}, ...]}}
    $json = Get-Page $ProductsApiUrl | ConvertFrom-Json
    $versions = @($json.products.reader) + @($json.products.dcPro) |
        Where-Object { $_ -and $_.version -match '^\d{2}\.\d{3}\.\d{5}$' } |
        ForEach-Object { $_.version } | Sort-Object { ConvertTo-Version $_ } -Descending
    if (-not $versions) { throw "Adobe's products service returned no version." }
    return [pscustomobject]@{ Version = @($versions)[0]; NotesUrl = $null }
}

function Get-LatestRelease {
    # Returns @{ Version = '26.002.21931'; NotesUrl = 'https://...' (or $null) }
    # Primary: Adobe's Reader products service (fast JSON; version only - download links
    #          are built from Adobe's standard URL pattern).
    # Fallback: the release notes index on www.adobe.com, tried once (that site often
    #          holds script connections open without answering).
    try {
        $r = Get-LatestFromProductsApi
        Write-Log "Adobe's products service reports version $($r.Version)."
        return $r
    }
    catch {
        Write-Log "Adobe's products service failed: $(Get-ErrorDetail $_)" 'WARN'
        Write-Log 'Trying the release notes index instead...'
    }
    try { $html = Get-Page $IndexUrl -Attempts 1 }
    catch { throw "Both version sources failed. Products service: see warning above. Release notes: $(Get-ErrorDetail $_). You can pass -Version." }
    $base = [Uri]$IndexUrl
    $entries = foreach ($m in [regex]::Matches($html, '(?is)<a\s[^>]*href="([^"]*continuous/[^"#]+\.html)[^"]*"[^>]*>\s*(\d{2}\.\d{3}\.\d{5})\b')) {
        [pscustomobject]@{
            Version  = $m.Groups[2].Value
            NotesUrl = ([Uri]::new($base, $m.Groups[1].Value)).AbsoluteUri
        }
    }
    if (-not $entries) { throw 'No Continuous-track releases found on the release notes index. Use -Version.' }
    return $entries | Sort-Object { ConvertTo-Version $_.Version } -Descending | Select-Object -First 1
}

# --- Main --------------------------------------------------------------------
$tempDir = Join-Path $env:TEMP "adobe-sync-$([guid]::NewGuid().ToString('N'))"
try {
    # latest.json as it was before this run, for the repo catalog (see the end of the script)
    $script:ManifestBefore = $null
    try {
        $manifestBeforePath = Join-Path $DestinationPath 'latest.json'
        if (Test-Path -LiteralPath $manifestBeforePath) { $script:ManifestBefore = Get-Content -LiteralPath $manifestBeforePath -Raw }
    }
    catch { }
    Write-Log "---- Sync started. Destination: $DestinationPath  Packages: $($Packages -join ', ')"
    New-Item -ItemType Directory -Path $tempDir | Out-Null

    $manifestPath = Join-Path $DestinationPath 'latest.json'
    $existing = $null
    if (Test-Path $manifestPath) {
        try { $existing = Get-Content $manifestPath -Raw | ConvertFrom-Json }
        catch { Write-Log "Existing manifest is unreadable and will be replaced: $_" 'WARN' }
    }
    Write-Log "Version on share: $(if ($existing) { $existing.Version } else { 'none' })"

    # --- Latest release -------------------------------------------------------
    $notesUrl = $null
    if ($Version) { $release = $Version }
    else {
        $latest   = Get-LatestRelease
        $release  = $latest.Version
        $notesUrl = $latest.NotesUrl
    }
    $digits = $release -replace '\.', ''
    Write-Log "Latest Continuous release: $release$(if ($notesUrl) { "  ($notesUrl)" })"

    # --- Are the update packages already current? ----------------------------
    $patchesCurrent = $false
    if ($existing -and -not $Force -and (ConvertTo-Version $existing.Version) -ge (ConvertTo-Version $release)) {
        $patchesCurrent = $true
        foreach ($pkg in $Packages) {
            $e = $existing.Packages.$pkg
            if (-not $e -or -not (Test-Path -LiteralPath (Join-Path $DestinationPath $e.FileName))) { $patchesCurrent = $false }
        }
    }

    $pkgs = [ordered]@{}
    $manifestVersion = $release
    if ($patchesCurrent) {
        Write-Log 'Update packages on the share are already the latest release.'
        foreach ($p in $existing.Packages.PSObject.Properties) { $pkgs[$p.Name] = $p.Value }
        $manifestVersion = $existing.Version
        $notesUrl = $existing.NotesUrl
    }
    else {
    # --- Links from the release notes page (fallback: Adobe's usual URL pattern) --
    $pageLinks = @{}
    if ($notesUrl) {
        try {
            $notes = Get-Page $notesUrl -Attempts 1
            foreach ($m in [regex]::Matches($notes, 'href="(https?://[^"]+?/([^/"]+\.msp))"')) {
                $pageLinks[$m.Groups[2].Value.ToLower()] = $m.Groups[1].Value
            }
            Write-Log "Found $($pageLinks.Count) .msp links on the release notes page."
        }
        catch { Write-Log "Couldn't read the release notes page: $(Get-ErrorDetail $_)" 'WARN' }
    }

    # --- Download and inspect each package -----------------------------------
    $found = [ordered]@{}
    foreach ($pkg in $Packages) {
        $info     = $PackageInfo[$pkg]
        $fileName = $info.File -replace '<v>', $digits
        $local    = Join-Path $tempDir $fileName

        $urls = @()
        if ($pageLinks[$fileName.ToLower()]) { $urls += $pageLinks[$fileName.ToLower()] }
        foreach ($h in 'ardownload3.adobe.com', 'ardownload2.adobe.com') {
            $urls += "https://$h/pub/adobe/$($info.Dir)/win/AcrobatDC/$digits/$fileName"
        }
        $urls = $urls | Select-Object -Unique

        $ok = $false
        foreach ($url in $urls) {
            try {
                Write-Log "Downloading $url"
                Save-Download -Url $url -OutFile $local
                $ok = $true; break
            }
            catch { Write-Log "  failed: $(Get-ErrorDetail $_)" 'WARN' }
        }
        if (-not $ok) { Write-Log "Could not download $fileName; skipping $pkg." 'WARN'; continue }

        $sig = Get-AuthenticodeSignature -FilePath $local
        $signedOk = $sig.Status -eq 'Valid' -and $sig.SignerCertificate.Subject -match $SignerPattern
        if (-not $signedOk) {
            $detail = "status: $($sig.Status), signer: $($sig.SignerCertificate.Subject)"
            if ($AllowUnsigned) { Write-Log "$fileName signature check failed ($detail); accepting because -AllowUnsigned was used." 'WARN' }
            else { throw "$fileName signature check failed ($detail)." }
        }

        $targets = Get-PatchTargets $local
        if ($targets.Count -eq 0) { throw "$fileName lists no target products; is it a valid patch?" }

        $size = (Get-Item -LiteralPath $local).Length
        Write-Log ("{0}: {1}  {2:N0} MB  applies to {3} product code(s)" -f $pkg, $fileName, ($size / 1MB), $targets.Count)
        $found[$pkg] = @{ Path = $local; Name = $fileName; Targets = $targets; Signed = $signedOk
                          Hash = (Get-FileHash -LiteralPath $local -Algorithm SHA256).Hash; Size = $size }
    }
    if ($found.Count -eq 0) { throw 'No update packages were downloaded.' }

    # --- Publish -------------------------------------------------------------
    $verFolder = Join-Path $DestinationPath $release
    $staging   = "$verFolder.partial"
    if (Test-Path $staging) { Remove-Item $staging -Recurse -Force }
    New-Item -ItemType Directory -Path $staging | Out-Null

    foreach ($pkg in $found.Keys) {
        Copy-Item -LiteralPath $found[$pkg].Path -Destination (Join-Path $staging $found[$pkg].Name)
        $pkgs[$pkg] = [ordered]@{
            FileName           = Join-Path $release $found[$pkg].Name
            Sha256             = $found[$pkg].Hash
            Size               = $found[$pkg].Size
            Signed             = $found[$pkg].Signed
            Product            = $PackageInfo[$pkg].Product
            Arch               = $PackageInfo[$pkg].Arch
            TargetProductCodes = $found[$pkg].Targets
        }
    }
    if (Test-Path $verFolder) { Remove-Item $verFolder -Recurse -Force }
    Rename-Item -Path $staging -NewName $release
    Write-Log "Published Acrobat/Reader update packages $release ($($pkgs.Keys -join ', '))."
    }   # end: update packages not current

    # --- Full installers for new installs ------------------------------------
    $inst = Sync-FullInstallers $existing $release $digits

    # --- Manifest (written last) ---------------------------------------------
    if (-not $patchesCurrent -or $inst.Changed -or -not $existing) {
        $manifest = [ordered]@{
            Product    = 'Adobe Acrobat / Acrobat Reader (Continuous track)'
            Version    = $manifestVersion
            NotesUrl   = $notesUrl
            UpdatedAt  = (Get-Date).ToString('o')
            Packages   = $pkgs
            Installers = $inst.Out
        }
        $tmp = "$manifestPath.tmp"
        $manifest | ConvertTo-Json -Depth 6 | Set-Content -Path $tmp -Encoding UTF8
        Move-Item -Path $tmp -Destination $manifestPath -Force
        Write-Log "Manifest updated: updates $manifestVersion; installers: $(($inst.Out.Keys | ForEach-Object { "$_ $($inst.Out[$_].Version)" }) -join ', ')."
    }
    else {
        Write-Log 'Nothing changed.'
    }

    # --- Prune old versions --------------------------------------------------
    Get-ChildItem -Path $DestinationPath -Directory |
        Where-Object { $_.Name -match '^\d{2}\.\d{3}\.\d{5}$' } |
        Sort-Object { ConvertTo-Version $_.Name } -Descending |
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
            Invoke-OTTOIntunePackageBuild -AppId 'AdobeAcrobat' -DestinationPath $DestinationPath -OutputPath $IntuneOutputPath `
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
            Update-OTTOCatalogEntry -AppId 'AdobeAcrobat' -DestinationPath $DestinationPath -ManifestBefore $script:ManifestBefore `
                -Failed ([bool]($script:SyncFailed -or $script:IntuneFailed)) -Script 'Sync\AdobeAcrobat.ps1' `
                -BoundParameters $PSBoundParameters -CatalogPath $CatalogPath -Definition $OTTOAppDefinition -ScriptPath $PSCommandPath -Log { param($m, $l) Write-Log $m $l }
        }
        catch { Write-Log "Couldn't update the repo catalog: $($_.Exception.Message)" 'WARN' }
    }
    # Release the one-sync-per-share lock (it would otherwise stay held until this PowerShell
    # window closes, so a second run in the same window would think a sync is still running)
    if ($script:SyncLock) { $script:SyncLock.Dispose(); $script:SyncLock = $null }
    if ($script:IntuneFailed) { exit 1 }
}
