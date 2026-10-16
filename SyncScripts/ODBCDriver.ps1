<#
.SYNOPSIS
    SERVER SCRIPT - Keeps a network share stocked with the latest Microsoft ODBC Driver 17
    and ODBC Driver 18 for SQL Server MSI installers.

.DESCRIPTION
    Microsoft changes the download links (go.microsoft.com/fwlink/?linkid=...) with each
    release, so this script:
    - Reads Microsoft's "Download ODBC Driver for SQL Server" page and picks out the
      English download links for each driver and architecture, e.g.
          "Download Microsoft ODBC Driver 18 for SQL Server (x64)"
      If learn.microsoft.com can't be reached, it reads the same page's source on GitHub
      (MicrosoftDocs/sql-docs) instead.
    - Skips anything whose link hasn't changed since the last run (and is on the share).
    - Otherwise downloads the MSI (progress logging, stall timeout), checks its
      Authenticode signature (Microsoft), reads the driver's ProductName/ProductVersion
      from the MSI, and publishes it to <DestinationPath>\<17|18>\<version>\.
    - For Driver 17, also keeps the Microsoft Visual C++ Redistributable (x64 + x86) on the
      share, because Driver 17 needs it (Driver 18.7 and later don't).
    - Writes latest.json last, and keeps the newest -KeepVersions versions per driver.

    Folder layout:
        <DestinationPath>\18\18.7.1.1\msodbcsql18-x64.msi  (also -x86, -arm64)
        <DestinationPath>\17\17.11.1.1\msodbcsql17-x64.msi (also -x86)
        <DestinationPath>\VCRedist\vc_redist.x64.exe       (also x86)
        <DestinationPath>\latest.json
        <DestinationPath>\Logs\Sync-ODBCDriverRepo.log

    Must run on Windows (it reads MSI details with the Windows Installer COM object).

.PARAMETER DestinationPath
    Folder (local path or UNC) where the installers are stored.
    Optional: if it's left out, the folder comes from the repo catalog
    (OTTOUpdate-Catalog.json): this app's Folder there (its full path), or
    <RepoRoot>\Applications\ODBCDriver if the app isn't in the catalog yet. The catalog is found
    automatically when this script runs from <RepoRoot>\Administrative\Sync;
    otherwise pass -CatalogPath.

.PARAMETER CatalogPath
    The repo catalog to take the folder from when -DestinationPath isn't given, e.g.
    \\fileserver\Software\OTTOUpdate-Catalog.json. Default: <RepoRoot>\OTTOUpdate-Catalog.json
    when this script is in <RepoRoot>\Administrative\Sync.

.PARAMETER Drivers
    Which driver versions to keep. Default: 17, 18.

.PARAMETER Architectures
    Which builds to keep. Default: x64, x86, arm64. (Driver 17 has no ARM64 build.)
    Note: the x64 MSI also installs the 32-bit driver, so x86 is only needed for
    32-bit Windows.

.PARAMETER KeepVersions
    How many versions to keep per driver. Default: 2.

.PARAMETER Proxy
    Proxy server for internet access, e.g. http://proxy.contoso.local:8080.

.PARAMETER ProxyUseDefaultCredentials
    Authenticate to the proxy as the account running the script.

.PARAMETER PageTimeoutSec
    Seconds to wait for a web page / for a download to start. Default: 60.

.PARAMETER StallTimeoutSec
    Give up on a download if no data arrives for this many seconds. Default: 120.

.PARAMETER Force
    Download and republish even if nothing appears to have changed.

.PARAMETER BuildIntunePackage
    After a successful sync, also build a Microsoft Intune Win32 app package from what is
    on the share: <IntuneOutputPath>\ODBCDriver\<version>\ gets ODBCDriver-<version>.intunewin,
    Detect-ODBCDriver.ps1 (custom detection script) and README-ODBCDriver.txt (the install/uninstall
    commands, return codes and detection settings to enter in Intune). Nothing is rebuilt
    if that version's package already exists (unless -Force). Needs <RepoRoot>\Administrative\Shared\OTTOUpdate-Common.ps1 and the app's client script (catalog ClientScript, normally Apps\ODBCDriver.ps1).

.PARAMETER IntuneOutputPath
    Where Intune packages are written. Default: <DestinationPath>\Intune

.PARAMETER ClientScriptPath
    Client script to put in the package. Default: the app's client script from the catalog (Apps\ODBCDriver.ps1 under <RepoRoot>\Administrative).

.PARAMETER IntuneWinAppUtilPath
    Path to IntuneWinAppUtil.exe (Microsoft Win32 Content Prep Tool). Default: the repo's
    shared copy, <RepoRoot>\Tools\IntuneWinAppUtil.exe (<RepoRoot> = the parent of
    -DestinationPath), which Update-IntuneWinAppUtil.ps1 downloads if it's missing.

.EXAMPLE
    .\Sync\ODBCDriver.ps1 -DestinationPath '\\fileserver\Software\Applications\ODBC'

.EXAMPLE
    # Sync, then build the Intune package (.intunewin + detection script + README)
    .\Sync\ODBCDriver.ps1 -DestinationPath '\\fileserver\Software\Applications\ODBC' -BuildIntunePackage
#>
[CmdletBinding()]
param(
    [string]$DestinationPath,

    [string]$CatalogPath,

    [ValidateSet('17', '18')]
    [string[]]$Drivers = @('17', '18'),

    [ValidateSet('x64', 'x86', 'arm64')]
    [string[]]$Architectures = @('x64', 'x86', 'arm64'),

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
    AppId        = 'ODBCDriver'
    Name         = 'Microsoft ODBC Driver 17/18 for SQL Server'
    SyncScript   = 'Sync\ODBCDriver.ps1'
    ClientScript = 'Apps\ODBCDriver.ps1'
    Intune       = @{
        # Install command arguments after the script name. '-SourcePath .' becomes the repo path
        # plus the package's own copy as the fallback.
        InstallCommand  = '-SourcePath . -Install 18'
        InstallVariants = @(
            '-SourcePath . -Install 17,18',
            '-SourcePath . -Install 17'
        )
        # The app's Programs and Features entries (regular expressions), for detection logging and uninstall
        Match           = @{ Pattern = '^Microsoft ODBC Driver 1[78] for SQL Server'; Exclude = ''; KeyPattern = ''; Exe = '' }
        Detection       = @{
            # How it's detected, as written in Detect.log. Empty = the built-in check of the
            # Programs and Features entry (Match.Pattern) and, if newer, Match.Exe's file version
            Description     = 'Programs and Features entries, each driver (17 / 18) compared separately'
            # Several versions side by side, each compared with its own repo version ($Required)
            SeveralVersions = $true
            # What $Required is when the detection script's $Required line is left at $null
            DefaultRequired = '@(''18'')'
            # Runs before the repo is read; may Pass or Fail straight away
            PreCheck        = ''
            # Sets $have when the repo can't be read. Empty = the Programs and Features check
            Offline         = ''
            # The check: compares what's installed with $Manifest (the repo's latest.json) and
            # ends with Test-Current / Test-CurrentSet. Empty = the built-in check
            Code            = @'
# Each installed driver is compared with its repo version. $Required = drivers that must be
# installed (match the -Install value in your Intune install command).
$arch = Get-OSArch
$installed = Get-Uninstall | Where-Object { $_.Name -match '^Microsoft ODBC Driver (1[78]) for SQL Server' }
$items = @()
foreach ($d in @($Manifest.Drivers.PSObject.Properties.Name)) {
    $entry = $Manifest.Drivers.$d.Files.$arch
    if (-not $entry) { continue }
    $best = $installed | Where-Object { $_.Name -match "Driver $d for" } | Sort-Object Version -Descending | Select-Object -First 1
    if ($best -or $Required -contains $d) { $items += [pscustomobject]@{ Name = "ODBC Driver $d"; Have = $best.VersionText; Want = $entry.Version } }
}
Test-CurrentSet 'ODBC drivers' $items
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
                    "Pass -DestinationPath <share>\ODBCDriver, or -CatalogPath <RepoRoot>\OTTOUpdate-Catalog.json " +
                    "(found automatically when this script runs from <RepoRoot>\Administrative\Sync).") -ForegroundColor Red
        exit 1
    }
    try { $catalogData = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $CatalogPath).ProviderPath) | ConvertFrom-Json }
    catch { Write-Host "The repo catalog $CatalogPath can't be read: $($_.Exception.Message). Pass -DestinationPath instead." -ForegroundColor Red; exit 1 }
    $catalogEntry = @($catalogData.Apps) | Where-Object { $_ -and [string]$_.AppId -eq 'ODBCDriver' } | Select-Object -First 1
    $catalogFolder = if ($catalogEntry -and $catalogEntry.Folder) { [string]$catalogEntry.Folder } else { 'Applications\ODBCDriver' }
    # Folder is the app's full path (e.g. \\fileserver\Software\Applications\Chrome); older catalogs hold a name under the repo root
    $DestinationPath = if ($catalogFolder -match '^\\\\' -or [IO.Path]::IsPathRooted($catalogFolder)) { $catalogFolder }
                       else { Join-Path (Split-Path (Resolve-Path -LiteralPath $CatalogPath).ProviderPath -Parent) $catalogFolder }
    Write-Host ("-DestinationPath from the repo catalog: $DestinationPath" + $(if (-not $catalogEntry) { " (ODBCDriver isn't in the catalog yet; it's added after this sync writes latest.json)" }))
}

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
try   { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13 }
catch { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 }

