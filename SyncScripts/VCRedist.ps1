<#
.SYNOPSIS
    SERVER SCRIPT - Keeps a network share stocked with the latest Microsoft Visual C++
    Redistributable installers for every runtime family: 2005, 2008, 2010, 2012, 2013 and
    2015-2022 ("v14"), in x86 / x64 (and ARM64 for v14).

.DESCRIPTION
    Download links are Microsoft's, from "Latest supported Visual C++ Redistributable
    downloads" (learn.microsoft.com/cpp/windows/latest-supported-vc-redist):
      v14 (2015-2022)  aka.ms/vc14/vc_redist.<x86|x64|arm64>.exe   (updated regularly)
      2013             12.0.40664  aka.ms/highdpimfc2013<x86|x64>enu
      2012 Update 4    11.0.61030  download.microsoft.com/.../VSU_4/vcredist_<arch>.exe
      2010 SP1         10.0.40219.325
      2008 SP1         9.0.30729.x
      2005 SP1 (MFC security update) 8.0.61001
    2005-2013 are no longer supported by Microsoft and their final versions don't change,
    but they're kept here because older apps still need them.

    This script:
    - Sends a HEAD request for each installer and skips it if unchanged since the last
      run (ETag / Last-Modified / size) and still on the share.
    - Otherwise downloads it (progress logging, stall timeout), checks its Authenticode
      signature (Microsoft), reads the runtime version from the file (falling back to
      the known final version for the 2005 package, whose file version isn't the
      runtime version), and publishes it to <DestinationPath>\<family>\<version>\.
    - Writes latest.json last. Keeps the newest -KeepVersions versions per family.

    Folder layout:
        <DestinationPath>\v14\14.44.35211.0\vc_redist.x64.exe  (x86, arm64)
        <DestinationPath>\2013\12.0.40664.0\vcredist_x64.exe   (x86)
        ... 2012, 2010, 2008, 2005 ...
        <DestinationPath>\latest.json
        <DestinationPath>\Logs\Sync-VCRedistRepo.log

.PARAMETER DestinationPath
    Folder (local path or UNC) where the installers are stored.
    Optional: if it's left out, the folder comes from the repo catalog
    (OTTOUpdate-Catalog.json): this app's Folder there (its full path), or
    <RepoRoot>\Applications\VCRedist if the app isn't in the catalog yet. The catalog is found
    automatically when this script runs from <RepoRoot>\Administrative\Sync;
    otherwise pass -CatalogPath.

.PARAMETER CatalogPath
    The repo catalog to take the folder from when -DestinationPath isn't given, e.g.
    \\fileserver\Software\OTTOUpdate-Catalog.json. Default: <RepoRoot>\OTTOUpdate-Catalog.json
    when this script is in <RepoRoot>\Administrative\Sync.

.PARAMETER Families
    Which runtime families to keep. Default: all (2005, 2008, 2010, 2012, 2013, v14).

.PARAMETER KeepVersions
    How many versions to keep per family. Default: 2.

.PARAMETER Proxy
    Proxy server for internet access, e.g. http://proxy.contoso.local:8080.

.PARAMETER ProxyUseDefaultCredentials
    Authenticate to the proxy as the account running the script.

.PARAMETER PageTimeoutSec
    Seconds to wait for a server to respond / a download to start. Default: 60.

.PARAMETER StallTimeoutSec
    Give up on a download if no data arrives for this many seconds. Default: 120.

.PARAMETER Force
    Download and republish even if nothing appears to have changed.

.PARAMETER BuildIntunePackage
    After a successful sync, also build a Microsoft Intune Win32 app package from what is
    on the share: <IntuneOutputPath>\VCRedist\<version>\ gets VCRedist-<version>.intunewin,
    Detect-VCRedist.ps1 (custom detection script) and README-VCRedist.txt (the install/uninstall
    commands, return codes and detection settings to enter in Intune). Nothing is rebuilt
    if that version's package already exists (unless -Force). Needs <RepoRoot>\Administrative\Shared\OTTOUpdate-Common.ps1 and the app's client script (catalog ClientScript, normally Apps\VCRedist.ps1).

.PARAMETER IntuneOutputPath
    Where Intune packages are written. Default: <DestinationPath>\Intune

