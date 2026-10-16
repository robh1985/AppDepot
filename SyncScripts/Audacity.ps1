<#
.SYNOPSIS
    SERVER SCRIPT - Keeps a network share stocked with the latest Audacity installers for
    Windows, for each Audacity major version ("track") you choose.

.DESCRIPTION
    Audacity 3 and Audacity 4 are separate products on Windows:
      Audacity 4.x - WiX MSI  (audacity-win-<ver>-x86_64.msi / -arm64.msi),
                     installs to Program Files\Audacity 4, shows as "Audacity 4.0"
      Audacity 3.x - Inno Setup EXE (audacity-win-<ver>-64bit.exe / -32bit.exe / -arm64.exe),
                     installs to Program Files\Audacity, shows as "Audacity 3.7.x"
    Audacity 3 is still maintained, and 4 doesn't replace it (they install side by side), so
    this script keeps the newest release of EACH track listed in -Tracks. The client script
    keeps every machine on its own track unless told otherwise (Apps\Audacity.ps1
    -Install 4 moves a machine to Audacity 4 and removes 3).

    This script:
    - Reads the Audacity releases from GitHub (github.com/audacity/audacity), ignoring
      drafts and pre-releases, and picks the newest release of each track.
    - Skips an installer the share already has.
    - Otherwise downloads it (progress logging, stall timeout), checks its SHA-256 against
      GitHub's published digest / the release's CHECKSUMS.txt, checks its Authenticode
      signature (MUSECY SM LTD - Muse Group), reads the MSI's ProductVersion and codes,
      and publishes it to <DestinationPath>\<track>\<version>\<file>.
    - Writes latest.json last. Keeps the newest -KeepVersions version folders per track.

    Dropping a track from -Tracks removes it from latest.json, so clients on that track move
    to the newest track on their next run (e.g. -Tracks 4 moves everyone to Audacity 4).

.PARAMETER DestinationPath
    Folder (local path or UNC) where the installers are stored.
    Optional: if it's left out, the folder comes from the repo catalog
    (OTTOUpdate-Catalog.json): this app's Folder there (its full path), or
    <RepoRoot>\Applications\Audacity if the app isn't in the catalog yet. The catalog is found
    automatically when this script runs from <RepoRoot>\Administrative\Sync;
    otherwise pass -CatalogPath.

.PARAMETER CatalogPath
    The repo catalog to take the folder from when -DestinationPath isn't given, e.g.
    \\fileserver\Software\OTTOUpdate-Catalog.json. Default: <RepoRoot>\OTTOUpdate-Catalog.json
    when this script is in <RepoRoot>\Administrative\Sync.

.PARAMETER Tracks
    Audacity major versions to keep, newest first. Default: 4, 3.

.PARAMETER Architectures
    Which builds to keep: x64, arm64, x86. Default: all three (Audacity 4 has no 32-bit
    build; 32-bit Windows gets Audacity 3).

.PARAMETER KeepVersions
    How many version folders to keep per track. Default: 2.

.PARAMETER GitHubToken
    Optional GitHub token, only needed if the server hits GitHub's anonymous rate limit
    (60 requests per hour per IP address; this script makes one or two per run).

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
    on the share: <IntuneOutputPath>\Audacity\<date>\ gets Audacity-<date>.intunewin,
    Detect-Audacity.ps1 (custom detection script) and README-Audacity.txt (the install/uninstall
    commands, return codes and detection settings to enter in Intune). Nothing is rebuilt
    if that package already exists (unless -Force). Needs <RepoRoot>\Administrative\Shared\OTTOUpdate-Common.ps1 and the app's client script (catalog ClientScript, normally Apps\Audacity.ps1).

.PARAMETER IntuneOutputPath
    Where Intune packages are written. Default: <DestinationPath>\Intune

.PARAMETER ClientScriptPath
    Client script to put in the package. Default: the app's client script from the catalog (Apps\Audacity.ps1 under <RepoRoot>\Administrative).

.PARAMETER IntuneWinAppUtilPath
    Path to IntuneWinAppUtil.exe (Microsoft Win32 Content Prep Tool). Default: the repo's
    shared copy, <RepoRoot>\Tools\IntuneWinAppUtil.exe (<RepoRoot> = the parent of
    -DestinationPath), which Update-IntuneWinAppUtil.ps1 downloads if it's missing.

