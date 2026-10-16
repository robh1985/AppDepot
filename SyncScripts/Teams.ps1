<#
.SYNOPSIS
    SERVER SCRIPT - Keeps a network share stocked with the latest new Microsoft Teams
    (work or school) MSIX packages and the Teams bootstrapper.

.DESCRIPTION
    Microsoft's official links (from "Deploy the new Microsoft Teams client"):
        teamsbootstrapper.exe  https://go.microsoft.com/fwlink/?linkid=2243204&clcid=0x409
        MSTeams x64 MSIX       https://go.microsoft.com/fwlink/?linkid=2196106
        MSTeams x86 MSIX       https://go.microsoft.com/fwlink/?linkid=2196060&clcid=0x409
        MSTeams ARM64 MSIX     https://go.microsoft.com/fwlink/?linkid=2196207&clcid=0x409
    This script:
    - Sends a HEAD request for each file and skips downloading it if it hasn't changed
      since the last run (ETag / Last-Modified / size).
    - Otherwise downloads it (with progress logging and a stall timeout), checks its
      Authenticode signature (Microsoft), and reads the Teams version from inside the
      MSIX (AppxManifest.xml).
    - Publishes to a version folder and writes latest.json last.
    - Keeps the newest -KeepVersions version folders.

    Folder layout:
        <DestinationPath>\25xxx.xxxx.xxxx.xxxx\MSTeams-x64.msix  (etc.)
        <DestinationPath>\25xxx.xxxx.xxxx.xxxx\teamsbootstrapper.exe
        <DestinationPath>\latest.json
        <DestinationPath>\Logs\Sync-TeamsRepo.log

.PARAMETER DestinationPath
    Folder (local path or UNC) where the packages are stored.
    Optional: if it's left out, the folder comes from the repo catalog
    (OTTOUpdate-Catalog.json): this app's Folder there (its full path), or
    <RepoRoot>\Applications\Teams if the app isn't in the catalog yet. The catalog is found
    automatically when this script runs from <RepoRoot>\Administrative\Sync;
    otherwise pass -CatalogPath.

.PARAMETER CatalogPath
    The repo catalog to take the folder from when -DestinationPath isn't given, e.g.
    \\fileserver\Software\OTTOUpdate-Catalog.json. Default: <RepoRoot>\OTTOUpdate-Catalog.json
    when this script is in <RepoRoot>\Administrative\Sync.

.PARAMETER Architectures
    Which MSIX builds to keep. Default: x64, arm64. (Add x86 for 32-bit Windows.)

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
    Download and republish even if nothing appears to have changed.

.PARAMETER BuildIntunePackage
    After a successful sync, also build a Microsoft Intune Win32 app package from what is
    on the share: <IntuneOutputPath>\Teams\<version>\ gets Teams-<version>.intunewin,
    Detect-Teams.ps1 (custom detection script) and README-Teams.txt (the install/uninstall
    commands, return codes and detection settings to enter in Intune). Nothing is rebuilt
    if that version's package already exists (unless -Force). Needs <RepoRoot>\Administrative\Shared\OTTOUpdate-Common.ps1 and the app's client script (catalog ClientScript, normally Apps\Teams.ps1).

.PARAMETER IntuneOutputPath
    Where Intune packages are written. Default: <DestinationPath>\Intune

.PARAMETER ClientScriptPath
    Client script to put in the package. Default: the app's client script from the catalog (Apps\Teams.ps1 under <RepoRoot>\Administrative).

.PARAMETER IntuneWinAppUtilPath
    Path to IntuneWinAppUtil.exe (Microsoft Win32 Content Prep Tool). Default: the repo's
    shared copy, <RepoRoot>\Tools\IntuneWinAppUtil.exe (<RepoRoot> = the parent of
    -DestinationPath), which Update-IntuneWinAppUtil.ps1 downloads if it's missing.

.EXAMPLE
    .\Sync\Teams.ps1 -DestinationPath '\\fileserver\Software\Applications\Teams'

.EXAMPLE
    # Sync, then build the Intune package (.intunewin + detection script + README)
    .\Sync\Teams.ps1 -DestinationPath '\\fileserver\Software\Applications\Teams' -BuildIntunePackage
