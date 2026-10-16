<#
.SYNOPSIS
    SERVER SCRIPT - Keeps a network share stocked with the latest Eclipse Temurin Java
    Runtime Environment (JRE) MSI installers for every available Java version.

.DESCRIPTION
    Eclipse Temurin (Adoptium) is a free, open-source build of Java that's free for
    business use. This script uses Adoptium's official API:
    - https://api.adoptium.net/v3/info/available_releases  -> which Java versions exist
      (8, 11, 17, 21, 25 ... ; by default every version Adoptium lists is kept, so any
      version installed on a client can be updated).
    - https://api.adoptium.net/v3/assets/latest/<version>/hotspot?image_type=jre&os=windows&architecture=<arch>
      -> the latest JRE MSI for that version/architecture, with its SHA-256 checksum.
    For each Java version and architecture (x64, x86, aarch64 - whichever Adoptium
    publishes), it:
    - skips it if the share already has that release,
    - otherwise downloads the MSI, checks it against Adoptium's SHA-256 and its
      Authenticode signature (Eclipse Foundation), reads the MSI's ProductVersion /
      ProductName / UpgradeCode, and publishes it to <DestinationPath>\<version>\<release>\.
    Writes latest.json last. Keeps the newest -KeepVersions releases per Java version.

    Folder layout:
        <DestinationPath>\8\jdk8u504-b01\OpenJDK8U-jre_x64_windows_hotspot_8u504b01.msi
        <DestinationPath>\21\jdk-21.0.x+y\OpenJDK21U-jre_x64_windows_hotspot_....msi
        <DestinationPath>\latest.json
        <DestinationPath>\Logs\Sync-TemurinJreRepo.log

    Must run on Windows (it reads MSI details with the Windows Installer COM object).

.PARAMETER DestinationPath
    Folder (local path or UNC) where the installers are stored.
    Optional: if it's left out, the folder comes from the repo catalog
    (OTTOUpdate-Catalog.json): this app's Folder there (its full path), or
    <RepoRoot>\Applications\TemurinJRE if the app isn't in the catalog yet. The catalog is found
    automatically when this script runs from <RepoRoot>\Administrative\Sync;
    otherwise pass -CatalogPath.

.PARAMETER CatalogPath
    The repo catalog to take the folder from when -DestinationPath isn't given, e.g.
    \\fileserver\Software\OTTOUpdate-Catalog.json. Default: <RepoRoot>\OTTOUpdate-Catalog.json
    when this script is in <RepoRoot>\Administrative\Sync.

.PARAMETER FeatureVersions
    Java versions to keep, e.g. 8,11,17,21,25. Default: every version Adoptium lists.

.PARAMETER Architectures
    Which builds to keep: x64, x86, aarch64. Default: all three (skipped where Adoptium
    has no JRE MSI for that version/architecture).

.PARAMETER KeepVersions
    How many releases to keep per Java version. Default: 2.

.PARAMETER Proxy
    Proxy server for internet access, e.g. http://proxy.contoso.local:8080.

.PARAMETER ProxyUseDefaultCredentials
    Authenticate to the proxy as the account running the script.

.PARAMETER PageTimeoutSec
    Seconds to wait for the API / for a download to start. Default: 60.

.PARAMETER StallTimeoutSec
    Give up on a download if no data arrives for this many seconds. Default: 120.

.PARAMETER Force
    Download and republish even if the share already has the latest releases.

.PARAMETER BuildIntunePackage
    After a successful sync, also build a Microsoft Intune Win32 app package from what is
    on the share: <IntuneOutputPath>\TemurinJRE\<version>\ gets TemurinJRE-<version>.intunewin,
    Detect-TemurinJRE.ps1 (custom detection script) and README-TemurinJRE.txt (the install/uninstall
    commands, return codes and detection settings to enter in Intune). Nothing is rebuilt
    if that version's package already exists (unless -Force). Needs <RepoRoot>\Administrative\Shared\OTTOUpdate-Common.ps1 and the app's client script (catalog ClientScript, normally Apps\TemurinJRE.ps1).

