<#
.SYNOPSIS
    SERVER SCRIPT - Keeps a network share stocked with the latest PuTTY MSI installers
    (64-bit x86, 64-bit Arm, 32-bit x86).

.DESCRIPTION
    PuTTY's official download site publishes each release under a fixed folder, plus a
    "latest" folder that always points at the current release:
        https://the.earth.li/~sgtatham/putty/latest/sha256sums
        https://the.earth.li/~sgtatham/putty/<version>/w64/putty-64bit-<version>-installer.msi
        https://the.earth.li/~sgtatham/putty/<version>/wa64/putty-arm64-<version>-installer.msi
        https://the.earth.li/~sgtatham/putty/<version>/w32/putty-<version>-installer.msi
    This script:
    - Reads the "latest" sha256sums file, which names the current installers (so it also
      tells us the current version) and gives their SHA-256 hashes.
    - Skips the run if the share already has that version.
    - Otherwise downloads each MSI from the release's own (permanent) folder, checks the
      SHA-256, checks the Authenticode signature (Simon Tatham), reads the MSI's
      ProductVersion / ProductCode / UpgradeCode, and publishes it to
      <DestinationPath>\<version>\.
    - Writes latest.json last. Keeps the newest -KeepVersions version folders.

.PARAMETER DestinationPath
    Folder (local path or UNC) where the installers are stored.
    Optional: if it's left out, the folder comes from the repo catalog
    (OTTOUpdate-Catalog.json): this app's Folder there (its full path), or
    <RepoRoot>\Applications\PuTTY if the app isn't in the catalog yet. The catalog is found
    automatically when this script runs from <RepoRoot>\Administrative\Sync;
    otherwise pass -CatalogPath.

.PARAMETER CatalogPath
    The repo catalog to take the folder from when -DestinationPath isn't given, e.g.
    \\fileserver\Software\OTTOUpdate-Catalog.json. Default: <RepoRoot>\OTTOUpdate-Catalog.json
    when this script is in <RepoRoot>\Administrative\Sync.

.PARAMETER Architectures
    Which builds to keep: x64, arm64, x86. Default: all three.

.PARAMETER Version
    Publish this release (e.g. 0.85) instead of the latest.

.PARAMETER BaseUrl
    PuTTY download site. Default: https://the.earth.li/~sgtatham/putty

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
    on the share: <IntuneOutputPath>\PuTTY\<version>\ gets PuTTY-<version>.intunewin,
    Detect-PuTTY.ps1 (custom detection script) and README-PuTTY.txt (the install/uninstall
    commands, return codes and detection settings to enter in Intune). Nothing is rebuilt
    if that version's package already exists (unless -Force). Needs <RepoRoot>\Administrative\Shared\OTTOUpdate-Common.ps1 and the app's client script (catalog ClientScript, normally Apps\PuTTY.ps1).

.PARAMETER IntuneOutputPath
    Where Intune packages are written. Default: <DestinationPath>\Intune

.PARAMETER ClientScriptPath
    Client script to put in the package. Default: the app's client script from the catalog (Apps\PuTTY.ps1 under <RepoRoot>\Administrative).

.PARAMETER IntuneWinAppUtilPath
    Path to IntuneWinAppUtil.exe (Microsoft Win32 Content Prep Tool). Default: the repo's
    shared copy, <RepoRoot>\Tools\IntuneWinAppUtil.exe (<RepoRoot> = the parent of
    -DestinationPath), which Update-IntuneWinAppUtil.ps1 downloads if it's missing.

.EXAMPLE
    .\Sync\PuTTY.ps1 -DestinationPath '\\fileserver\Software\Applications\PuTTY'

.EXAMPLE
    # Sync, then build the Intune package (.intunewin + detection script + README)
    .\Sync\PuTTY.ps1 -DestinationPath '\\fileserver\Software\Applications\PuTTY' -BuildIntunePackage