.PARAMETER ClientScriptPath
    Client script to put in the package. Default: the app's client script from the catalog (Apps\VCRedist.ps1 under <RepoRoot>\Administrative).

.PARAMETER IntuneWinAppUtilPath
    Path to IntuneWinAppUtil.exe (Microsoft Win32 Content Prep Tool). Default: the repo's
    shared copy, <RepoRoot>\Tools\IntuneWinAppUtil.exe (<RepoRoot> = the parent of
    -DestinationPath), which Update-IntuneWinAppUtil.ps1 downloads if it's missing.

.EXAMPLE
    .\Sync\VCRedist.ps1 -DestinationPath '\\fileserver\Software\Applications\VCRedist'

.EXAMPLE
    # Sync, then build the Intune package (.intunewin + detection script + README)
    .\Sync\VCRedist.ps1 -DestinationPath '\\fileserver\Software\Applications\VCRedist' -BuildIntunePackage
#>
[CmdletBinding()]
param(
    [string]$DestinationPath,

    [string]$CatalogPath,

    [ValidateSet('2005', '2008', '2010', '2012', '2013', 'v14')]
    [string[]]$Families = @('2005', '2008', '2010', '2012', '2013', 'v14'),

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
    AppId        = 'VCRedist'
    Name         = 'Microsoft Visual C++ Redistributables'
    SyncScript   = 'Sync\VCRedist.ps1'
    ClientScript = 'Apps\VCRedist.ps1'
    Intune       = @{
        # Install command arguments after the script name. '-SourcePath .' becomes the repo path
        # plus the package's own copy as the fallback.
        InstallCommand  = '-SourcePath . -Install v14'
        InstallVariants = @(
            '-SourcePath . -Install v14,2013,2010',
            '-SourcePath .   (update installed runtimes only)'
        )
        # The app's Programs and Features entries (regular expressions), for detection logging and uninstall
        Match           = @{ Pattern = '^Microsoft Visual C\+\+ 20(1[5-9]|2\d)(-20\d\d)? Redistributable'; Exclude = ''; KeyPattern = ''; Exe = '' }
        Detection       = @{
            # How it's detected, as written in Detect.log. Empty = the built-in check of the
            # Programs and Features entry (Match.Pattern) and, if newer, Match.Exe's file version
            Description     = 'Programs and Features entries, each runtime family and architecture compared separately'
            # Several versions side by side, each compared with its own repo version ($Required)
            SeveralVersions = $true
            # What $Required is when the detection script's $Required line is left at $null
            DefaultRequired = '@(''v14'')'
            # Runs before the repo is read; may Pass or Fail straight away
            PreCheck        = ''
            # Sets $have when the repo can't be read. Empty = the Programs and Features check
            Offline         = ''
            # The check: compares what's installed with $Manifest (the repo's latest.json) and
            # ends with Test-Current / Test-CurrentSet. Empty = the built-in check
            Code            = @'
# Each installed runtime is compared with its repo version. $Required = runtime families that
# must be installed (match -Install in your Intune install command).
# Programs and Features records fewer version parts than the runtime files for some
# families (2010: 10.0.40219 vs 10.0.40219.325), so compare only the parts it records.
$UseInstalledPrecision = $true
$os = Get-OSArch
$fits = switch ($os) { 'x86' { @('x86') } 'x64' { @('x86', 'x64') } 'arm64' { @('x86', 'x64', 'arm64') } }
$rows = @()
foreach ($e in Get-Uninstall) {
    $m = [regex]::Match($e.Name, '^Microsoft Visual C\+\+ (?<y>20\d\d)(?:-20\d\d)?\b')
    if (-not $m.Success -or $e.Name -notmatch 'Redistributable' -or $e.Name -match 'Debug|Minimum Runtime|Additional Runtime') { continue }
    $y = [int]$m.Groups['y'].Value
    $fam = if ($y -ge 2015) { 'v14' } else { "$y" }
    $a = if ($e.Name -match 'ARM64') { 'arm64' } elseif ($e.Name -match 'x64') { 'x64' } else { 'x86' }
    $rows += [pscustomobject]@{ Family = $fam; Arch = $a; Version = $e.VersionText }
}
$items = @()
foreach ($fam in @($Manifest.Families.PSObject.Properties.Name)) {
    foreach ($a in $fits) {
        $entry = $Manifest.Families.$fam.Files.$a
        if (-not $entry) { continue }
        if ($a -eq 'arm64' -and $fam -ne 'v14') { continue }
        $have = $rows | Where-Object { $_.Family -eq $fam -and $_.Arch -eq $a } | Sort-Object { ConvertTo-Version $_.Version } -Descending | Select-Object -First 1
        if ($have -or ($Required -contains $fam -and $a -ne 'arm64')) { $items += [pscustomobject]@{ Name = "Visual C++ $fam $a"; Have = $have.Version; Want = $entry.Version } }
    }
}
Test-CurrentSet 'Visual C++ runtimes' $items
'@
        }
        Uninstall       = @{
            # Silent arguments for uninstallers that aren't MSI
            ExeArgs      = '/uninstall /quiet /norestart'
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
                    "Pass -DestinationPath <share>\VCRedist, or -CatalogPath <RepoRoot>\OTTOUpdate-Catalog.json " +
                    "(found automatically when this script runs from <RepoRoot>\Administrative\Sync).") -ForegroundColor Red
        exit 1
    }
    try { $catalogData = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $CatalogPath).ProviderPath) | ConvertFrom-Json }
    catch { Write-Host "The repo catalog $CatalogPath can't be read: $($_.Exception.Message). Pass -DestinationPath instead." -ForegroundColor Red; exit 1 }
    $catalogEntry = @($catalogData.Apps) | Where-Object { $_ -and [string]$_.AppId -eq 'VCRedist' } | Select-Object -First 1
    $catalogFolder = if ($catalogEntry -and $catalogEntry.Folder) { [string]$catalogEntry.Folder } else { 'Applications\VCRedist' }
    # Folder is the app's full path (e.g. \\fileserver\Software\Applications\Chrome); older catalogs hold a name under the repo root
    $DestinationPath = if ($catalogFolder -match '^\\\\' -or [IO.Path]::IsPathRooted($catalogFolder)) { $catalogFolder }
                       else { Join-Path (Split-Path (Resolve-Path -LiteralPath $CatalogPath).ProviderPath -Parent) $catalogFolder }
    Write-Host ("-DestinationPath from the repo catalog: $DestinationPath" + $(if (-not $catalogEntry) { " (VCRedist isn't in the catalog yet; it's added after this sync writes latest.json)" }))
}

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
try   { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13 }
catch { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 }

