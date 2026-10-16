<#
.SYNOPSIS
    SERVER SCRIPT - Keeps a network share stocked with the latest Windows installer of
    every supported Python 3 version (3.10, 3.11, 3.12, 3.13, 3.14 ...) and of Python 2.7
    (its final release, 2.7.18), verified against python.org's published checksums and
    the Python Software Foundation's signature.

.DESCRIPTION
    Python versions ("branches", e.g. 3.13) are installed side by side, and each gets its
    own updates. For each branch this script keeps the newest release that has Windows
    installers:
    - Which branches: every branch that hasn't reached end of life (from endoflife.date;
      if that can't be read, the five newest branches - Python supports five at a time),
      or the ones given with -Branches (which may include end-of-life ones).
    - Which release: python.org's release list (https://www.python.org/api/v2/downloads/).
      Branches in "security fixes only" support get source-only releases, so for those
      the newest release WITH Windows installers is used (e.g. 3.12.10 even when 3.12.12
      exists) - that's the newest version anyone can install on Windows from python.org.
    - Downloads the installers for -Architectures, checks each against python.org's
      SHA-256 (MD5 for older releases that only list that) and its Authenticode
      signature (Python Software Foundation), and publishes them to
      <DestinationPath>\<version>\.
    - Branches whose version hasn't changed aren't downloaded again.
    - Writes latest.json last. Keeps -KeepVersions version folders per branch.

    Folder layout:
        <DestinationPath>\3.13.11\python-3.13.11-amd64.exe   (python-3.13.11.exe = 32-bit,
                                                            python-3.13.11-arm64.exe)
        <DestinationPath>\latest.json
        <DestinationPath>\Logs\Sync-PythonRepo.log

    Note: from Python 3.16 python.org plans to ship only the new "Python install manager"
    for Windows; the traditional installers this script uses are available through 3.15.

.PARAMETER DestinationPath
    Folder (local path or UNC) where the installers are stored.
    Optional: if it's left out, the folder comes from the repo catalog
    (OTTOUpdate-Catalog.json): this app's Folder there (its full path), or
    <RepoRoot>\Applications\Python if the app isn't in the catalog yet. The catalog is found
    automatically when this script runs from <RepoRoot>\Administrative\Sync;
    otherwise pass -CatalogPath.

.PARAMETER CatalogPath
    The repo catalog to take the folder from when -DestinationPath isn't given, e.g.
    \\fileserver\Software\OTTOUpdate-Catalog.json. Default: <RepoRoot>\OTTOUpdate-Catalog.json
    when this script is in <RepoRoot>\Administrative\Sync.