$PageUrls = @(
    'https://learn.microsoft.com/en-us/sql/connect/odbc/download-odbc-driver-for-sql-server',
    'https://raw.githubusercontent.com/MicrosoftDocs/sql-docs/live/docs/connect/odbc/download-odbc-driver-for-sql-server.md'
)
$VcUrls = @{
    x64 = 'https://aka.ms/vs/17/release/vc_redist.x64.exe'
    x86 = 'https://aka.ms/vs/17/release/vc_redist.x86.exe'
}
$SignerPattern = 'O=Microsoft Corporation'
$UserAgent     = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36'

if ($Proxy) {
    $PSDefaultParameterValues['Invoke-WebRequest:Proxy'] = $Proxy
    if ($ProxyUseDefaultCredentials) { $PSDefaultParameterValues['Invoke-WebRequest:ProxyUseDefaultCredentials'] = $true }
}

# --- Helpers -----------------------------------------------------------------
if (-not (Test-Path $DestinationPath)) { New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null }
$logDir = Join-Path $DestinationPath 'Logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$LogFile = Join-Path $logDir 'Sync-ODBCDriverRepo.log'

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

function Assert-MicrosoftSigned([string]$Path) {
    $sig = Get-AuthenticodeSignature -FilePath $Path
    if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch $SignerPattern) {
        throw "Signature check failed for $(Split-Path $Path -Leaf) (status: $($sig.Status), signer: $($sig.SignerCertificate.Subject))."
    }
}