#>
[CmdletBinding()]
param(
    [string]$DestinationPath,

    [string]$CatalogPath,

    [ValidateSet('x64', 'arm64', 'x86')]
    [string[]]$Architectures = @('x64', 'arm64', 'x86'),

    [ValidatePattern('^\d+\.\d+(\.\d+)?$')]
    [string]$Version,

    [string]$BaseUrl = 'https://the.earth.li/~sgtatham/putty',

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
    AppId        = 'PuTTY'
    Name         = 'PuTTY'
    SyncScript   = 'Sync\PuTTY.ps1'
    ClientScript = 'Apps\PuTTY.ps1'
    Intune       = @{
        # Install command arguments after the script name. '-SourcePath .' becomes the repo path
        # plus the package's own copy as the fallback.
        InstallCommand  = '-SourcePath . -Install'
        InstallVariants = @(
            '-SourcePath . -Install -InstallWhileRunning   (update even with PuTTY/Pageant open; finishes at the next restart - returns 3010)',
            '-SourcePath . -Install -ConvertToNativeArchitecture   (replace 32-bit PuTTY on 64-bit Windows with the 64-bit build instead of updating it in place)',
            '-SourcePath . -Install -CloseRunning   (closes PuTTY programs - open sessions are dropped)',
            '-SourcePath .   (update existing installs only)'
        )
        # The app's Programs and Features entries (regular expressions), for detection logging and uninstall
        Match           = @{ Pattern = '^PuTTY\b'; Exclude = 'CAC'; KeyPattern = ''; Exe = '' }
        Detection       = @{
            # How it's detected, as written in Detect.log. Empty = the built-in check of the
            # Programs and Features entry (Match.Pattern) and, if newer, Match.Exe's file version
            Description     = 'Programs and Features entry (Simon Tatham, the old installer, or the MSI family)'
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
# Any PuTTY install counts (any architecture, MSI or the old pre-0.68 installer)
$codes = @($Manifest.Files.PSObject.Properties | ForEach-Object { $_.Value.UpgradeCode } | Sort-Object -Unique |
           ForEach-Object { Get-RelatedProducts $_ } | ForEach-Object { $_.ProductCode.ToUpper() })
$best  = Get-Uninstall | Where-Object { $_.Name -match '^PuTTY\b' -and $_.Name -notmatch 'CAC' -and
             ($_.Publisher -match 'Tatham' -or $_.KeyName -match '_is1$' -or $codes -contains $_.KeyName.ToUpper()) } |
         Sort-Object Version -Descending | Select-Object -First 1
Test-Current $AppName $best.VersionText (Select-ArchEntry $Manifest.Files).ProductVersion
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
                    "Pass -DestinationPath <share>\PuTTY, or -CatalogPath <RepoRoot>\OTTOUpdate-Catalog.json " +
                    "(found automatically when this script runs from <RepoRoot>\Administrative\Sync).") -ForegroundColor Red
        exit 1
    }
    try { $catalogData = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $CatalogPath).ProviderPath) | ConvertFrom-Json }
    catch { Write-Host "The repo catalog $CatalogPath can't be read: $($_.Exception.Message). Pass -DestinationPath instead." -ForegroundColor Red; exit 1 }
    $catalogEntry = @($catalogData.Apps) | Where-Object { $_ -and [string]$_.AppId -eq 'PuTTY' } | Select-Object -First 1
    $catalogFolder = if ($catalogEntry -and $catalogEntry.Folder) { [string]$catalogEntry.Folder } else { 'Applications\PuTTY' }
    # Folder is the app's full path (e.g. \\fileserver\Software\Applications\Chrome); older catalogs hold a name under the repo root
    $DestinationPath = if ($catalogFolder -match '^\\\\' -or [IO.Path]::IsPathRooted($catalogFolder)) { $catalogFolder }
                       else { Join-Path (Split-Path (Resolve-Path -LiteralPath $CatalogPath).ProviderPath -Parent) $catalogFolder }
    Write-Host ("-DestinationPath from the repo catalog: $DestinationPath" + $(if (-not $catalogEntry) { " (PuTTY isn't in the catalog yet; it's added after this sync writes latest.json)" }))
}

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
try   { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13 }
catch { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 }

$BaseUrl       = $BaseUrl.TrimEnd('/')
$SignerPattern = 'Simon Tatham'
$UserAgent     = 'Sync-PuTTYRepo.ps1 (PowerShell)'
# Installer paths inside a release folder (as listed in sha256sums)
$Patterns = @{
    x64   = '^w64/putty-64bit-(?<v>[\d\.]+)-installer\.msi$'
    arm64 = '^wa64/putty-arm64-(?<v>[\d\.]+)-installer\.msi$'
    x86   = '^w32/putty-(?<v>[\d\.]+)-installer\.msi$'
}