.EXAMPLE
    # Keep the newest Audacity 4 and Audacity 3 on the share
    .\Sync\Audacity.ps1 -DestinationPath '\\fileserver\Software\Applications\Audacity'

.EXAMPLE
    # Audacity 4 only (clients still on 3.x will be moved to 4)
    .\Sync\Audacity.ps1 -DestinationPath '\\fileserver\Software\Applications\Audacity' -Tracks 4

.EXAMPLE
    # Sync, then build the Intune package (.intunewin + detection script + README)
    .\Sync\Audacity.ps1 -DestinationPath '\\fileserver\Software\Applications\Audacity' -BuildIntunePackage
#>
[CmdletBinding()]
param(
    [string]$DestinationPath,

    [string]$CatalogPath,

    [ValidatePattern('^\d+$')]
    [string[]]$Tracks = @('4', '3'),

    [ValidateSet('x64', 'arm64', 'x86')]
    [string[]]$Architectures = @('x64', 'arm64', 'x86'),

    [ValidateRange(1, 20)]
    [int]$KeepVersions = 2,

    [string]$GitHubToken,

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
    AppId        = 'Audacity'
    Name         = 'Audacity'
    SyncScript   = 'Sync\Audacity.ps1'
    ClientScript = 'Apps\Audacity.ps1'
    Intune       = @{
        # Install command arguments after the script name. '-SourcePath .' becomes the repo path
        # plus the package's own copy as the fallback.
        InstallCommand  = '-SourcePath . -Install'
        InstallVariants = @(
            '-SourcePath . -Install -ConvertToNativeArchitecture   (replace an installed copy of another architecture, e.g. 32-bit, with the build for this Windows)',
            '-SourcePath . -Install 4   (move every computer to Audacity 4 and remove Audacity 3; set $Required = @(''4'') in the detection script)',
            '-SourcePath . -Install 3   (keep or put computers on Audacity 3; set $Required = @(''3''))',
            '-SourcePath . -Install -CloseRunning   (closes Audacity - unsaved work is lost)'
        )
        # The app's Programs and Features entries (regular expressions), for detection logging and uninstall
        Match           = @{ Pattern = '^Audacity \d'; Exclude = ''; KeyPattern = ''; Exe = '' }
        Detection       = @{
            # How it's detected, as written in Detect.log. Empty = the built-in check of the
            # Programs and Features entry (Match.Pattern) and, if newer, Match.Exe's file version
            Description     = 'Programs and Features entry, compared per major version (Audacity 3 / 4)'
            # Several versions side by side, each compared with its own repo version ($Required)
            SeveralVersions = $true
            # What $Required is when the detection script's $Required line is left at $null
            DefaultRequired = '@()'
            # Runs before the repo is read; may Pass or Fail straight away
            PreCheck        = ''
            # Sets $have when the repo can't be read. Empty = the Programs and Features check
            Offline         = ''
            # The check: compares what's installed with $Manifest (the repo's latest.json) and
            # ends with Test-Current / Test-CurrentSet. Empty = the built-in check
            Code            = @'
# Audacity 3 and 4 are separate products ("tracks"); the installed track is compared with
# the repo version of that same track. $Required = @('4') makes Audacity 4 the one that
# must be installed (use it with an -Install 4 install command).
$tracks = @($Manifest.Tracks.PSObject.Properties.Name | Sort-Object { [int]$_ } -Descending)
$copies = @(Get-Uninstall | Where-Object {
        ($_.KeyName -match '_is1$' -and $_.Name -match '^Audacity\b') -or
        ($_.IsMsi -and $_.Name -match '^Audacity \d' -and $_.Publisher -match '^Audacity|Muse') } |
    ForEach-Object { $_ | Add-Member -NotePropertyName Track -NotePropertyValue ([regex]::Match($_.VersionText, '^\d+').Value) -PassThru })
$newest = $tracks | Where-Object { Select-ArchEntry $Manifest.Tracks.$_.Files } | Select-Object -First 1
$target = if ($Required.Count) { [string]$Required[0] }
          elseif ($copies.Count) {
              $t = ($copies | Sort-Object { [int]("0" + $_.Track) } -Descending | Select-Object -First 1).Track
              if ($tracks -contains $t -and (Select-ArchEntry $Manifest.Tracks.$t.Files)) { $t } else { $newest } }
          else { $newest }
$entry = Select-ArchEntry $Manifest.Tracks.$target.Files
$have  = $copies | Where-Object { $_.Track -eq $target } | Sort-Object Version -Descending | Select-Object -First 1
Note "  Audacity installed: $(if ($copies) { ($copies | ForEach-Object { "$($_.Name) $($_.VersionText)" }) -join '; ' } else { 'none' }); checking track $target"
Test-Current $(if ($have) { 'Audacity' } else { "Audacity $target" }) $have.VersionText $entry.Version
'@
        }
        Uninstall       = @{
            # Silent arguments for uninstallers that aren't MSI
            ExeArgs      = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART'
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
                    "Pass -DestinationPath <share>\Audacity, or -CatalogPath <RepoRoot>\OTTOUpdate-Catalog.json " +
                    "(found automatically when this script runs from <RepoRoot>\Administrative\Sync).") -ForegroundColor Red
        exit 1
    }
    try { $catalogData = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $CatalogPath).ProviderPath) | ConvertFrom-Json }
    catch { Write-Host "The repo catalog $CatalogPath can't be read: $($_.Exception.Message). Pass -DestinationPath instead." -ForegroundColor Red; exit 1 }
    $catalogEntry = @($catalogData.Apps) | Where-Object { $_ -and [string]$_.AppId -eq 'Audacity' } | Select-Object -First 1
    $catalogFolder = if ($catalogEntry -and $catalogEntry.Folder) { [string]$catalogEntry.Folder } else { 'Applications\Audacity' }
    # Folder is the app's full path (e.g. \\fileserver\Software\Applications\Chrome); older catalogs hold a name under the repo root
    $DestinationPath = if ($catalogFolder -match '^\\\\' -or [IO.Path]::IsPathRooted($catalogFolder)) { $catalogFolder }
                       else { Join-Path (Split-Path (Resolve-Path -LiteralPath $CatalogPath).ProviderPath -Parent) $catalogFolder }
    Write-Host ("-DestinationPath from the repo catalog: $DestinationPath" + $(if (-not $catalogEntry) { " (Audacity isn't in the catalog yet; it's added after this sync writes latest.json)" }))
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