function Get-DownloadLinks {
    # Returns @{ '18' = @{ x64 = 'https://go.microsoft.com/fwlink/?linkid=...'; ... }; '17' = @{ ... } }
    foreach ($url in $PageUrls) {
        try { $page = Get-Page $url }
        catch { Write-Log "  couldn't read it: $(Get-ErrorDetail $_)" 'WARN'; continue }
        $page = [Net.WebUtility]::HtmlDecode($page)

        $links = @{}
        # HTML:     <a href="https://go.microsoft.com/fwlink/?linkid=123">Download Microsoft ODBC Driver 18 for SQL Server (x64)</a>
        # Markdown: [Download Microsoft ODBC Driver 18 for SQL Server (x64)](https://go.microsoft.com/fwlink/?linkid=123)
        $patterns = @(
            '(?is)<a\s[^>]*href="(?<u>https?://go\.microsoft\.com/fwlink/\?linkid=\d+[^"]*)"[^>]*>\s*Download Microsoft ODBC Driver (?<d>1[78]) for SQL Server \((?<a>x64|x86|ARM64)\)\s*</a>',
            '(?is)\[\s*Download Microsoft ODBC Driver (?<d>1[78]) for SQL Server \((?<a>x64|x86|ARM64)\)\s*\]\((?<u>https?://go\.microsoft\.com/fwlink/\?linkid=\d+[^)\s]*)\)'
        )
        foreach ($p in $patterns) {
            foreach ($m in [regex]::Matches($page, $p)) {
                $d = $m.Groups['d'].Value; $a = $m.Groups['a'].Value.ToLower()
                if (-not $links[$d]) { $links[$d] = @{} }
                # First occurrence on the page = the current release
                if (-not $links[$d][$a]) { $links[$d][$a] = $m.Groups['u'].Value -replace '&amp;', '&' }
            }
        }
        if ($links.Count -gt 0) { return $links }
        Write-Log "  no ODBC driver download links found on $url" 'WARN'
    }
    throw 'Could not find the ODBC driver download links on Microsoft''s page or its GitHub source.'
}