.PARAMETER Branches
    Python versions to keep, e.g. 2.7,3.12,3.13,3.14. Default: every supported version,
    plus 2.7 (see -IncludePython2).
    Naming an end-of-life version (e.g. 3.9) keeps its last Windows release. (In a
    PowerShell prompt 3.10 unquoted arrives as 3.1; that's taken to mean 3.10.)

.PARAMETER IncludePython2
    With the default (supported) versions, also keep Python 2.7's final release, 2.7.18
    (MSI installers, x64 and x86), so computers that still have Python 2.7 can be updated
    to it. Default: $true. -IncludePython2:$false leaves it out. Python 2 reached end of
    life in 2020 and gets no more fixes - updating to 2.7.18 is the best available, but
    moving those programs to Python 3 is the real fix.

.PARAMETER AllowUnsigned
    Accept an installer that isn't signed by the Python Software Foundation when its
    python.org checksum matches. Only needed if an older release (e.g. Python 2.7) turns
    out to be unsigned; the manifest records it so clients check the SHA-256 only.

.PARAMETER PortablePackages
    Also keep the files Apps\PythonPortable.ps1 uses to update portable
    (unregistered) copies of Python found on computers: for each version and architecture,
    python.org's "embeddable package" zip (the embedded layout apps ship) and the official
    NuGet package (python / pythonx86 / pythonarm64, python2 / python2x86 for 2.7 - a full
    Python folder without an installer). The zip's checksum comes from python.org and the
    NuGet package's SHA-512 from nuget.org. They're not put in the Intune package.
    Default: $true.

.PARAMETER Architectures
    Which builds to keep: x64, x86 (32-bit Python - also needed to update 32-bit Python
    installed on 64-bit Windows) and/or arm64. Default: all three. A branch without a
    build (e.g. no ARM64 for 3.10 or 2.7) just doesn't get one.

.PARAMETER KeepVersions
    How many version folders to keep per branch. Default: 2.

.PARAMETER Proxy
    Proxy server for internet access, e.g. http://proxy.contoso.local:8080.

.PARAMETER ProxyUseDefaultCredentials
    Authenticate to the proxy as the account running the script.

.PARAMETER PageTimeoutSec
    Seconds to wait for a web page / for a download to start. Default: 60.

.PARAMETER StallTimeoutSec
    Give up on a download if no data arrives for this many seconds. Default: 120.

.PARAMETER Force
    Download and republish every branch even if the share already has it.

.PARAMETER BuildIntunePackage
    After a successful sync, also build a Microsoft Intune Win32 app package from what is
    on the share: <IntuneOutputPath>\Python\<date>\ gets Python-<date>.intunewin,
    Detect-Python.ps1 (custom detection script) and README-Python.txt (the install/uninstall
    commands, return codes and detection settings to enter in Intune). Nothing is rebuilt
    if that package already exists (unless -Force). Needs <RepoRoot>\Administrative\Shared\OTTOUpdate-Common.ps1 and the app's client script (catalog ClientScript, normally Apps\Python.ps1).

.PARAMETER IntuneOutputPath
    Where Intune packages are written. Default: <DestinationPath>\Intune

.PARAMETER ClientScriptPath
    Client script to put in the package. Default: the app's client script from the catalog (Apps\Python.ps1 under <RepoRoot>\Administrative).

.PARAMETER IntuneWinAppUtilPath
    Path to IntuneWinAppUtil.exe (Microsoft Win32 Content Prep Tool). Default: the repo's
    shared copy, <RepoRoot>\Tools\IntuneWinAppUtil.exe (<RepoRoot> = the parent of
    -DestinationPath), which Update-IntuneWinAppUtil.ps1 downloads if it's missing.

.EXAMPLE
    # Every supported Python version
    .\Sync\Python.ps1 -DestinationPath '\\fileserver\Software\Applications\Python'

.EXAMPLE
    # Only some versions, 64-bit only
    .\Sync\Python.ps1 -DestinationPath '\\fileserver\Software\Applications\Python' -Branches 3.12,3.13 -Architectures x64

.EXAMPLE
    # Sync, then build the Intune package (.intunewin + detection script + README)
    .\Sync\Python.ps1 -DestinationPath '\\fileserver\Software\Applications\Python' -BuildIntunePackage
#>
[CmdletBinding()]
param(
    [string]$DestinationPath,

    [string]$CatalogPath,

    [ValidatePattern('^[23]\.\d+$')]
    [string[]]$Branches = @(),

    [bool]$IncludePython2 = $true,

    [switch]$AllowUnsigned,

    [bool]$PortablePackages = $true,

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
    AppId        = 'Python'
    Name         = 'Python (every supported 3.x, and 2.7)'
    SyncScript   = 'Sync\Python.ps1'
    ClientScript = 'Apps\Python.ps1'
    Intune       = @{
        # Install command arguments after the script name. '-SourcePath .' becomes the repo path
        # plus the package's own copy as the fallback.
        InstallCommand  = '-SourcePath . -Install'
        InstallVariants = @(
            '-SourcePath . -Install 3.12,3.13   (make sure these versions are installed; set $Required = @(''3.12'',''3.13'') in the detection script)',
            '-SourcePath . -Install -InstallOptions PrependPath=1   (new installs are also added to PATH)',
            '-SourcePath . -Install -CloseRunning   (close running Python programs instead of retrying)',
            '-SourcePath .   (update installed versions only; set $Required = @() in the detection script)'
        )
        # The app's Programs and Features entries (regular expressions), for detection logging and uninstall
        Match           = @{ Pattern = '^Python (3\.\d+\.\d+ \((64-bit|32-bit|ARM64)\)|2\.7\.\d+( \(64-bit\))?)$'; Exclude = ''; KeyPattern = ''; Exe = '' }
        Detection       = @{
            # How it's detected, as written in Detect.log. Empty = the built-in check of the
            # Programs and Features entry (Match.Pattern) and, if newer, Match.Exe's file version
            Description     = 'Programs and Features entries "Python 3.x.y (64-bit / 32-bit / ARM64)" and "Python 2.7.x", each Python version and architecture compared separately'
            # Several versions side by side, each compared with its own repo version ($Required)
            SeveralVersions = $true
            # What $Required is when the detection script's $Required line is left at $null
            DefaultRequired = '@(@($Manifest.Branches.PSObject.Properties.Name) | Where-Object { $_ -notlike ''2.*'' } | Sort-Object { [version]$_ } -Descending | Select-Object -First 1)'
            # Runs before the repo is read; may Pass or Fail straight away
            PreCheck        = ''
            # Sets $have when the repo can't be read. Empty = the Programs and Features check
            Offline         = ''
            # The check: compares what's installed with $Manifest (the repo's latest.json) and
            # ends with Test-Current / Test-CurrentSet. Empty = the built-in check
            Code            = @'
# Each installed Python version (3.12, 3.13 ...) and architecture is compared with the repo's
# release of that version. $Required = versions that must be installed (match -Install).
$items = @()
foreach ($e in Get-Uninstall) {
    # Python 3: "Python 3.13.7 (64-bit|32-bit|ARM64)"; Python 2.7: "Python 2.7.18 (64-bit)" or "Python 2.7.18" (32-bit)
    if ($e.Name -notmatch '^Python ([23]\.\d+)\.(\d+)(?: \((64-bit|32-bit|ARM64)\))?$') { continue }
    if (-not $Matches[3] -and $Matches[1] -notlike '2.*') { continue }
    $b = $Matches[1]; $have = "$b.$($Matches[2])"
    $a = switch ($Matches[3]) { '64-bit' { 'x64' } 'ARM64' { 'arm64' } default { 'x86' } }
    $repo = $Manifest.Branches.$b
    if (-not $repo) { Note "  Python $have ($a): $b isn't in the repo (e.g. end of life) - not checked"; continue }
    $want = if ($repo.Files.$a) { $repo.Files.$a.Version } else { Note "  Python $have ($a): the repo has no $a build of $b - not checked"; continue }
    $items += [pscustomobject]@{ Name = "Python $b ($a)"; Have = $have; Want = $want }
}
foreach ($b in $Required) {
    if ($items | Where-Object { $_.Name -like "Python $b (*" }) { continue }
    $repo = $Manifest.Branches.$b
    $items += [pscustomobject]@{ Name = "Python $b"; Have = $null; Want = $(if ($repo) { $repo.Version } else { $b }) }
}
Test-CurrentSet 'Python' $items
'@
        }
        Uninstall       = @{
            # Silent arguments for uninstallers that aren't MSI
            ExeArgs      = '/uninstall /quiet'
            # A reason the app can't be uninstalled (the uninstall script then only logs it)
            NotSupported = ''
            # Runs instead of removing the matching Programs and Features entries
            Code         = ''
        }
    }
    # More client actions: OTTOUpdate-Client.ps1 Task Python Portable
    Tasks        = @{
        Portable = @{ Script = 'Apps\PythonPortable.ps1'; Description = 'Find portable (not installed) copies of Python on this computer and update them' }
    }
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
                    "Pass -DestinationPath <share>\Python, or -CatalogPath <RepoRoot>\OTTOUpdate-Catalog.json " +
                    "(found automatically when this script runs from <RepoRoot>\Administrative\Sync).") -ForegroundColor Red
        exit 1
    }
    try { $catalogData = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $CatalogPath).ProviderPath) | ConvertFrom-Json }
    catch { Write-Host "The repo catalog $CatalogPath can't be read: $($_.Exception.Message). Pass -DestinationPath instead." -ForegroundColor Red; exit 1 }
    $catalogEntry = @($catalogData.Apps) | Where-Object { $_ -and [string]$_.AppId -eq 'Python' } | Select-Object -First 1
    $catalogFolder = if ($catalogEntry -and $catalogEntry.Folder) { [string]$catalogEntry.Folder } else { 'Applications\Python' }
    # Folder is the app's full path (e.g. \\fileserver\Software\Applications\Chrome); older catalogs hold a name under the repo root
    $DestinationPath = if ($catalogFolder -match '^\\\\' -or [IO.Path]::IsPathRooted($catalogFolder)) { $catalogFolder }
                       else { Join-Path (Split-Path (Resolve-Path -LiteralPath $CatalogPath).ProviderPath -Parent) $catalogFolder }
    Write-Host ("-DestinationPath from the repo catalog: $DestinationPath" + $(if (-not $catalogEntry) { " (Python isn't in the catalog yet; it's added after this sync writes latest.json)" }))
}

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
try   { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13 }
catch { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 }