$ReleasesApi   = 'https://api.github.com/repos/audacity/audacity/releases?per_page=100'
$SignerPattern = 'MUSECY|Muse Group'
$UserAgent     = 'Sync-AudacityRepo.ps1 (PowerShell)'
# Windows installer file names: audacity-win-<version>-<arch>.<msi|exe>
$ArchNames     = @{ 'x86_64' = 'x64'; 'x64' = 'x64'; '64bit' = 'x64'; 'arm64' = 'arm64'; 'aarch64' = 'arm64'; '32bit' = 'x86'; 'x86' = 'x86' }

# --- Helpers -----------------------------------------------------------------
if (-not (Test-Path $DestinationPath)) { New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null }
$logDir = Join-Path $DestinationPath 'Logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$LogFile = Join-Path $logDir 'Sync-AudacityRepo.log'

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

function Get-Text([string]$Url) {
    $tmp = Join-Path $tempDir ([guid]::NewGuid().ToString('N') + '.txt')
    Save-Download -Url $Url -OutFile $tmp
    try { return [IO.File]::ReadAllText($tmp) } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
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

function Get-AudacityReleases {
    # Final (non-draft, non-pre-release) Audacity releases, newest first, with their
    # Windows installers per architecture.
    $headers = @{ 'User-Agent' = $UserAgent; 'Accept' = 'application/vnd.github+json' }
    if ($GitHubToken) { $headers['Authorization'] = "Bearer $GitHubToken" }
    $list = Invoke-RestMethod -Uri $ReleasesApi -Headers $headers -TimeoutSec $PageTimeoutSec
    # Assign first, then enumerate: 5.1 and 7 differ in how a JSON array comes down the pipeline
    $out = @()
    foreach ($r in @($list) | ForEach-Object { $_ }) {
        if ($r.draft -or $r.prerelease) { continue }
        $m = [regex]::Match([string]$r.tag_name, '^Audacity-(\d+\.\d+\.\d+(?:\.\d+)?)$')
        if (-not $m.Success) { continue }
        $ver = $m.Groups[1].Value
        $win = @{}
        foreach ($a in @($r.assets)) {
            $am = [regex]::Match([string]$a.name, '^audacity-win-' + [regex]::Escape($ver) + '-(?<arch>[A-Za-z0-9_]+)\.(?<ext>msi|exe)$')
            if (-not $am.Success) { continue }
            $arch = $ArchNames[$am.Groups['arch'].Value.ToLower()]
            if (-not $arch) { continue }
            $type = if ($am.Groups['ext'].Value -eq 'msi') { 'msi' } else { 'inno' }
            # Prefer the MSI if a release ever has both for one architecture
            if ($win[$arch] -and $win[$arch].Type -eq 'msi') { continue }
            $digest = if ([string]$a.digest -match '^sha256:([0-9a-fA-F]{64})$') { $Matches[1].ToUpper() } else { $null }
            $win[$arch] = [pscustomobject]@{ Name = $a.name; Url = $a.browser_download_url; Size = $a.size; Type = $type; Digest = $digest }
        }
        $sums = @($r.assets) | Where-Object { $_.name -eq 'CHECKSUMS.txt' } | Select-Object -First 1
        $out += [pscustomobject]@{
            Tag = $r.tag_name; Version = $ver; Track = $ver.Split('.')[0]; Published = $r.published_at
            Windows = $win; ChecksumsUrl = if ($sums) { $sums.browser_download_url } else { $null }
        }
    }
    return $out | Sort-Object { ConvertTo-Version $_.Version } -Descending
}

function Get-Checksums([string]$Url) {
    # CHECKSUMS.txt: "<name>   <length>   <sha256>" per line
    $map = @{}
    if (-not $Url) { return $map }
    try {
        foreach ($line in (Get-Text $Url) -split "`r?`n") {
            $m = [regex]::Match($line, '^\s*(\S+)\s+\d+\s+([0-9a-fA-F]{64})\s*$')
            if ($m.Success) { $map[$m.Groups[1].Value] = $m.Groups[2].Value.ToUpper() }
        }
    }
    catch { Write-Log "  Could not read CHECKSUMS.txt: $(Get-ErrorDetail $_)" 'WARN' }
    return $map
}

# --- Main --------------------------------------------------------------------
$tempDir = Join-Path $env:TEMP "audacity-sync-$([guid]::NewGuid().ToString('N'))"
try {
    # latest.json as it was before this run, for the repo catalog (see the end of the script)
    $script:ManifestBefore = $null
    try {
        $manifestBeforePath = Join-Path $DestinationPath 'latest.json'
        if (Test-Path -LiteralPath $manifestBeforePath) { $script:ManifestBefore = Get-Content -LiteralPath $manifestBeforePath -Raw }
    }
    catch { }
    Write-Log "---- Sync started. Destination: $DestinationPath  Tracks: $($Tracks -join ', ')  Architectures: $($Architectures -join ', ')"
    New-Item -ItemType Directory -Path $tempDir | Out-Null

    $manifestPath = Join-Path $DestinationPath 'latest.json'
    $existing = $null
    if (Test-Path $manifestPath) {
        try { $existing = Get-Content $manifestPath -Raw | ConvertFrom-Json }
        catch { Write-Log "Existing manifest is unreadable and will be replaced: $_" 'WARN' }
    }
    if ($existing -and $existing.Tracks) {
        Write-Log "On share: $(($existing.Tracks.PSObject.Properties | ForEach-Object { "Audacity $($_.Value.Release)" }) -join ', ')"
    } else { Write-Log 'On share: nothing yet.' }

    Write-Log "Reading Audacity releases from GitHub..."
    $releases = @(Get-AudacityReleases)
    if ($releases.Count -eq 0) { throw 'GitHub returned no Audacity releases.' }

    $tracksOut = [ordered]@{}
    $changed   = $false
    foreach ($track in ($Tracks | Sort-Object { [int]$_ } -Descending)) {
        $prevTrack = if ($existing -and $existing.Tracks) { $existing.Tracks.$track } else { $null }
        $files = [ordered]@{}
        if ($prevTrack -and $prevTrack.Files) { foreach ($p in $prevTrack.Files.PSObject.Properties) { if ($Architectures -contains $p.Name) { $files[$p.Name] = $p.Value } } }

        $rel = $releases | Where-Object { $_.Track -eq $track -and $_.Windows.Count -gt 0 } | Select-Object -First 1
        if (-not $rel) {
            Write-Log "Track $track : no final Audacity $track.x release with Windows installers on GitHub." 'WARN'
            if ($files.Count) { $tracksOut[$track] = [ordered]@{ Release = $prevTrack.Release; PublishedAt = $prevTrack.PublishedAt; Files = $files } }
            continue
        }
        Write-Log "Track $track : latest is Audacity $($rel.Version) ($($rel.Published)); Windows builds: $(($rel.Windows.Keys | Sort-Object) -join ', ')"
        $sums = $null

        foreach ($arch in $Architectures) {
            $asset = $rel.Windows[$arch]
            if (-not $asset) {
                if (-not $files[$arch]) { Write-Log "  $arch : Audacity $track has no $arch build." }
                else { Write-Log "  $arch : Audacity $($rel.Version) has no $arch build; keeping $($files[$arch].Release)." 'WARN' }
                continue
            }
            try {
                $prev = $files[$arch]
                if (-not $Force -and $prev -and $prev.Release -eq $rel.Version -and (Test-Path -LiteralPath (Join-Path $DestinationPath $prev.FileName))) {
                    Write-Log "  $arch : $($asset.Name) already on the share."
                    continue
                }

                # Expected SHA-256: GitHub's digest, else the release's CHECKSUMS.txt
                $expected = $asset.Digest
                if (-not $expected) {
                    if ($null -eq $sums) { $sums = Get-Checksums $rel.ChecksumsUrl }
                    $expected = $sums[$asset.Name]
                }
                if (-not $expected) { throw "no published SHA-256 for $($asset.Name) (GitHub digest / CHECKSUMS.txt)." }

                $local = Join-Path $tempDir $asset.Name
                Write-Log ("  {0} : downloading {1} ({2:N0} MB)" -f $arch, $asset.Name, ($asset.Size / 1MB))
                Save-Download -Url $asset.Url -OutFile $local
                $hash = (Get-FileHash -LiteralPath $local -Algorithm SHA256).Hash
                if ($hash -ne $expected) { throw "SHA-256 mismatch. Published: $expected  Downloaded: $hash" }
                $sig = Get-AuthenticodeSignature -FilePath $local
                if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch $SignerPattern) {
                    throw "signature check failed (status: $($sig.Status), signer: $($sig.SignerCertificate.Subject))."
                }

                $entry = [ordered]@{
                    Type        = $asset.Type             # msi (Audacity 4+) or inno (Audacity 3)
                    Release     = $rel.Version            # e.g. 4.0.1
                    Version     = $rel.Version            # what Programs and Features shows (MSI: ProductVersion)
                    FileName    = Join-Path $track (Join-Path $rel.Version $asset.Name)
                    Sha256      = $hash
                    SourceUrl   = $asset.Url
                }
                if ($asset.Type -eq 'msi') {
                    $entry.Version     = Get-MsiProperty $local 'ProductVersion'
                    $entry.ProductName = Get-MsiProperty $local 'ProductName'
                    $entry.ProductCode = Get-MsiProperty $local 'ProductCode'
                    $entry.UpgradeCode = Get-MsiProperty $local 'UpgradeCode'
                }

                $verDir = Join-Path $DestinationPath (Join-Path $track $rel.Version)
                New-Item -ItemType Directory -Path $verDir -Force | Out-Null
                $final = Join-Path $verDir $asset.Name
                Copy-Item -LiteralPath $local -Destination "$final.partial" -Force
                Move-Item -LiteralPath "$final.partial" -Destination $final -Force
                $files[$arch] = $entry
                $changed = $true
                Write-Log "  $arch : published $($asset.Name) (version $($entry.Version)); SHA-256 matches; signed by $($sig.SignerCertificate.Subject)."
            }
            catch { Write-Log "  $arch failed: $(Get-ErrorDetail $_). Keeping what's on the share." 'WARN' }
        }

        if ($files.Count -gt 0) {
            $newest = $files.Values | Sort-Object { ConvertTo-Version $_.Release } -Descending | Select-Object -First 1
            $tracksOut[$track] = [ordered]@{
                Release     = $newest.Release
                PublishedAt = if ($newest.Release -eq $rel.Version) { $rel.Published } elseif ($prevTrack) { $prevTrack.PublishedAt } else { $null }
                Files       = $files
            }
        }
    }

    # Tracks dropped from -Tracks
    if ($existing -and $existing.Tracks) {
        foreach ($p in $existing.Tracks.PSObject.Properties) {
            if (-not $tracksOut.Contains($p.Name)) {
                Write-Log "Track $($p.Name) is no longer in -Tracks; removing it from latest.json (its folder is left on the share). Clients on Audacity $($p.Name) will move to the newest track." 'WARN'
                $changed = $true
            }
        }
    }
    if ($tracksOut.Count -eq 0) { throw 'No installers are available for any track.' }

    if ($changed -or -not $existing) {
        $manifest = [ordered]@{
            Product     = 'Audacity'
            UpdatedAt   = (Get-Date).ToString('o')
            NewestTrack = @($tracksOut.Keys | Sort-Object { [int]$_ } -Descending)[0]
            Tracks      = $tracksOut
        }
        $tmp = "$manifestPath.tmp"
        $manifest | ConvertTo-Json -Depth 6 | Set-Content -Path $tmp -Encoding UTF8
        Move-Item -Path $tmp -Destination $manifestPath -Force
        Write-Log "Manifest updated: $(($tracksOut.Keys | ForEach-Object { "track $_ = $($tracksOut[$_].Release) ($(($tracksOut[$_].Files.Keys) -join ', '))" }) -join '; ')."
    }
    else { Write-Log 'Nothing changed.' }

    # --- Prune old version folders per track (never ones in use) ---------------
    foreach ($track in $tracksOut.Keys) {
        $trackDir = Join-Path $DestinationPath $track
        if (-not (Test-Path -LiteralPath $trackDir)) { continue }
        $inUse = @($tracksOut[$track].Files.Values | ForEach-Object { Split-Path (Split-Path $_.FileName -Parent) -Leaf } | Sort-Object -Unique)
        Get-ChildItem -LiteralPath $trackDir -Directory |
            Where-Object { $_.Name -match '^\d+(\.\d+){1,3}$' -and $inUse -notcontains $_.Name } |
            Sort-Object { ConvertTo-Version $_.Name } -Descending |
            Select-Object -Skip ([math]::Max(0, $KeepVersions - $inUse.Count)) |
            ForEach-Object { Write-Log "Removing old version folder $track\$($_.Name)"; Remove-Item $_.FullName -Recurse -Force }
        Get-ChildItem -LiteralPath $trackDir -Recurse -Filter '*.partial' -File | Remove-Item -Force -ErrorAction SilentlyContinue
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
            Invoke-OTTOIntunePackageBuild -AppId 'Audacity' -DestinationPath $DestinationPath -OutputPath $IntuneOutputPath `
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
            Update-OTTOCatalogEntry -AppId 'Audacity' -DestinationPath $DestinationPath -ManifestBefore $script:ManifestBefore `
                -Failed ([bool]($script:SyncFailed -or $script:IntuneFailed)) -Script 'Sync\Audacity.ps1' `
                -BoundParameters $PSBoundParameters -CatalogPath $CatalogPath -Definition $OTTOAppDefinition -ScriptPath $PSCommandPath -Log { param($m, $l) Write-Log $m $l }
        }
        catch { Write-Log "Couldn't update the repo catalog: $($_.Exception.Message)" 'WARN' }
    }
    # Release the one-sync-per-share lock (it would otherwise stay held until this PowerShell
    # window closes, so a second run in the same window would think a sync is still running)
    if ($script:SyncLock) { $script:SyncLock.Dispose(); $script:SyncLock = $null }
    if ($script:IntuneFailed) { exit 1 }
}