# --- Main --------------------------------------------------------------------
$tempDir = Join-Path $env:TEMP "odbc-sync-$([guid]::NewGuid().ToString('N'))"
try {
    # latest.json as it was before this run, for the repo catalog (see the end of the script)
    $script:ManifestBefore = $null
    try {
        $manifestBeforePath = Join-Path $DestinationPath 'latest.json'
        if (Test-Path -LiteralPath $manifestBeforePath) { $script:ManifestBefore = Get-Content -LiteralPath $manifestBeforePath -Raw }
    }
    catch { }
    Write-Log "---- Sync started. Destination: $DestinationPath  Drivers: $($Drivers -join ', ')  Architectures: $($Architectures -join ', ')"
    New-Item -ItemType Directory -Path $tempDir | Out-Null

    $manifestPath = Join-Path $DestinationPath 'latest.json'
    $existing = $null
    if (Test-Path $manifestPath) {
        try { $existing = Get-Content $manifestPath -Raw | ConvertFrom-Json }
        catch { Write-Log "Existing manifest is unreadable and will be replaced: $_" 'WARN' }
    }

    $links = Get-DownloadLinks
    foreach ($d in $Drivers) {
        foreach ($a in $Architectures) {
            if ($links[$d] -and $links[$d][$a]) { Write-Log "Driver $d $a link: $($links[$d][$a])" }
        }
    }

    # Start from the existing manifest so untouched drivers are kept
    $driversOut = [ordered]@{}
    if ($existing -and $existing.Drivers) {
        foreach ($p in $existing.Drivers.PSObject.Properties) { $driversOut[$p.Name] = $p.Value }
    }
    $changed = $false

    foreach ($d in $Drivers) {
        $prev = $driversOut[$d]
        $prevVersion = if ($prev) { ConvertTo-Version $prev.Version } else { $null }

        # Which architectures need downloading? (link changed or file missing)
        $archs = @($Architectures | Where-Object { $links[$d] -and $links[$d][$_] })
        foreach ($a in $Architectures | Where-Object { $archs -notcontains $_ }) {
            if (-not ($d -eq '17' -and $a -eq 'arm64')) { Write-Log "No $a download link for Driver $d on the page." 'WARN' }
        }
        $todo = @($archs | Where-Object {
            $e = if ($prev) { $prev.Files.$_ } else { $null }
            $Force -or -not $e -or $e.SourceUrl -ne $links[$d][$_] -or -not (Test-Path -LiteralPath (Join-Path $DestinationPath $e.FileName))
        })
        if ($todo.Count -eq 0) {
            Write-Log "Driver $d : links unchanged and files present ($($prev.Version)). Nothing to do."
            continue
        }

        # Download and inspect
        $found = [ordered]@{}
        foreach ($a in $archs) {
            $local = Join-Path $tempDir "msodbcsql$d-$a.msi"
            Write-Log "Downloading Driver $d $a"
            try { Save-Download -Url $links[$d][$a] -OutFile $local }
            catch { Write-Log "  failed: $(Get-ErrorDetail $_); skipping $a." 'WARN'; continue }
            Assert-MicrosoftSigned $local
            $name = Get-MsiProperty $local 'ProductName'
            $ver  = Get-MsiProperty $local 'ProductVersion'
            if ($name -notmatch "ODBC Driver $d for SQL Server") { throw "Downloaded Driver $d $a MSI is '$name' - not what was expected." }
            Write-Log "  $name $ver, signature OK"
            $found[$a] = @{ Path = $local; Version = $ver; ProductName = $name; Url = $links[$d][$a]
                            Hash = (Get-FileHash -LiteralPath $local -Algorithm SHA256).Hash }
        }
        if ($found.Count -eq 0) { Write-Log "Driver $d : nothing downloaded." 'WARN'; continue }

        $vers = @($found.Values | ForEach-Object { ConvertTo-Version $_.Version } | Sort-Object -Unique -Descending)
        if ($vers.Count -gt 1) { Write-Log "Driver $d architectures report different versions ($($vers -join ', ')); using the highest for the folder." 'WARN' }
        $newVersion = $vers[0]
        if ($prevVersion -and $newVersion -lt $prevVersion -and -not $Force) {
            Write-Log "Driver $d : downloaded $newVersion is older than the share's $prevVersion. Not publishing." 'WARN'
            continue
        }

        # Publish
        $verName   = $newVersion.ToString()
        $drvDir    = Join-Path $DestinationPath $d
        if (-not (Test-Path $drvDir)) { New-Item -ItemType Directory -Path $drvDir | Out-Null }
        $verFolder = Join-Path $drvDir $verName
        $staging   = "$verFolder.partial"
        if (Test-Path $staging) { Remove-Item $staging -Recurse -Force }
        New-Item -ItemType Directory -Path $staging | Out-Null

        $files = [ordered]@{}
        foreach ($a in $found.Keys) {
            $fileName = "msodbcsql$d-$a.msi"
            Copy-Item -LiteralPath $found[$a].Path -Destination (Join-Path $staging $fileName)
            $files[$a] = [ordered]@{
                FileName    = Join-Path $d (Join-Path $verName $fileName)
                Version     = $found[$a].Version
                ProductName = $found[$a].ProductName
                Sha256      = $found[$a].Hash
                SourceUrl   = $found[$a].Url
            }
        }
        if (Test-Path $verFolder) { Remove-Item $verFolder -Recurse -Force }
        Rename-Item -Path $staging -NewName $verName
        $driversOut[$d] = [ordered]@{ Version = $verName; Files = $files }
        $changed = $true
        Write-Log "Published ODBC Driver $d $verName ($($files.Keys -join ', '))."

        Get-ChildItem -Path $drvDir -Directory |
            Where-Object { $_.Name -match '^\d+(\.\d+){1,3}$' } |
            Sort-Object { [version]$_.Name } -Descending |
            Select-Object -Skip $KeepVersions |
            ForEach-Object { Write-Log "Removing old Driver $d folder $($_.Name)"; Remove-Item $_.FullName -Recurse -Force }
        Get-ChildItem -Path $drvDir -Directory -Filter '*.partial' | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }

    # --- Visual C++ Redistributable (needed by Driver 17) --------------------
    $vcOut = [ordered]@{}
    if ($existing -and $existing.VCRedist) { foreach ($p in $existing.VCRedist.PSObject.Properties) { $vcOut[$p.Name] = $p.Value } }
    if ($Drivers -contains '17') {
        $vcDir = Join-Path $DestinationPath 'VCRedist'
        if (-not (Test-Path $vcDir)) { New-Item -ItemType Directory -Path $vcDir | Out-Null }
        foreach ($a in 'x64', 'x86') {
            $final = Join-Path $vcDir "vc_redist.$a.exe"
            $prevVc = $vcOut[$a]
            # Refresh weekly, or when missing
            if (-not $Force -and $prevVc -and (Test-Path -LiteralPath $final) -and
                ((Get-Date) - [datetime]$prevVc.DownloadedAt).TotalDays -lt 7) { continue }
            Write-Log "Downloading VC++ Redistributable $a"
            $partial = "$final.partial"
            try {
                Save-Download -Url $VcUrls[$a] -OutFile $partial
                Assert-MicrosoftSigned $partial
                $vcVer = (Get-Item -LiteralPath $partial).VersionInfo.ProductVersion
                Move-Item -LiteralPath $partial -Destination $final -Force
                $vcOut[$a] = [ordered]@{
                    FileName     = Join-Path 'VCRedist' "vc_redist.$a.exe"
                    Version      = $vcVer
                    Sha256       = (Get-FileHash -LiteralPath $final -Algorithm SHA256).Hash
                    DownloadedAt = (Get-Date).ToString('o')
                }
                $changed = $true
                Write-Log "  VC++ Redistributable $a $vcVer"
            }
            catch {
                Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
                Write-Log "  VC++ Redistributable $a failed: $(Get-ErrorDetail $_)" 'WARN'
            }
        }
    }

    # --- Manifest ------------------------------------------------------------
    if ($changed -or -not $existing) {
        $manifest = [ordered]@{
            Product   = 'Microsoft ODBC Driver for SQL Server (17 / 18)'
            UpdatedAt = (Get-Date).ToString('o')
            Drivers   = $driversOut
            VCRedist  = $vcOut
        }
        $tmp = "$manifestPath.tmp"
        $manifest | ConvertTo-Json -Depth 6 | Set-Content -Path $tmp -Encoding UTF8
        Move-Item -Path $tmp -Destination $manifestPath -Force
        Write-Log "Manifest updated ($(($driversOut.Keys | ForEach-Object { "Driver $_ $($driversOut[$_].Version)" }) -join ', '))."
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
            Invoke-OTTOIntunePackageBuild -AppId 'ODBCDriver' -DestinationPath $DestinationPath -OutputPath $IntuneOutputPath `
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
            Update-OTTOCatalogEntry -AppId 'ODBCDriver' -DestinationPath $DestinationPath -ManifestBefore $script:ManifestBefore `
                -Failed ([bool]($script:SyncFailed -or $script:IntuneFailed)) -Script 'Sync\ODBCDriver.ps1' `
                -BoundParameters $PSBoundParameters -CatalogPath $CatalogPath -Definition $OTTOAppDefinition -ScriptPath $PSCommandPath -Log { param($m, $l) Write-Log $m $l }
        }
        catch { Write-Log "Couldn't update the repo catalog: $($_.Exception.Message)" 'WARN' }
    }
    # Release the one-sync-per-share lock (it would otherwise stay held until this PowerShell
    # window closes, so a second run in the same window would think a sync is still running)
    if ($script:SyncLock) { $script:SyncLock.Dispose(); $script:SyncLock = $null }
    if ($script:IntuneFailed) { exit 1 }
}