$ApiBase       = 'https://www.python.org/api/v2/downloads'
$EolUrl        = 'https://endoflife.date/api/python.json'
# python.org's names for the Windows installers
# (Python 3: .exe installers; Python 2.7: MSI installers, no ARM64)
$InstallerName = @{ x64   = 'Windows installer (64-bit)', 'Windows x86-64 MSI installer'
                    x86   = 'Windows installer (32-bit)', 'Windows x86 MSI installer'
                    arm64 = @('Windows installer (ARM64)') }
$SignerPattern = 'Python Software Foundation'
# Portable Python sources (see -PortablePackages)
$EmbedName     = @{ x64 = 'Windows embeddable package (64-bit)'; x86 = 'Windows embeddable package (32-bit)'; arm64 = 'Windows embeddable package (ARM64)' }
$NuGetId       = @{ '3' = @{ x64 = 'python'; x86 = 'pythonx86'; arm64 = 'pythonarm64' }; '2' = @{ x64 = 'python2'; x86 = 'python2x86' } }
$NuGetFlat     = 'https://api.nuget.org/v3-flatcontainer'
$NuGetReg      = 'https://api.nuget.org/v3/registration5-semver1'
$UserAgent     = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Sync-PythonRepo.ps1'

if ($Proxy) {
    $PSDefaultParameterValues['Invoke-WebRequest:Proxy'] = $Proxy
    if ($ProxyUseDefaultCredentials) { $PSDefaultParameterValues['Invoke-WebRequest:ProxyUseDefaultCredentials'] = $true }
}