#>
[CmdletBinding()]
param(
    [string]$DestinationPath,

    [string]$CatalogPath,

    [ValidateSet('x64', 'x86', 'arm64')]
    [string[]]$Architectures = @('x64', 'arm64'),

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
    AppId        = 'Teams'
    Name         = 'Microsoft Teams (work or school)'
    SyncScript   = 'Sync\Teams.ps1'
    ClientScript = 'Apps\Teams.ps1'
    Intune       = @{
        # Install command arguments after the script name. '-SourcePath .' becomes the repo path
        # plus the package's own copy as the fallback.
        InstallCommand  = '-SourcePath . -Install'
        InstallVariants = @(
            '-SourcePath . -Install -RemoveClassicTeams:$false   (leave classic Teams in place)'
        )
        # The app's Programs and Features entries (regular expressions), for detection logging and uninstall
        Match           = @{ Pattern = '^$'; Exclude = ''; KeyPattern = ''; Exe = '' }
        Detection       = @{
            # How it's detected, as written in Detect.log. Empty = the built-in check of the
            # Programs and Features entry (Match.Pattern) and, if newer, Match.Exe's file version
            Description     = 'provisioned MSTeams app package (WindowsApps)'
            # Several versions side by side, each compared with its own repo version ($Required)
            SeveralVersions = $false
            # What $Required is when the detection script's $Required line is left at $null
            DefaultRequired = '@()'
            # Runs before the repo is read; may Pass or Fail straight away
            PreCheck        = ''
            # Sets $have when the repo can't be read. Empty = the Programs and Features check
            Offline         = @'
$dirs = @(Get-ChildItem -LiteralPath (Join-Path (Get-PF64) 'WindowsApps') -Directory -Filter 'MSTeams_*' -ErrorAction SilentlyContinue)
foreach ($d in $dirs) { Note "  Teams package folder: $($d.Name)" }
$best = $dirs | ForEach-Object { ConvertTo-Version ($_.Name -split '_')[1] } | Sort-Object -Descending | Select-Object -First 1
$have = if ($best) { "$best" } else { $null }
'@
            # The check: compares what's installed with $Manifest (the repo's latest.json) and
            # ends with Test-Current / Test-CurrentSet. Empty = the built-in check
            Code            = @'
# Provisioned (all-users) Teams; works from 32- or 64-bit PowerShell
$dirs = Get-ChildItem -LiteralPath (Join-Path (Get-PF64) 'WindowsApps') -Directory -Filter 'MSTeams_*' -ErrorAction SilentlyContinue
foreach ($d in $dirs) { Note "  Teams package folder: $($d.Name)" }
$best = $dirs | ForEach-Object { ConvertTo-Version ($_.Name -split '_')[1] } | Sort-Object -Descending | Select-Object -First 1
if (-not $best) {
    try { $best = Get-AppxProvisionedPackage -Online | Where-Object DisplayName -eq 'MSTeams' | ForEach-Object { [version]$_.Version } | Sort-Object -Descending | Select-Object -First 1 } catch { }
    Note "  Provisioned MSTeams package: $(if ($best) { "version $best" } else { 'none' })"
}
Test-Current $AppName $(if ($best) { "$best" }) (Select-ArchEntry $Manifest.Files).Version
'@
        }
        Uninstall       = @{
            # Silent arguments for uninstallers that aren't MSI
            ExeArgs      = ''
            # A reason the app can't be uninstalled (the uninstall script then only logs it)
            NotSupported = ''
            # Runs instead of removing the matching Programs and Features entries
            Code         = @'
# New Teams: the bootstrapper in this package deprovisions it for all users
$boot = Get-ChildItem -Path . -Recurse -Filter 'teamsbootstrapper.exe' -File | Select-Object -First 1
if (-not $boot) { throw 'teamsbootstrapper.exe not found in the package.' }
$code = Invoke-Tool $boot.FullName '-x'
Write-Log "teamsbootstrapper.exe -x returned $code"
if ($code -ne 0) { exit 1 }
exit 0
'@
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
                    "Pass -DestinationPath <share>\Teams, or -CatalogPath <RepoRoot>\OTTOUpdate-Catalog.json " +
                    "(found automatically when this script runs from <RepoRoot>\Administrative\Sync).") -ForegroundColor Red
        exit 1
    }
    try { $catalogData = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $CatalogPath).ProviderPath) | ConvertFrom-Json }
    catch { Write-Host "The repo catalog $CatalogPath can't be read: $($_.Exception.Message). Pass -DestinationPath instead." -ForegroundColor Red; exit 1 }
    $catalogEntry = @($catalogData.Apps) | Where-Object { $_ -and [string]$_.AppId -eq 'Teams' } | Select-Object -First 1
    $catalogFolder = if ($catalogEntry -and $catalogEntry.Folder) { [string]$catalogEntry.Folder } else { 'Applications\Teams' }
    # Folder is the app's full path (e.g. \\fileserver\Software\Applications\Chrome); older catalogs hold a name under the repo root
    $DestinationPath = if ($catalogFolder -match '^\\\\' -or [IO.Path]::IsPathRooted($catalogFolder)) { $catalogFolder }
                       else { Join-Path (Split-Path (Resolve-Path -LiteralPath $CatalogPath).ProviderPath -Parent) $catalogFolder }
    Write-Host ("-DestinationPath from the repo catalog: $DestinationPath" + $(if (-not $catalogEntry) { " (Teams isn't in the catalog yet; it's added after this sync writes latest.json)" }))
}

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
try   { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13 }
catch { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 }