.PARAMETER IntuneOutputPath
    Where Intune packages are written. Default: <DestinationPath>\Intune

.PARAMETER ClientScriptPath
    Client script to put in the package. Default: the app's client script from the catalog (Apps\TemurinJRE.ps1 under <RepoRoot>\Administrative).

.PARAMETER IntuneWinAppUtilPath
    Path to IntuneWinAppUtil.exe (Microsoft Win32 Content Prep Tool). Default: the repo's
    shared copy, <RepoRoot>\Tools\IntuneWinAppUtil.exe (<RepoRoot> = the parent of
    -DestinationPath), which Update-IntuneWinAppUtil.ps1 downloads if it's missing.

.EXAMPLE
    .\Sync\TemurinJRE.ps1 -DestinationPath '\\fileserver\Software\Applications\TemurinJRE'

.EXAMPLE
    # Sync, then build the Intune package (.intunewin + detection script + README)
    .\Sync\TemurinJRE.ps1 -DestinationPath '\\fileserver\Software\Applications\TemurinJRE' -BuildIntunePackage
#>
[CmdletBinding()]
param(
    [string]$DestinationPath,

    [string]$CatalogPath,

    [int[]]$FeatureVersions,

    [ValidateSet('x64', 'x86', 'aarch64')]
    [string[]]$Architectures = @('x64', 'x86', 'aarch64'),

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
    AppId        = 'TemurinJRE'
    Name         = 'Eclipse Temurin JRE'
    SyncScript   = 'Sync\TemurinJRE.ps1'
    ClientScript = 'Apps\TemurinJRE.ps1'
    Intune       = @{
        # Install command arguments after the script name. '-SourcePath .' becomes the repo path
        # plus the package's own copy as the fallback.
        InstallCommand  = '-SourcePath . -Install'
        InstallVariants = @(
            '-SourcePath . -Install 8,21   (Java 8 and 21; the detection script needs $Required = @(''8'',''21''))',
            '-SourcePath . -Install -ReplaceOracleJava8:$false   (leave Oracle Java 8 alone)'
        )
        # The app's Programs and Features entries (regular expressions), for detection logging and uninstall
        Match           = @{ Pattern = '^Eclipse Temurin JRE'; Exclude = ''; KeyPattern = ''; Exe = '' }
        Detection       = @{
            # How it's detected, as written in Detect.log. Empty = the built-in check of the
            # Programs and Features entry (Match.Pattern) and, if newer, Match.Exe's file version
            Description     = 'Programs and Features entries, each Java version and architecture compared separately'
            # Several versions side by side, each compared with its own repo version ($Required)
            SeveralVersions = $true
            # What $Required is when the detection script's $Required line is left at $null
            DefaultRequired = '@(@($Manifest.Features.PSObject.Properties | Where-Object { $_.Value.Lts -and $_.Value.Files.PSObject.Properties.Count -gt 0 } |
    ForEach-Object { [int]$_.Name }) | Sort-Object -Descending | Select-Object -First 1 | ForEach-Object { [string]$_ })'
            # Runs before the repo is read; may Pass or Fail straight away
            PreCheck        = ''
            # Sets $have when the repo can't be read. Empty = the Programs and Features check
            Offline         = ''
            # The check: compares what's installed with $Manifest (the repo's latest.json) and
            # ends with Test-Current / Test-CurrentSet. Empty = the built-in check
            Code            = @'
# Each installed Java version is compared with its repo version. $Required = Java versions that
# must be installed (match -Install in your Intune install command).
$os = Get-OSArch
$installed = @()
foreach ($e in Get-Uninstall | Where-Object { $_.Name -match 'Temurin' -and $_.Name -match '\bJRE\b' -and $_.Publisher -match 'Adoptium|Eclipse' }) {
    # "...Hotspot 8u504-b01 (x64)" -> 8 ; "...Hotspot 21.0.8+9 (x64)" -> 21
    $m = [regex]::Match($e.Name, '(?i)hotspot\s+(\d+)(?:u|\.)')
    $f = if ($m.Success) { [int]$m.Groups[1].Value } elseif ($e.VersionText -match '^(\d+)\.') { if ([int]$Matches[1] -eq 1) { 8 } else { [int]$Matches[1] } } else { $null }
    if (-not $f) { continue }
    $a = if ($e.Name -match '(?i)aarch64|arm64') { 'aarch64' } elseif ($e.Name -match '(?i)\(x86\)|x86-32|32-bit') { 'x86' } elseif ($e.Name -match '(?i)\(x64\)|64-bit') { 'x64' } elseif ($e.View -eq '32' -and $os -ne 'x86') { 'x86' } else { 'x64' }
    $installed += [pscustomobject]@{ Feature = $f; Arch = $a; Version = $e.VersionText }
}
$items = @()
foreach ($g in $installed | Group-Object Feature, Arch) {
    $f = $g.Group[0].Feature; $a = $g.Group[0].Arch
    $entry = $Manifest.Features."$f".Files.$a
    if (-not $entry) { continue }
    $best = $g.Group | Sort-Object { ConvertTo-Version $_.Version } -Descending | Select-Object -First 1
    $items += [pscustomobject]@{ Name = "Java $f ($a)"; Have = $best.Version; Want = $entry.ProductVersion }
}
foreach ($f in $Required) {
    if ($installed | Where-Object { $_.Feature -eq [int]$f }) { continue }
    $entry = Select-ArchEntry ($Manifest.Features."$f".Files | Select-Object @{ n = 'arm64'; e = { $_.aarch64 } }, x64, x86)
    $items += [pscustomobject]@{ Name = "Java $f"; Have = $null; Want = $(if ($entry) { $entry.ProductVersion } else { "$f" }) }
}
Test-CurrentSet 'Temurin JRE' $items
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
                    "Pass -DestinationPath <share>\TemurinJRE, or -CatalogPath <RepoRoot>\OTTOUpdate-Catalog.json " +
                    "(found automatically when this script runs from <RepoRoot>\Administrative\Sync).") -ForegroundColor Red
        exit 1
    }
    try { $catalogData = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $CatalogPath).ProviderPath) | ConvertFrom-Json }
    catch { Write-Host "The repo catalog $CatalogPath can't be read: $($_.Exception.Message). Pass -DestinationPath instead." -ForegroundColor Red; exit 1 }
    $catalogEntry = @($catalogData.Apps) | Where-Object { $_ -and [string]$_.AppId -eq 'TemurinJRE' } | Select-Object -First 1
    $catalogFolder = if ($catalogEntry -and $catalogEntry.Folder) { [string]$catalogEntry.Folder } else { 'Applications\TemurinJRE' }
    # Folder is the app's full path (e.g. \\fileserver\Software\Applications\Chrome); older catalogs hold a name under the repo root
    $DestinationPath = if ($catalogFolder -match '^\\\\' -or [IO.Path]::IsPathRooted($catalogFolder)) { $catalogFolder }
                       else { Join-Path (Split-Path (Resolve-Path -LiteralPath $CatalogPath).ProviderPath -Parent) $catalogFolder }
    Write-Host ("-DestinationPath from the repo catalog: $DestinationPath" + $(if (-not $catalogEntry) { " (TemurinJRE isn't in the catalog yet; it's added after this sync writes latest.json)" }))
}

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
try   { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13 }
catch { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 }