# --- Helpers -----------------------------------------------------------------
if (-not (Test-Path $DestinationPath)) { New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null }
$logDir = Join-Path $DestinationPath 'Logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$LogFile = Join-Path $logDir 'Sync-PythonRepo.log'

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
function Get-Json([string]$Url) { Get-Page $Url | ConvertFrom-Json }

function Get-ProductVersion([string]$Version) {
    # Python's Programs and Features version: 3.13.11 -> 3.13.11150.0, 2.7.18 -> 2.7.18150
    # (micro*1000 + 150 = final release)
    $p = $Version.Split('.')
    if ($p[0] -eq '2') { return '{0}.{1}.{2}' -f $p[0], $p[1], ([int]$p[2] * 1000 + 150) }
    return '{0}.{1}.{2}.0' -f $p[0], $p[1], ([int]$p[2] * 1000 + 150)
}

$tempDir = Join-Path $env:TEMP "python-sync-$([guid]::NewGuid().ToString('N'))"
try {
    # latest.json as it was before this run, for the repo catalog (see the end of the script)
    $script:ManifestBefore = $null
    try {
        $manifestBeforePath = Join-Path $DestinationPath 'latest.json'
        if (Test-Path -LiteralPath $manifestBeforePath) { $script:ManifestBefore = Get-Content -LiteralPath $manifestBeforePath -Raw }
    }
    catch { }
    Write-Log "---- Sync started. Destination: $DestinationPath  Branches: $(if ($Branches) { $Branches -join ', ' } else { 'supported' })  Architectures: $($Architectures -join ', ')"
    New-Item -ItemType Directory -Path $tempDir | Out-Null

    $manifestPath = Join-Path $DestinationPath 'latest.json'
    $existing = $null
    if (Test-Path $manifestPath) {
        try { $existing = Get-Content $manifestPath -Raw | ConvertFrom-Json }
        catch { Write-Log "Existing manifest is unreadable and will be replaced: $_" 'WARN' }
    }
    Write-Log "Versions on share: $(if ($existing -and $existing.Branches) { ($existing.Branches.PSObject.Properties | ForEach-Object { $_.Value.Version }) -join ', ' } else { 'none' })"

    # --- Python releases (python.org) ----------------------------------------
    $releases = @(@(Get-Json "$ApiBase/release/?is_published=true&pre_release=false&version=3") +
                  @(Get-Json "$ApiBase/release/?is_published=true&pre_release=false&version=2") |
        ForEach-Object {
            if ($_.name -notmatch '^Python ([23])\.(\d+)\.(\d+)$') { return }
            [pscustomobject]@{
                Branch  = "$($Matches[1]).$($Matches[2])"
                Version = "$($Matches[1]).$($Matches[2]).$($Matches[3])"
                Micro   = [int]$Matches[3]
                Date    = $_.release_date
                Id      = [regex]::Match([string]$_.resource_uri, '/release/(\d+)/').Groups[1].Value
            }
        })
    if (-not $releases) { throw "python.org's release list returned no Python 3 releases." }

    # --- Which branches? ---------------------------------------------------------
    $eolOf = @{}
    if ($Branches.Count) {
        # 3.10 typed without quotes reaches the script as the number 3.1 - it means 3.10
        $known = @($releases.Branch | Select-Object -Unique)
        $want = @($Branches | ForEach-Object { if ($known -notcontains $_ -and $known -contains "$($_)0") { "$($_)0" } else { $_ } } |
                  Sort-Object { [version]$_ } -Unique)
    } else {
        try {
            $cycles = Get-Json $EolUrl
            $today = (Get-Date).Date
            $want = @($cycles | Where-Object { $_.cycle -match '^3\.\d+$' -and $_.eol -and [datetime]$_.eol -ge $today -and
                                                 (-not $_.releaseDate -or [datetime]$_.releaseDate -le $today) } |
                      ForEach-Object { $eolOf[[string]$_.cycle] = [string]$_.eol; [string]$_.cycle })
            Write-Log "Supported Python versions (endoflife.date): $($want -join ', ')"
        }
        catch {
            Write-Log "Couldn't read $EolUrl ($(Get-ErrorDetail $_)); using the five newest Python versions instead." 'WARN'
            $want = @()
        }
        if (-not $want) {
            $want = @($releases | Select-Object -ExpandProperty Branch -Unique | Sort-Object { [version]$_ } -Descending | Select-Object -First 5)
        }
        # Python 2.7: end of life since 2020, but its final release (2.7.18) is kept so
        # computers that still have Python 2 can be brought up to it
        if ($IncludePython2) { $want = @($want) + '2.7'; $eolOf['2.7'] = '2020-01-01' }
        $want = @($want | Where-Object { $b = $_; $releases | Where-Object { $_.Branch -eq $b } } | Sort-Object { [version]$_ })
    }
    if (-not $want) { throw 'No Python versions to sync.' }

    # --- Newest release with Windows installers, per branch -----------------------------
    $plan = [ordered]@{}
    foreach ($b in $want) {
        $old = if ($existing -and $existing.Branches) { $existing.Branches.$b } else { $null }
        $candidates = @($releases | Where-Object { $_.Branch -eq $b } | Sort-Object Micro -Descending | Select-Object -First 30)
        if (-not $candidates) { Write-Log "  $b : python.org lists no releases for it; skipped." 'WARN'; continue }
        $skippedSource = @()
        foreach ($r in $candidates) {
            # The share already has this release (or a newer one) with every file present
            if ($old -and -not $Force -and [version]$old.Version -ge [version]$r.Version) {
                $complete = $true
                foreach ($a in $Architectures) {
                    $f = $old.Files.$a
                    if ($f -and -not (Test-Path -LiteralPath (Join-Path $DestinationPath $f.FileName))) { $complete = $false }
                }
                if ($PortablePackages -and -not $old.Portable) { $complete = $false }      # portable packages not fetched yet
                if ($complete) { $plan[$b] = [pscustomobject]@{ Keep = $old; Release = $null }; break }
            }
            $files = @(Get-Json "$ApiBase/release_file/?release=$($r.Id)")
            $win = @{}
            foreach ($a in $Architectures) {
                $f = $files | Where-Object { $InstallerName[$a] -contains $_.name -and $_.url -match '\.(exe|msi)$' } | Select-Object -First 1
                if ($f) { $win[$a] = $f }
            }
            if ($win.Count -eq 0) { $skippedSource += $r.Version; continue }
            $emb = @{}
            foreach ($a in $Architectures) {
                $f = $files | Where-Object { $_.name -eq $EmbedName[$a] -and $_.url -match '\.zip$' } | Select-Object -First 1
                if ($f) { $emb[$a] = $f }
            }
            $plan[$b] = [pscustomobject]@{ Keep = $null; Release = $r; Files = $win; Embeds = $emb }
            break
        }
        if ($skippedSource) { Write-Log "  $b : $($skippedSource -join ', ') $(if ($skippedSource.Count -eq 1) { 'is' } else { 'are' }) source-only (no Windows installers)." }
        if (-not $plan.Contains($b)) { Write-Log "  $b : no release with Windows installers found; skipped." 'WARN'; continue }
        $p = $plan[$b]
        if ($p.Keep) { Write-Log "  $b : $($p.Keep.Version) (already on the share)" }
        else { Write-Log "  $b : $($p.Release.Version) ($(@($p.Files.Keys) -join ', '))" }
    }
    if ($plan.Count -eq 0) { throw 'No Python version has Windows installers to sync.' }

    # --- Anything new? -------------------------------------------------------
    $toGet = @($plan.Keys | Where-Object { -not $plan[$_].Keep })
    $sameSet = $existing -and $existing.Branches -and
               ((@($existing.Branches.PSObject.Properties.Name) | Sort-Object) -join ',') -eq ((@($plan.Keys) | Sort-Object) -join ',')
    if ($toGet.Count -eq 0 -and $sameSet) {
        Write-Log 'Share already has these versions. Nothing to do.'
        exit 0
    }

    # --- Download, verify and publish each new release --------------------------------
    $branchesOut = [ordered]@{}
    foreach ($b in $plan.Keys) {
        $p = $plan[$b]
        if ($p.Keep) { $branchesOut[$b] = $p.Keep; continue }
        $r = $p.Release
        $verFolder = Join-Path $DestinationPath $r.Version
        $staging   = "$verFolder.partial"
        if (Test-Path $staging) { Remove-Item $staging -Recurse -Force }
        New-Item -ItemType Directory -Path $staging | Out-Null
        $filesOut = [ordered]@{}
        foreach ($a in $Architectures) {
            $f = $p.Files[$a]
            if (-not $f) { continue }
            $name  = Split-Path ([uri]$f.url).AbsolutePath -Leaf
            $local = Join-Path $tempDir $name
            Write-Log "Downloading $($r.Version) $a : $($f.url)"
            try { Save-Download -Url $f.url -OutFile $local }
            catch { Write-Log "  failed: $(Get-ErrorDetail $_); skipping $($r.Version) $a." 'WARN'; continue }
            if ($f.sha256_sum) {
                $hash = (Get-FileHash -LiteralPath $local -Algorithm SHA256).Hash
                if ($hash -ne ([string]$f.sha256_sum).ToUpper()) { throw "SHA-256 mismatch for $name. python.org lists $($f.sha256_sum), got $hash." }
                $how = "SHA-256 matches python.org"
            } elseif ($f.md5_sum) {
                $md5 = (Get-FileHash -LiteralPath $local -Algorithm MD5).Hash
                if ($md5 -ne ([string]$f.md5_sum).ToUpper()) { throw "MD5 mismatch for $name. python.org lists $($f.md5_sum), got $md5." }
                $how = "MD5 matches python.org"
            } else { $how = 'python.org lists no checksum' }
            $sig = Get-AuthenticodeSignature -FilePath $local
            $signed = $sig.Status -eq 'Valid' -and $sig.SignerCertificate.Subject -match $SignerPattern
            if (-not $signed) {
                $why = "Signature check failed for $name (status: $($sig.Status), signer: $($sig.SignerCertificate.Subject))"
                if (-not $AllowUnsigned -or $how -eq 'python.org lists no checksum') { throw "$why. If python.org simply didn't sign this (older) release, -AllowUnsigned accepts it on the strength of its checksum." }
                Write-Log "  $a : $why - accepted (-AllowUnsigned, $how)." 'WARN'
            }
            $sha = (Get-FileHash -LiteralPath $local -Algorithm SHA256).Hash
            Write-Log "  $a : $how; $(if ($signed) { "signed by $($sig.SignerCertificate.Subject)" } else { 'not signed' })"
            Copy-Item -LiteralPath $local -Destination (Join-Path $staging $name)
            $filesOut[$a] = [ordered]@{
                FileName       = Join-Path $r.Version $name
                Sha256         = $sha
                Version        = $r.Version
                ProductVersion = Get-ProductVersion $r.Version
                Signed         = [bool]$signed                    # clients check the signature only when this is true
                SourceUrl      = $f.url
            }
        }
        if ($filesOut.Count -eq 0) {
            Remove-Item $staging -Recurse -Force
            $old = if ($existing -and $existing.Branches) { $existing.Branches.$b } else { $null }
            if ($old) { Write-Log "  $b : nothing downloaded; keeping $($old.Version)." 'WARN'; $branchesOut[$b] = $old }
            else { Write-Log "  $b : nothing downloaded; left out." 'WARN' }
            continue
        }
        # --- Portable Python sources (embeddable zip + NuGet package) --------------------
        $portable = $null
        if ($PortablePackages) {
            $portable = [ordered]@{ Embed = [ordered]@{}; Full = [ordered]@{} }
            foreach ($a in $Architectures) {
                $e = $p.Embeds[$a]
                if ($e) {
                    $name = Split-Path ([uri]$e.url).AbsolutePath -Leaf
                    $local = Join-Path $staging $name
                    try {
                        Write-Log "Downloading $($r.Version) $a embeddable package: $($e.url)"
                        Save-Download -Url $e.url -OutFile $local
                        if ($e.sha256_sum) { $ok = (Get-FileHash -LiteralPath $local -Algorithm SHA256).Hash -eq ([string]$e.sha256_sum).ToUpper(); $how = 'SHA-256' }
                        elseif ($e.md5_sum) { $ok = (Get-FileHash -LiteralPath $local -Algorithm MD5).Hash -eq ([string]$e.md5_sum).ToUpper(); $how = 'MD5' }
                        else { $ok = $false; $how = 'no checksum listed' }
                        if (-not $ok) { throw "$how doesn't match python.org's" }
                        $portable.Embed[$a] = [ordered]@{ FileName = Join-Path $r.Version $name; Sha256 = (Get-FileHash -LiteralPath $local -Algorithm SHA256).Hash; Version = $r.Version }
                        Write-Log "  $a embeddable: $how matches python.org"
                    }
                    catch { Remove-Item -LiteralPath $local -Force -ErrorAction SilentlyContinue; Write-Log "  $a embeddable package: $(Get-ErrorDetail $_); left out." 'WARN' }
                }
                $id = $NuGetId[$r.Version.Split('.')[0]][$a]
                if ($id) {
                    $name = "$id.$($r.Version).nupkg"
                    $local = Join-Path $staging $name
                    try {
                        # nuget.org's SHA-512 for the package: registration -> catalog entry -> packageHash
                        $reg = Get-Json "$NuGetReg/$id/$($r.Version).json"
                        $cat = Get-Json ([string]$reg.catalogEntry)
                        if ($cat.packageHashAlgorithm -ne 'SHA512' -or -not $cat.packageHash) { throw "nuget.org gives no SHA-512 for $id $($r.Version)" }
                        Write-Log "Downloading $($r.Version) $a NuGet package: $NuGetFlat/$id/$($r.Version)/$name"
                        Save-Download -Url "$NuGetFlat/$id/$($r.Version)/$name" -OutFile $local
                        $sha512 = [Convert]::ToBase64String((New-Object Security.Cryptography.SHA512Managed).ComputeHash([IO.File]::ReadAllBytes($local)))
                        if ($sha512 -ne [string]$cat.packageHash) { throw "SHA-512 doesn't match nuget.org's" }
                        $portable.Full[$a] = [ordered]@{ FileName = Join-Path $r.Version $name; Sha256 = (Get-FileHash -LiteralPath $local -Algorithm SHA256).Hash; Version = $r.Version; NuGetId = $id }
                        Write-Log "  $a NuGet ($id): SHA-512 matches nuget.org"
                    }
                    catch { Remove-Item -LiteralPath $local -Force -ErrorAction SilentlyContinue; Write-Log "  $a NuGet package $id $($r.Version): $(Get-ErrorDetail $_); left out." 'WARN' }
                }
            }
        }
        if (Test-Path $verFolder) { Remove-Item $verFolder -Recurse -Force }
        Rename-Item -Path $staging -NewName $r.Version
        $branchesOut[$b] = [ordered]@{
            Version        = $r.Version
            ProductVersion = Get-ProductVersion $r.Version
            ReleaseDate    = $r.Date
            EndOfLife      = $eolOf[$b]
            Files          = $filesOut
        }
        if ($portable) { $branchesOut[$b].Portable = $portable }    # for Apps\PythonPortable.ps1
    }
    if ($branchesOut.Count -eq 0) { throw 'Nothing to publish.' }

    $versions = @($branchesOut.Keys | Sort-Object { [version]$_ } | ForEach-Object { $branchesOut[$_].Version })
    $manifest = [ordered]@{
        Product   = 'Python'
        Version   = $versions -join ', '                       # summary, e.g. "3.12.10, 3.13.11, 3.14.8"
        UpdatedAt = (Get-Date).ToString('o')
        Branches  = $branchesOut                               # per Python version: Version, ProductVersion, Files.<arch>
    }
    $tmp = "$manifestPath.tmp"
    $manifest | ConvertTo-Json -Depth 6 | Set-Content -Path $tmp -Encoding UTF8
    Move-Item -Path $tmp -Destination $manifestPath -Force
    Write-Log "Published Python $($versions -join ', ') and updated manifest."

    # --- Prune old versions (per branch) ------------------------------------------
    $inUse = @($branchesOut.Values | ForEach-Object { $_.Version })
    Get-ChildItem -Path $DestinationPath -Directory |
        Where-Object { $_.Name -match '^[23]\.\d+\.\d+$' } |
        Group-Object { ($_.Name -split '\.')[0..1] -join '.' } |
        ForEach-Object {
            $_.Group | Sort-Object { [version]$_.Name } -Descending | Select-Object -Skip $KeepVersions |
                Where-Object { $inUse -notcontains $_.Name } |
                ForEach-Object { Write-Log "Removing old version folder $($_.Name)"; Remove-Item $_.FullName -Recurse -Force }
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
            Invoke-OTTOIntunePackageBuild -AppId 'Python' -DestinationPath $DestinationPath -OutputPath $IntuneOutputPath `
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
            Update-OTTOCatalogEntry -AppId 'Python' -DestinationPath $DestinationPath -ManifestBefore $script:ManifestBefore `
                -Failed ([bool]($script:SyncFailed -or $script:IntuneFailed)) -Script 'Sync\Python.ps1' `
                -BoundParameters $PSBoundParameters -CatalogPath $CatalogPath -Definition $OTTOAppDefinition -ScriptPath $PSCommandPath -Log { param($m, $l) Write-Log $m $l }
        }
        catch { Write-Log "Couldn't update the repo catalog: $($_.Exception.Message)" 'WARN' }
    }
    # Release the one-sync-per-share lock (it would otherwise stay held until this PowerShell
    # window closes, so a second run in the same window would think a sync is still running)
    if ($script:SyncLock) { $script:SyncLock.Dispose(); $script:SyncLock = $null }
    if ($script:IntuneFailed) { exit 1 }
}