$BootstrapperUrl = 'https://go.microsoft.com/fwlink/?linkid=2243204&clcid=0x409'
$MsixUrls = @{
    x64   = 'https://go.microsoft.com/fwlink/?linkid=2196106'
    x86   = 'https://go.microsoft.com/fwlink/?linkid=2196060&clcid=0x409'
    arm64 = 'https://go.microsoft.com/fwlink/?linkid=2196207&clcid=0x409'
}
$MsixNames     = @{ x64 = 'MSTeams-x64.msix'; x86 = 'MSTeams-x86.msix'; arm64 = 'MSTeams-arm64.msix' }
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
$LogFile = Join-Path $logDir 'Sync-TeamsRepo.log'

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

function Get-MsixIdentity([string]$Path) {
    # Reads <Identity Name=".." Version=".." ProcessorArchitecture=".."> from AppxManifest.xml inside the MSIX
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $entry = $zip.Entries | Where-Object { $_.FullName -eq 'AppxManifest.xml' } | Select-Object -First 1
        if (-not $entry) { throw 'AppxManifest.xml not found in the package.' }
        $reader = New-Object IO.StreamReader($entry.Open())
        try { [xml]$xml = $reader.ReadToEnd() } finally { $reader.Dispose() }
        $id = $xml.Package.Identity
        return [pscustomobject]@{ Name = $id.Name; Version = $id.Version; Arch = $id.ProcessorArchitecture; Publisher = $id.Publisher }
    }
    finally { $zip.Dispose() }
}

function Assert-MicrosoftSigned([string]$Path) {
    $sig = Get-AuthenticodeSignature -FilePath $Path
    if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch $SignerPattern) {
        throw "Signature check failed for $(Split-Path $Path -Leaf) (status: $($sig.Status), signer: $($sig.SignerCertificate.Subject))."
    }
}