# Family catalog: download link per architecture, expected runtime major version, the
# known final version (used when the file's own version isn't the runtime version),
# and the silent install arguments the client should use.
$Catalog = [ordered]@{
    'v14' = @{
        Major = 14; Known = $null; Args = '/install /quiet /norestart'
        Urls  = @{ x86   = 'https://aka.ms/vc14/vc_redist.x86.exe'
                   x64   = 'https://aka.ms/vc14/vc_redist.x64.exe'
                   arm64 = 'https://aka.ms/vc14/vc_redist.arm64.exe' }
    }
    '2013' = @{
        Major = 12; Known = '12.0.40664.0'; Args = '/install /quiet /norestart'
        Urls  = @{ x86 = 'https://aka.ms/highdpimfc2013x86enu'
                   x64 = 'https://aka.ms/highdpimfc2013x64enu' }
    }
    '2012' = @{
        Major = 11; Known = '11.0.61030.0'; Args = '/install /quiet /norestart'
        Urls  = @{ x86 = 'https://download.microsoft.com/download/1/6/B/16B06F60-3B20-4FF2-B699-5E9B7962F9AE/VSU_4/vcredist_x86.exe'
                   x64 = 'https://download.microsoft.com/download/1/6/B/16B06F60-3B20-4FF2-B699-5E9B7962F9AE/VSU_4/vcredist_x64.exe' }
    }
    '2010' = @{
        Major = 10; Known = '10.0.40219.325'; Args = '/q /norestart'
        Urls  = @{ x86 = 'https://download.microsoft.com/download/1/6/5/165255E7-1014-4D0A-B094-B6A430A6BFFC/vcredist_x86.exe'
                   x64 = 'https://download.microsoft.com/download/1/6/5/165255E7-1014-4D0A-B094-B6A430A6BFFC/vcredist_x64.exe' }
    }
    '2008' = @{
        Major = 9; Known = '9.0.30729.5677'; Args = '/q /norestart'
        Urls  = @{ x86 = 'https://download.microsoft.com/download/5/D/8/5D8C65CB-C849-4025-8E95-C3966CAFD8AE/vcredist_x86.exe'
                   x64 = 'https://download.microsoft.com/download/5/D/8/5D8C65CB-C849-4025-8E95-C3966CAFD8AE/vcredist_x64.exe' }
    }
    '2005' = @{
        # SP1 ATL/MFC security update (download page id=26347)
        Major = 8; Known = '8.0.61001.0'; Args = '/q'
        Urls  = @{ x86 = 'https://download.microsoft.com/download/8/B/4/8B42259F-5D70-43F4-AC2E-4B208FD8D66A/vcredist_x86.EXE'
                   x64 = 'https://download.microsoft.com/download/8/B/4/8B42259F-5D70-43F4-AC2E-4B208FD8D66A/vcredist_x64.EXE' }
    }
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
$LogFile = Join-Path $logDir 'Sync-VCRedistRepo.log'

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
                Write-Log ("  {0:N0} MB, {1:N1} MB/s" -f ($done / 1MB), $rate)
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

function Get-RuntimeVersion([string]$Path, $FamilyInfo) {
    # The installer's file/product version, if it's the runtime version (same major);
    # otherwise the known final version for that family.
    $vi = (Get-Item -LiteralPath $Path).VersionInfo
    foreach ($candidate in @($vi.ProductVersion, $vi.FileVersion)) {
        $v = ConvertTo-Version $candidate
        if ($v -and $v.Major -eq $FamilyInfo.Major) { return $v.ToString() }
    }
    if ($FamilyInfo.Known) { return $FamilyInfo.Known }
    throw "Couldn't tell the runtime version of $(Split-Path $Path -Leaf) (file version $($vi.FileVersion))."
}

# --- Main --------------------------------------------------------------------
$tempDir = Join-Path $env:TEMP "vcredist-sync-$([guid]::NewGuid().ToString('N'))"
try {
    # latest.json as it was before this run, for the repo catalog (see the end of the script)
    $script:ManifestBefore = $null
    try {
        $manifestBeforePath = Join-Path $DestinationPath 'latest.json'
        if (Test-Path -LiteralPath $manifestBeforePath) { $script:ManifestBefore = Get-Content -LiteralPath $manifestBeforePath -Raw }
    }
    catch { }
    Write-Log "---- Sync started. Destination: $DestinationPath  Families: $($Families -join ', ')"
    New-Item -ItemType Directory -Path $tempDir | Out-Null

    $manifestPath = Join-Path $DestinationPath 'latest.json'
    $existing = $null
    if (Test-Path $manifestPath) {
        try { $existing = Get-Content $manifestPath -Raw | ConvertFrom-Json }
        catch { Write-Log "Existing manifest is unreadable and will be replaced: $_" 'WARN' }
    }

    # Start from the existing manifest so families/architectures not refreshed are kept
    $out = [ordered]@{}
    if ($existing -and $existing.Families) {
        foreach ($p in $existing.Families.PSObject.Properties) {
            $files = [ordered]@{}
            foreach ($f in $p.Value.Files.PSObject.Properties) { $files[$f.Name] = $f.Value }
            $out[$p.Name] = [ordered]@{ Args = $p.Value.Args; Files = $files }
        }
    }
    $changed = $false

    foreach ($fam in $Families) {
        $info = $Catalog[$fam]
        if (-not $out[$fam]) { $out[$fam] = [ordered]@{ Args = $info.Args; Files = [ordered]@{} } }
        $out[$fam].Args = $info.Args
        $famDir = Join-Path $DestinationPath $fam

        foreach ($arch in $info.Urls.Keys | Sort-Object) {
            $url  = $info.Urls[$arch]
            $prev = $out[$fam].Files[$arch]
            $stamp = Get-RemoteStamp $url
            if (-not $Force -and $prev -and $stamp -and $prev.SourceStamp -eq $stamp -and
                (Test-Path -LiteralPath (Join-Path $DestinationPath $prev.FileName))) {
                Write-Log "$fam $arch : unchanged ($($prev.Version))."
                continue
            }

            $fileName = Split-Path ([Uri]$url).AbsolutePath -Leaf
            if ($fileName -notmatch '\.exe$') { $fileName = "vcredist_$arch.exe" }   # aka.ms links have no file name
            $local = Join-Path $tempDir "$fam-$arch-$fileName"
            Write-Log "Downloading $fam $arch from $url"
            try {
                Save-Download -Url $url -OutFile $local
                $sig = Get-AuthenticodeSignature -FilePath $local
                if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch $SignerPattern) {
                    throw "signature check failed (status: $($sig.Status), signer: $($sig.SignerCertificate.Subject))"
                }
                $ver = Get-RuntimeVersion $local $info
            }
            catch {
                Write-Log "  $fam $arch failed: $(Get-ErrorDetail $_). Keeping what's on the share." 'WARN'
                continue
            }

            if ($prev -and (ConvertTo-Version $ver) -lt (ConvertTo-Version $prev.Version) -and -not $Force) {
                Write-Log "  $fam $arch : downloaded $ver is older than the share's $($prev.Version). Not publishing." 'WARN'
                continue
            }

            # Publish: <family>\<version>\<file> (a new version folder per release)
            $verDir = Join-Path $famDir $ver
            if (-not (Test-Path $verDir)) { New-Item -ItemType Directory -Path $verDir -Force | Out-Null }
            $final   = Join-Path $verDir $fileName
            $partial = "$final.partial"
            Copy-Item -LiteralPath $local -Destination $partial -Force
            Move-Item -LiteralPath $partial -Destination $final -Force

            $out[$fam].Files[$arch] = [ordered]@{
                FileName    = Join-Path $fam (Join-Path $ver $fileName)
                Version     = $ver
                Sha256      = (Get-FileHash -LiteralPath $final -Algorithm SHA256).Hash
                SourceStamp = $stamp
            }
            $changed = $true
            Write-Log "  Published $fam $arch $ver (signed by Microsoft)."
        }

        # Prune old version folders for this family (never the ones in use)
        if (Test-Path $famDir) {
            $inUse = @($out[$fam].Files.Values | ForEach-Object { Split-Path (Split-Path $_.FileName -Parent) -Leaf } | Sort-Object -Unique)
            Get-ChildItem -Path $famDir -Directory |
                Where-Object { $_.Name -match '^\d+(\.\d+){1,3}$' -and $inUse -notcontains $_.Name } |
                Sort-Object { [version]$_.Name } -Descending |
                Select-Object -Skip ([math]::Max(0, $KeepVersions - $inUse.Count)) |
                ForEach-Object { Write-Log "Removing old $fam folder $($_.Name)"; Remove-Item $_.FullName -Recurse -Force }
        }
    }

    if ($changed -or -not $existing) {
        $manifest = [ordered]@{
            Product   = 'Microsoft Visual C++ Redistributables'
            UpdatedAt = (Get-Date).ToString('o')
            Families  = $out
        }
        $tmp = "$manifestPath.tmp"
        $manifest | ConvertTo-Json -Depth 6 | Set-Content -Path $tmp -Encoding UTF8
        Move-Item -Path $tmp -Destination $manifestPath -Force
        Write-Log 'Manifest updated.'
    }
    else {
        Write-Log 'Nothing changed.'
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
            Invoke-OTTOIntunePackageBuild -AppId 'VCRedist' -DestinationPath $DestinationPath -OutputPath $IntuneOutputPath `
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
            Update-OTTOCatalogEntry -AppId 'VCRedist' -DestinationPath $DestinationPath -ManifestBefore $script:ManifestBefore `
                -Failed ([bool]($script:SyncFailed -or $script:IntuneFailed)) -Script 'Sync\VCRedist.ps1' `
                -BoundParameters $PSBoundParameters -CatalogPath $CatalogPath -Definition $OTTOAppDefinition -ScriptPath $PSCommandPath -Log { param($m, $l) Write-Log $m $l }
        }
        catch { Write-Log "Couldn't update the repo catalog: $($_.Exception.Message)" 'WARN' }
    }
    # Release the one-sync-per-share lock (it would otherwise stay held until this PowerShell
    # window closes, so a second run in the same window would think a sync is still running)
    if ($script:SyncLock) { $script:SyncLock.Dispose(); $script:SyncLock = $null }
    if ($script:IntuneFailed) { exit 1 }
}