$ApiBase       = 'https://api.adoptium.net/v3'
$SignerPattern = 'Eclipse'
$UserAgent     = 'Sync-TemurinJreRepo.ps1 (PowerShell)'

if ($Proxy) {
    $PSDefaultParameterValues['Invoke-WebRequest:Proxy'] = $Proxy
    if ($ProxyUseDefaultCredentials) { $PSDefaultParameterValues['Invoke-WebRequest:ProxyUseDefaultCredentials'] = $true }
}

# --- Helpers -----------------------------------------------------------------
if (-not (Test-Path $DestinationPath)) { New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null }
$logDir = Join-Path $DestinationPath 'Logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$LogFile = Join-Path $logDir 'Sync-TemurinJreRepo.log'

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

function Get-Json([string]$Url) {
    $content = (Invoke-WebRequest -Uri $Url -UseBasicParsing -UserAgent $UserAgent -TimeoutSec $PageTimeoutSec).Content
    if ($content -is [byte[]]) { $content = [Text.Encoding]::UTF8.GetString($content) }
    if (-not $content -or -not ([string]$content).Trim()) { return $null }
    return ([string]$content | ConvertFrom-Json)
}

function Save-Download([string]$Url, [string]$OutFile) {
    # Streams a file to disk; gives up if no data arrives for $StallTimeoutSec.
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

function Get-LatestAsset([int]$Feature, [string]$Arch) {
    # Latest JRE MSI for a Java version/architecture, or $null if Adoptium has none.
    # 32-bit Windows is 'x86' in some API versions and 'x32' in others - try both.
    $apiArchs = if ($Arch -eq 'x86') { @('x86', 'x32') } else { @($Arch) }
    foreach ($a in $apiArchs) {
        $url  = "$ApiBase/assets/latest/$Feature/hotspot?architecture=$a&image_type=jre&os=windows&vendor=eclipse"
        $json = Get-Json $url
        $asset = @($json) | ForEach-Object { $_ } | Where-Object { $_ -and $_.binary.installer.link -match '\.msi$' } | Select-Object -First 1
        if ($asset) { return $asset }
    }
    return $null
}

# --- Main --------------------------------------------------------------------
$tempDir = Join-Path $env:TEMP "temurin-sync-$([guid]::NewGuid().ToString('N'))"
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

    # --- Which Java versions? -----------------------------------------------
    $info = Get-Json "$ApiBase/info/available_releases"
    $lts  = @($info.available_lts_releases | ForEach-Object { [int]$_ })
    $features = if ($FeatureVersions) { $FeatureVersions } else { @($info.available_releases | ForEach-Object { [int]$_ }) }
    Write-Log "Java versions to keep: $($features -join ', ')  (LTS: $($lts -join ', '))"

    # Start from the existing manifest so anything not refreshed is kept
    $out = [ordered]@{}
    if ($existing -and $existing.Features) {
        foreach ($p in $existing.Features.PSObject.Properties) {
            $files = [ordered]@{}
            foreach ($f in $p.Value.Files.PSObject.Properties) { $files[$f.Name] = $f.Value }
            $out[$p.Name] = [ordered]@{ Lts = $p.Value.Lts; Files = $files }
        }
    }
    $changed = $false

    foreach ($feature in $features) {
        $fk = [string]$feature
        if (-not $out[$fk]) { $out[$fk] = [ordered]@{ Lts = ($lts -contains $feature); Files = [ordered]@{} } }
        $out[$fk].Lts = ($lts -contains $feature)
        $featDir = Join-Path $DestinationPath $fk

        foreach ($arch in $Architectures) {
            try {
                $asset = Get-LatestAsset $feature $arch
                if (-not $asset) { Write-Log "Java $feature $arch : Adoptium has no Windows JRE MSI - skipping."; continue }

                $release = [string]$asset.release_name
                $inst    = $asset.binary.installer
                $prev    = $out[$fk].Files[$arch]
                if (-not $Force -and $prev -and $prev.Release -eq $release -and
                    (Test-Path -LiteralPath (Join-Path $DestinationPath $prev.FileName))) {
                    Write-Log "Java $feature $arch : $release - already on the share."
                    continue
                }

                $local = Join-Path $tempDir $inst.name
                Write-Log "Java $feature $arch : downloading $release ($([math]::Round($inst.size / 1MB)) MB)"
                Save-Download -Url $inst.link -OutFile $local

                $hash = (Get-FileHash -LiteralPath $local -Algorithm SHA256).Hash
                if ($hash -ne ([string]$inst.checksum).ToUpper()) { throw "SHA-256 mismatch. Adoptium lists $($inst.checksum), got $hash." }
                $sig = Get-AuthenticodeSignature -FilePath $local
                if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch $SignerPattern) {
                    throw "signature check failed (status: $($sig.Status), signer: $($sig.SignerCertificate.Subject))."
                }
                $pv   = Get-MsiProperty $local 'ProductVersion'
                $name = Get-MsiProperty $local 'ProductName'
                $uc   = ([string](Get-MsiProperty $local 'UpgradeCode')).ToUpper()

                # Publish
                $relDir = Join-Path $featDir $release
                New-Item -ItemType Directory -Path $relDir -Force | Out-Null
                $final = Join-Path $relDir $inst.name
                Copy-Item -LiteralPath $local -Destination "$final.partial" -Force
                Move-Item -LiteralPath "$final.partial" -Destination $final -Force

                $out[$fk].Files[$arch] = [ordered]@{
                    Release        = $release
                    SemVer         = [string]$asset.version.semver
                    ProductVersion = $pv
                    ProductName    = $name
                    UpgradeCode    = $uc
                    FileName       = Join-Path $fk (Join-Path $release $inst.name)
                    Sha256         = $hash
                }
                $changed = $true
                Write-Log "  Published $name ($pv); SHA-256 matches Adoptium; signed by $($sig.SignerCertificate.Subject)."
            }
            catch {
                Write-Log "Java $feature $arch failed: $(Get-ErrorDetail $_). Keeping what's on the share." 'WARN'
            }
        }

        # Prune old releases for this Java version (never the ones in use)
        if (Test-Path $featDir) {
            $inUse = @($out[$fk].Files.Values | ForEach-Object { Split-Path (Split-Path $_.FileName -Parent) -Leaf } | Sort-Object -Unique)
            Get-ChildItem -LiteralPath $featDir -Directory |
                Where-Object { $inUse -notcontains $_.Name } |
                Sort-Object LastWriteTime -Descending |
                Select-Object -Skip ([math]::Max(0, $KeepVersions - $inUse.Count)) |
                ForEach-Object { Write-Log "Removing old Java $fk release folder $($_.Name)"; Remove-Item $_.FullName -Recurse -Force }
        }
    }

    if ($changed -or -not $existing) {
        $manifest = [ordered]@{
            Product   = 'Eclipse Temurin JRE'
            UpdatedAt = (Get-Date).ToString('o')
            Features  = $out
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
            Invoke-OTTOIntunePackageBuild -AppId 'TemurinJRE' -DestinationPath $DestinationPath -OutputPath $IntuneOutputPath `
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
            Update-OTTOCatalogEntry -AppId 'TemurinJRE' -DestinationPath $DestinationPath -ManifestBefore $script:ManifestBefore `
                -Failed ([bool]($script:SyncFailed -or $script:IntuneFailed)) -Script 'Sync\TemurinJRE.ps1' `
                -BoundParameters $PSBoundParameters -CatalogPath $CatalogPath -Definition $OTTOAppDefinition -ScriptPath $PSCommandPath -Log { param($m, $l) Write-Log $m $l }
        }
        catch { Write-Log "Couldn't update the repo catalog: $($_.Exception.Message)" 'WARN' }
    }
    # Release the one-sync-per-share lock (it would otherwise stay held until this PowerShell
    # window closes, so a second run in the same window would think a sync is still running)
    if ($script:SyncLock) { $script:SyncLock.Dispose(); $script:SyncLock = $null }
    if ($script:IntuneFailed) { exit 1 }
}