# --- Main --------------------------------------------------------------------
$tempDir = Join-Path $env:TEMP "teams-sync-$([guid]::NewGuid().ToString('N'))"
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
    Write-Log "Version on share: $(if ($existing) { $existing.Version } else { 'none' })"

    # --- Anything changed upstream? ------------------------------------------
    $stamps = @{ bootstrapper = Get-RemoteStamp $BootstrapperUrl }
    foreach ($arch in $Architectures) { $stamps[$arch] = Get-RemoteStamp $MsixUrls[$arch] }

    $changed = $Force -or -not $existing
    if (-not $changed) {
        if (-not $stamps.bootstrapper -or $existing.Bootstrapper.SourceStamp -ne $stamps.bootstrapper -or
            -not (Test-Path -LiteralPath (Join-Path $DestinationPath $existing.Bootstrapper.FileName))) { $changed = $true }
        foreach ($arch in $Architectures) {
            $e = $existing.Files.$arch
            if (-not $stamps[$arch] -or -not $e -or $e.SourceStamp -ne $stamps[$arch] -or
                -not (Test-Path -LiteralPath (Join-Path $DestinationPath $e.FileName))) { $changed = $true }
        }
    }
    if (-not $changed) {
        Write-Log 'Nothing changed upstream and all files are present. Nothing to do.'
        exit 0
    }

    # --- Download and check --------------------------------------------------
    $bootLocal = Join-Path $tempDir 'teamsbootstrapper.exe'
    Write-Log 'Downloading teamsbootstrapper.exe'
    Save-Download -Url $BootstrapperUrl -OutFile $bootLocal
    Assert-MicrosoftSigned $bootLocal
    $bootVersion = (Get-Item -LiteralPath $bootLocal).VersionInfo.FileVersion
    Write-Log "Bootstrapper version $bootVersion, signature OK."

    $found = [ordered]@{}
    foreach ($arch in $Architectures) {
        $local = Join-Path $tempDir $MsixNames[$arch]
        Write-Log "Downloading $arch MSIX"
        try { Save-Download -Url $MsixUrls[$arch] -OutFile $local }
        catch { Write-Log "  failed: $(Get-ErrorDetail $_); skipping $arch." 'WARN'; continue }
        Assert-MicrosoftSigned $local
        $id = Get-MsixIdentity $local
        if ($id.Name -ne 'MSTeams') { throw "Unexpected package name '$($id.Name)' in the $arch MSIX." }
        Write-Log "$arch : $($id.Name) $($id.Version) ($($id.Arch)), signature OK"
        $found[$arch] = @{ Path = $local; Version = $id.Version; Hash = (Get-FileHash -LiteralPath $local -Algorithm SHA256).Hash }
    }
    if ($found.Count -eq 0) { throw 'No MSIX packages were downloaded.' }

    $versions = @($found.Values | ForEach-Object { ConvertTo-Version $_.Version } | Sort-Object -Unique -Descending)
    if ($versions.Count -gt 1) { Write-Log "Architectures report different versions ($($versions -join ', ')); each is recorded separately." 'WARN' }
    $release = $versions[0].ToString()

    if ($existingVersion -and $versions[0] -lt $existingVersion -and -not $Force) {
        throw "Downloaded version $release is OLDER than the share's $existingVersion. Not publishing."
    }

    # --- Publish -------------------------------------------------------------
    $verFolder = Join-Path $DestinationPath $release
    $staging   = "$verFolder.partial"
    if (Test-Path $staging) { Remove-Item $staging -Recurse -Force }
    New-Item -ItemType Directory -Path $staging | Out-Null
    Copy-Item -LiteralPath $bootLocal -Destination (Join-Path $staging 'teamsbootstrapper.exe')

    $files = [ordered]@{}
    foreach ($arch in $found.Keys) {
        Copy-Item -LiteralPath $found[$arch].Path -Destination (Join-Path $staging $MsixNames[$arch])
        $files[$arch] = [ordered]@{
            FileName    = Join-Path $release $MsixNames[$arch]
            Version     = $found[$arch].Version
            Sha256      = $found[$arch].Hash
            SourceStamp = $stamps[$arch]
        }
    }
    if (Test-Path $verFolder) { Remove-Item $verFolder -Recurse -Force }
    Rename-Item -Path $staging -NewName $release

    $manifest = [ordered]@{
        Product      = 'Microsoft Teams (work or school) - MSTeams'
        Version      = $release
        UpdatedAt    = (Get-Date).ToString('o')
        Bootstrapper = [ordered]@{
            FileName    = Join-Path $release 'teamsbootstrapper.exe'
            Version     = $bootVersion
            Sha256      = (Get-FileHash -LiteralPath $bootLocal -Algorithm SHA256).Hash
            SourceStamp = $stamps.bootstrapper
        }
        Files        = $files
    }
    $tmp = "$manifestPath.tmp"
    $manifest | ConvertTo-Json -Depth 5 | Set-Content -Path $tmp -Encoding UTF8
    Move-Item -Path $tmp -Destination $manifestPath -Force
    Write-Log "Published Teams $release ($($files.Keys -join ', ')) and updated manifest."

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
            Invoke-OTTOIntunePackageBuild -AppId 'Teams' -DestinationPath $DestinationPath -OutputPath $IntuneOutputPath `
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
            Update-OTTOCatalogEntry -AppId 'Teams' -DestinationPath $DestinationPath -ManifestBefore $script:ManifestBefore `
                -Failed ([bool]($script:SyncFailed -or $script:IntuneFailed)) -Script 'Sync\Teams.ps1' `
                -BoundParameters $PSBoundParameters -CatalogPath $CatalogPath -Definition $OTTOAppDefinition -ScriptPath $PSCommandPath -Log { param($m, $l) Write-Log $m $l }
        }
        catch { Write-Log "Couldn't update the repo catalog: $($_.Exception.Message)" 'WARN' }
    }
    # Release the one-sync-per-share lock (it would otherwise stay held until this PowerShell
    # window closes, so a second run in the same window would think a sync is still running)
    if ($script:SyncLock) { $script:SyncLock.Dispose(); $script:SyncLock = $null }
    if ($script:IntuneFailed) { exit 1 }
}