# --- Helpers -----------------------------------------------------------------
if (-not (Test-Path $DestinationPath)) { New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null }
$logDir = Join-Path $DestinationPath 'Logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$LogFile = Join-Path $logDir 'Sync-PuTTYRepo.log'

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
        while ($true) {
            $read = $in.ReadAsync($buf, 0, $buf.Length)
            if (-not $read.Wait([TimeSpan]::FromSeconds($StallTimeoutSec))) {
                throw ("Download stalled: no data for {0} s after {1:N0} MB." -f $StallTimeoutSec, ($done / 1MB))
            }
            $n = $read.Result
            if ($n -le 0) { break }
            $out.Write($buf, 0, $n)
            $done += $n
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

function Get-ReleaseInstallers([string]$Folder) {
    # Parses <BaseUrl>/<Folder>/sha256sums ("<sha256>  <path>" per line) and returns the
    # MSI installers in it per architecture, with the release version taken from the names.
    $text = Get-Text "$BaseUrl/$Folder/sha256sums"
    $found = @{}
    foreach ($line in $text -split "`r?`n") {
        $m = [regex]::Match($line, '^\s*([0-9a-fA-F]{64})\s+\*?(\S+)\s*$')
        if (-not $m.Success) { continue }
        $path = $m.Groups[2].Value
        foreach ($arch in $Patterns.Keys) {
            $pm = [regex]::Match($path, $Patterns[$arch])
            if ($pm.Success) {
                $found[$arch] = [pscustomobject]@{ Path = $path; Name = Split-Path $path -Leaf; Version = $pm.Groups['v'].Value; Sha256 = $m.Groups[1].Value.ToUpper() }
            }
        }
    }
    return $found
}

# --- Main --------------------------------------------------------------------
$tempDir = Join-Path $env:TEMP "putty-sync-$([guid]::NewGuid().ToString('N'))"
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

    # --- What's the current release? ------------------------------------------
    $folder = if ($Version) { $Version } else { 'latest' }
    Write-Log "Reading $BaseUrl/$folder/sha256sums"
    $installers = Get-ReleaseInstallers $folder
    if ($installers.Count -eq 0) { throw "No Windows MSI installers listed in $BaseUrl/$folder/sha256sums." }
    $release = @($installers.Values | ForEach-Object { $_.Version } | Sort-Object { ConvertTo-Version $_ } -Descending)[0]
    if ($Version -and $release -ne $Version) { Write-Log "sha256sums lists version $release (asked for $Version)." 'WARN' }
    Write-Log "Current release: PuTTY $release ($(($installers.Keys | Sort-Object) -join ', '))"

    if ($existing -and -not $Version -and (ConvertTo-Version $release) -lt (ConvertTo-Version $existing.Version) -and -not $Force) {
        Write-Log "The site's release $release is older than the share's $($existing.Version). Nothing published." 'WARN'
        Write-Log '---- Sync finished successfully.'
        exit 0
    }

    # Already on the share?
    $current = $existing -and $existing.Version -eq $release -and -not $Force
    if ($current) {
        foreach ($arch in $Architectures) {
            if (-not $installers[$arch]) { continue }
            $f = $existing.Files.$arch
            if (-not $f -or -not (Test-Path -LiteralPath (Join-Path $DestinationPath $f.FileName))) { $current = $false }
        }
    }
    if ($current) {
        Write-Log "Share already has PuTTY $release. Nothing to do."
    }
    else {
        # --- Download and verify --------------------------------------------------
        $found = [ordered]@{}
        foreach ($arch in $Architectures) {
            $i = $installers[$arch]
            if (-not $i) { Write-Log "  $arch : no installer in this release." 'WARN'; continue }
            $local = Join-Path $tempDir $i.Name
            $url   = "$BaseUrl/$release/$($i.Path)"
            Write-Log "  $arch : downloading $url"
            try { Save-Download -Url $url -OutFile $local }
            catch {
                # The permanent folder should always exist; fall back to the folder we read
                Write-Log "    $(Get-ErrorDetail $_) - trying $BaseUrl/$folder/$($i.Path)" 'WARN'
                $url = "$BaseUrl/$folder/$($i.Path)"
                Save-Download -Url $url -OutFile $local
            }
            $hash = (Get-FileHash -LiteralPath $local -Algorithm SHA256).Hash
            if ($hash -ne $i.Sha256) { throw "$($i.Name): SHA-256 mismatch. Published: $($i.Sha256)  Downloaded: $hash" }
            $sig = Get-AuthenticodeSignature -FilePath $local
            if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch $SignerPattern) {
                throw "$($i.Name): signature check failed (status: $($sig.Status), signer: $($sig.SignerCertificate.Subject))."
            }
            $found[$arch] = [ordered]@{
                FileName       = Join-Path $release $i.Name
                Sha256         = $hash
                ProductName    = Get-MsiProperty $local 'ProductName'
                ProductVersion = Get-MsiProperty $local 'ProductVersion'
                ProductCode    = Get-MsiProperty $local 'ProductCode'
                UpgradeCode    = Get-MsiProperty $local 'UpgradeCode'
                SourceUrl      = $url
                LocalPath      = $local
            }
            Write-Log "    $($found[$arch].ProductName) $($found[$arch].ProductVersion): SHA-256 matches; signed by $($sig.SignerCertificate.Subject)."
        }
        if ($found.Count -eq 0) { throw 'No installers were downloaded.' }

        # --- Publish ------------------------------------------------------------
        $verFolder = Join-Path $DestinationPath $release
        $staging   = "$verFolder.partial"
        if (Test-Path $staging) { Remove-Item $staging -Recurse -Force }
        New-Item -ItemType Directory -Path $staging | Out-Null
        $files = [ordered]@{}
        foreach ($arch in $found.Keys) {
            Copy-Item -LiteralPath $found[$arch].LocalPath -Destination (Join-Path $staging (Split-Path $found[$arch].FileName -Leaf))
            $found[$arch].Remove('LocalPath')
            $files[$arch] = $found[$arch]
        }
        if (Test-Path $verFolder) { Remove-Item $verFolder -Recurse -Force }
        Rename-Item -Path $staging -NewName $release

        $manifest = [ordered]@{
            Product   = 'PuTTY'
            Version   = $release
            UpdatedAt = (Get-Date).ToString('o')
            Files     = $files
        }
        $tmp = "$manifestPath.tmp"
        $manifest | ConvertTo-Json -Depth 5 | Set-Content -Path $tmp -Encoding UTF8
        Move-Item -Path $tmp -Destination $manifestPath -Force
        Write-Log "Published PuTTY $release ($($files.Keys -join ', ')); manifest updated."
    }

    # --- Prune old version folders ---------------------------------------------
    Get-ChildItem -Path $DestinationPath -Directory |
        Where-Object { $_.Name -match '^\d+\.\d+(\.\d+)?$' } |
        Sort-Object { ConvertTo-Version $_.Name } -Descending |
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
            Invoke-OTTOIntunePackageBuild -AppId 'PuTTY' -DestinationPath $DestinationPath -OutputPath $IntuneOutputPath `
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
            Update-OTTOCatalogEntry -AppId 'PuTTY' -DestinationPath $DestinationPath -ManifestBefore $script:ManifestBefore `
                -Failed ([bool]($script:SyncFailed -or $script:IntuneFailed)) -Script 'Sync\PuTTY.ps1' `
                -BoundParameters $PSBoundParameters -CatalogPath $CatalogPath -Definition $OTTOAppDefinition -ScriptPath $PSCommandPath -Log { param($m, $l) Write-Log $m $l }
        }
        catch { Write-Log "Couldn't update the repo catalog: $($_.Exception.Message)" 'WARN' }
    }
    # Release the one-sync-per-share lock (it would otherwise stay held until this PowerShell
    # window closes, so a second run in the same window would think a sync is still running)
    if ($script:SyncLock) { $script:SyncLock.Dispose(); $script:SyncLock = $null }
    if ($script:IntuneFailed) { exit 1 }
}
