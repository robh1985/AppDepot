<#
.SYNOPSIS
    SERVER SCRIPT - Keeps a network share stocked with the latest Microsoft .NET Windows
    Desktop Runtime installers (windowsdesktop-runtime-*.exe) for every .NET version.

.DESCRIPTION
    Uses Microsoft's official .NET release metadata:
    - https://builds.dotnet.microsoft.com/dotnet/release-metadata/releases-index.json
      -> every .NET channel (3.0, 3.1, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0 ...) with its
         support phase (active / maintenance / eol / preview).
    - <channel>/releases.json -> the latest release's "windowsdesktop" installers for
      win-x64 / win-x86 / win-arm64, with official download URLs and SHA-512 hashes.
    For each channel and architecture it:
    - skips it if the share already has that release,
    - otherwise downloads the installer, checks it against Microsoft's SHA-512 and its
      Authenticode signature (Microsoft), and publishes it to
      <DestinationPath>\<channel>\<version>\.
    Writes latest.json last. Keeps the newest -KeepVersions releases per channel.
    The Windows Desktop Runtime exists from .NET Core 3.0 onward; older channels are skipped.
    Preview / release-candidate channels are skipped unless -IncludePreview.

    Folder layout:
        <DestinationPath>\8.0\8.0.31\windowsdesktop-runtime-8.0.31-win-x64.exe  (x86, arm64)
        <DestinationPath>\10.0\10.0.12\windowsdesktop-runtime-10.0.12-win-x64.exe
        <DestinationPath>\latest.json
        <DestinationPath>\Logs\Sync-DotNetDesktopRuntimeRepo.log

.PARAMETER DestinationPath
    Folder (local path or UNC) where the installers are stored.
    Optional: if it's left out, the folder comes from the repo catalog
    (OTTOUpdate-Catalog.json): this app's Folder there (its full path), or
    <RepoRoot>\Applications\DotNetDesktopRuntime if the app isn't in the catalog yet. The catalog is found
    automatically when this script runs from <RepoRoot>\Administrative\Sync;
    otherwise pass -CatalogPath.

.PARAMETER CatalogPath
    The repo catalog to take the folder from when -DestinationPath isn't given, e.g.
    \\fileserver\Software\OTTOUpdate-Catalog.json. Default: <RepoRoot>\OTTOUpdate-Catalog.json
    when this script is in <RepoRoot>\Administrative\Sync.

.PARAMETER Channels
    .NET channels to keep, e.g. 6.0,8.0,10.0. Default: every channel that has a Windows
    Desktop Runtime (3.0 and later), excluding previews.

.PARAMETER Architectures
    Which builds to keep: x64, x86, arm64. Default: all three.

.PARAMETER IncludePreview
    Also keep preview / release-candidate channels.

.PARAMETER KeepVersions
    How many releases to keep per channel. Default: 2.

.PARAMETER Proxy
    Proxy server for internet access, e.g. http://proxy.contoso.local:8080.

.PARAMETER ProxyUseDefaultCredentials
    Authenticate to the proxy as the account running the script.

.PARAMETER PageTimeoutSec
    Seconds to wait for the metadata / for a download to start. Default: 60.

.PARAMETER StallTimeoutSec
    Give up on a download if no data arrives for this many seconds. Default: 120.

.PARAMETER Force
    Download and republish even if the share already has the latest releases.

.PARAMETER BuildIntunePackage
    After a successful sync, also build a Microsoft Intune Win32 app package from what is
    on the share: <IntuneOutputPath>\DotNetDesktopRuntime\<version>\ gets DotNetDesktopRuntime-<version>.intunewin,
    Detect-DotNetDesktopRuntime.ps1 (custom detection script) and README-DotNetDesktopRuntime.txt (the install/uninstall
    commands, return codes and detection settings to enter in Intune). Nothing is rebuilt
    if that version's package already exists (unless -Force). Needs <RepoRoot>\Administrative\Shared\OTTOUpdate-Common.ps1 and the app's client script (catalog ClientScript, normally Apps\DotNetDesktopRuntime.ps1).

.PARAMETER IntuneOutputPath
    Where Intune packages are written. Default: <DestinationPath>\Intune

.PARAMETER ClientScriptPath
    Client script to put in the package. Default: the app's client script from the catalog (Apps\DotNetDesktopRuntime.ps1 under <RepoRoot>\Administrative).

.PARAMETER IntuneWinAppUtilPath
    Path to IntuneWinAppUtil.exe (Microsoft Win32 Content Prep Tool). Default: the repo's
    shared copy, <RepoRoot>\Tools\IntuneWinAppUtil.exe (<RepoRoot> = the parent of
    -DestinationPath), which Update-IntuneWinAppUtil.ps1 downloads if it's missing.

.EXAMPLE
    .\Sync\DotNetDesktopRuntime.ps1 -DestinationPath '\\fileserver\Software\Applications\DotNetDesktopRuntime'

.EXAMPLE
    # Sync, then build the Intune package (.intunewin + detection script + README)
    .\Sync\DotNetDesktopRuntime.ps1 -DestinationPath '\\fileserver\Software\Applications\DotNetDesktopRuntime' -BuildIntunePackage
#>
[CmdletBinding()]
param(
    [string]$DestinationPath,

    [string]$CatalogPath,

    [string[]]$Channels,

    [ValidateSet('x64', 'x86', 'arm64')]
    [string[]]$Architectures = @('x64', 'x86', 'arm64'),

    [switch]$IncludePreview,

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
    AppId        = 'DotNetDesktopRuntime'
    Name         = '.NET Windows Desktop Runtime'
    SyncScript   = 'Sync\DotNetDesktopRuntime.ps1'
    ClientScript = 'Apps\DotNetDesktopRuntime.ps1'
    Intune       = @{
        # Install command arguments after the script name. '-SourcePath .' becomes the repo path
        # plus the package's own copy as the fallback.
        InstallCommand  = '-SourcePath . -Install'
        InstallVariants = @(
            '-SourcePath . -Install 8.0,10.0'
        )
        # The app's Programs and Features entries (regular expressions), for detection logging and uninstall
        Match           = @{ Pattern = '^Microsoft Windows Desktop Runtime - '; Exclude = ''; KeyPattern = ''; Exe = '' }
        Detection       = @{
            # How it's detected, as written in Detect.log. Empty = the built-in check of the
            # Programs and Features entry (Match.Pattern) and, if newer, Match.Exe's file version
            Description     = 'registry SOFTWARE\dotnet\Setup\InstalledVersions, each channel and architecture compared separately'
            # Several versions side by side, each compared with its own repo version ($Required)
            SeveralVersions = $true
            # What $Required is when the detection script's $Required line is left at $null
            DefaultRequired = '@(@($Manifest.Channels.PSObject.Properties | Where-Object { $_.Value.ReleaseType -eq ''lts'' -and $_.Value.SupportPhase -notmatch ''eol'' }) |
    Sort-Object { [version]($_.Name + ''.0'') } -Descending | Select-Object -First 1 | ForEach-Object { $_.Name })'
            # Runs before the repo is read; may Pass or Fail straight away
            PreCheck        = ''
            # Sets $have when the repo can't be read. Empty = the Programs and Features check
            Offline         = ''
            # The check: compares what's installed with $Manifest (the repo's latest.json) and
            # ends with Test-Current / Test-CurrentSet. Empty = the built-in check
            Code            = @'
# Each installed .NET channel is compared with its repo version. $Required = channels that
# must be installed (match -Install in your Intune install command).
$rows = @{}
foreach ($view in [Microsoft.Win32.RegistryView]::Registry64, [Microsoft.Win32.RegistryView]::Registry32) {
    foreach ($a in 'x64', 'x86', 'arm64') {
        try {
            $k = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, $view).OpenSubKey("SOFTWARE\dotnet\Setup\InstalledVersions\$a\sharedfx\Microsoft.WindowsDesktop.App")
            if ($k) { foreach ($v in $k.GetValueNames()) { if ($v -match '^(\d+)\.(\d+)\.\d+$') { $rows["$a|$v"] = [pscustomobject]@{ Channel = "$($Matches[1]).$($Matches[2])"; Arch = $a; Version = $v } } } }
        } catch { }
    }
}
Note "  .NET Desktop Runtime installed: $(if ($rows.Count) { ($rows.Values | Sort-Object Arch, Version | ForEach-Object { "$($_.Version) ($($_.Arch))" }) -join ', ' } else { 'none' })"
$items = @()
foreach ($g in $rows.Values | Group-Object Channel, Arch) {
    $c = $g.Group[0].Channel; $a = $g.Group[0].Arch
    $entry = $Manifest.Channels.$c.Files.$a
    if (-not $entry) { continue }
    $best = $g.Group | Sort-Object { ConvertTo-Version $_.Version } -Descending | Select-Object -First 1
    $items += [pscustomobject]@{ Name = ".NET $c ($a)"; Have = $best.Version; Want = $entry.Version }
}
foreach ($c in $Required) {
    if ($rows.Values | Where-Object { $_.Channel -eq $c }) { continue }
    $entry = Select-ArchEntry $Manifest.Channels.$c.Files
    $items += [pscustomobject]@{ Name = ".NET $c"; Have = $null; Want = $(if ($entry) { $entry.Version } else { $c }) }
}
Test-CurrentSet '.NET Desktop Runtime' $items
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
                    "Pass -DestinationPath <share>\DotNetDesktopRuntime, or -CatalogPath <RepoRoot>\OTTOUpdate-Catalog.json " +
                    "(found automatically when this script runs from <RepoRoot>\Administrative\Sync).") -ForegroundColor Red
        exit 1
    }
    try { $catalogData = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $CatalogPath).ProviderPath) | ConvertFrom-Json }
    catch { Write-Host "The repo catalog $CatalogPath can't be read: $($_.Exception.Message). Pass -DestinationPath instead." -ForegroundColor Red; exit 1 }
    $catalogEntry = @($catalogData.Apps) | Where-Object { $_ -and [string]$_.AppId -eq 'DotNetDesktopRuntime' } | Select-Object -First 1
    $catalogFolder = if ($catalogEntry -and $catalogEntry.Folder) { [string]$catalogEntry.Folder } else { 'Applications\DotNetDesktopRuntime' }
    # Folder is the app's full path (e.g. \\fileserver\Software\Applications\Chrome); older catalogs hold a name under the repo root
    $DestinationPath = if ($catalogFolder -match '^\\\\' -or [IO.Path]::IsPathRooted($catalogFolder)) { $catalogFolder }
                       else { Join-Path (Split-Path (Resolve-Path -LiteralPath $CatalogPath).ProviderPath -Parent) $catalogFolder }
    Write-Host ("-DestinationPath from the repo catalog: $DestinationPath" + $(if (-not $catalogEntry) { " (DotNetDesktopRuntime isn't in the catalog yet; it's added after this sync writes latest.json)" }))
}

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
try   { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13 }
catch { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 }

$IndexUrls = @(
    'https://builds.dotnet.microsoft.com/dotnet/release-metadata/releases-index.json',
    'https://dotnetcli.blob.core.windows.net/dotnet/release-metadata/releases-index.json'
)
$SignerPattern = 'O=Microsoft Corporation'
$UserAgent     = 'Sync-DotNetDesktopRuntimeRepo.ps1 (PowerShell)'

if ($Proxy) {
    $PSDefaultParameterValues['Invoke-WebRequest:Proxy'] = $Proxy
    if ($ProxyUseDefaultCredentials) { $PSDefaultParameterValues['Invoke-WebRequest:ProxyUseDefaultCredentials'] = $true }
}

# --- Helpers -----------------------------------------------------------------
if (-not (Test-Path $DestinationPath)) { New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null }
$logDir = Join-Path $DestinationPath 'Logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$LogFile = Join-Path $logDir 'Sync-DotNetDesktopRuntimeRepo.log'

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

function Get-DesktopRelease($ReleasesJson) {
    # Newest release in a channel that has a Windows Desktop Runtime .exe.
    # Returns @{ Version; Date; Files = @{ x64 = @{ Url; Hash; Name }; ... } } or $null
    foreach ($rel in @($ReleasesJson.releases) | ForEach-Object { $_ }) {
        $wd = $rel.windowsdesktop
        if (-not $wd -or -not $wd.files) { continue }
        $files = @{}
        foreach ($f in @($wd.files) | ForEach-Object { $_ }) {
            $url = [string]$f.url
            if ($url -notmatch '(?i)windowsdesktop-runtime-[^/]*\.exe$') { continue }
            $arch = switch -Regex ([string]$f.rid) { 'win-x64$' { 'x64' } 'win-x86$' { 'x86' } 'win-arm64$' { 'arm64' } default { $null } }
            if ($arch) { $files[$arch] = @{ Url = $url; Hash = ([string]$f.hash).ToUpper(); Name = Split-Path ([Uri]$url).AbsolutePath -Leaf } }
        }
        if ($files.Count -gt 0) {
            return @{ Version = [string]$wd.version; Date = [string]$rel.'release-date'; Files = $files }
        }
    }
    return $null
}

# --- Main --------------------------------------------------------------------
$tempDir = Join-Path $env:TEMP "dotnetdesktop-sync-$([guid]::NewGuid().ToString('N'))"
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

    # --- Channels -------------------------------------------------------------
    $index = $null
    foreach ($u in $IndexUrls) {
        try { Write-Log "Reading $u"; $index = Get-Json $u; break }
        catch { Write-Log "  failed: $(Get-ErrorDetail $_)" 'WARN' }
    }
    if (-not $index) { throw "Couldn't read Microsoft's .NET release index." }

    $all = @($index.'releases-index') | ForEach-Object { $_ } | Where-Object {
        $v = ConvertTo-Version $_.'channel-version'
        $v -and $v -ge [version]'3.0'                                   # Desktop Runtime starts at 3.0
    }
    if ($Channels) {
        $want = $Channels | ForEach-Object { if ($_ -match '^\d+$') { "$_.0" } else { $_ } }
        $all = $all | Where-Object { $want -contains $_.'channel-version' }
    }
    elseif (-not $IncludePreview) {
        $all = $all | Where-Object { $_.'support-phase' -notmatch 'preview|go-live|rc' }
    }
    Write-Log "Channels: $(($all | ForEach-Object { "$($_.'channel-version') ($($_.'support-phase'))" }) -join ', ')"

    # Start from the existing manifest so anything not refreshed is kept
    $out = [ordered]@{}
    if ($existing -and $existing.Channels) {
        foreach ($p in $existing.Channels.PSObject.Properties) {
            $files = [ordered]@{}
            foreach ($f in $p.Value.Files.PSObject.Properties) { $files[$f.Name] = $f.Value }
            $out[$p.Name] = [ordered]@{ SupportPhase = $p.Value.SupportPhase; ReleaseType = $p.Value.ReleaseType; Files = $files }
        }
    }
    $changed = $false

    foreach ($ch in $all) {
        $cv = [string]$ch.'channel-version'
        try {
            $rel = Get-DesktopRelease (Get-Json ([string]$ch.'releases.json'))
            if (-not $rel) { Write-Log "$cv : no Windows Desktop Runtime installers listed - skipping."; continue }
            Write-Log "$cv : latest Windows Desktop Runtime $($rel.Version) ($($rel.Date), $($ch.'support-phase'))"

            if (-not $out[$cv]) { $out[$cv] = [ordered]@{ Files = [ordered]@{} } }
            $out[$cv].SupportPhase = [string]$ch.'support-phase'
            $out[$cv].ReleaseType  = [string]$ch.'release-type'
            $chDir = Join-Path $DestinationPath $cv

            foreach ($arch in $Architectures) {
                $f = $rel.Files[$arch]
                if (-not $f) { Write-Log "  $cv $arch : no installer for this architecture."; continue }
                $prev = $out[$cv].Files[$arch]
                if (-not $Force -and $prev -and $prev.Version -eq $rel.Version -and
                    (Test-Path -LiteralPath (Join-Path $DestinationPath $prev.FileName))) {
                    Write-Log "  $cv $arch : $($rel.Version) already on the share."
                    continue
                }
                try {
                    $local = Join-Path $tempDir $f.Name
                    Write-Log "  $cv $arch : downloading $($f.Url)"
                    Save-Download -Url $f.Url -OutFile $local
                    $hash = (Get-FileHash -LiteralPath $local -Algorithm SHA512).Hash
                    if ($hash -ne $f.Hash) { throw "SHA-512 mismatch (Microsoft lists $($f.Hash.Substring(0,16))..., got $($hash.Substring(0,16))...)." }
                    $sig = Get-AuthenticodeSignature -FilePath $local
                    if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch $SignerPattern) {
                        throw "signature check failed (status: $($sig.Status), signer: $($sig.SignerCertificate.Subject))."
                    }
                    $verDir = Join-Path $chDir $rel.Version
                    New-Item -ItemType Directory -Path $verDir -Force | Out-Null
                    $final = Join-Path $verDir $f.Name
                    Copy-Item -LiteralPath $local -Destination "$final.partial" -Force
                    Move-Item -LiteralPath "$final.partial" -Destination $final -Force
                    $out[$cv].Files[$arch] = [ordered]@{
                        Version  = $rel.Version
                        FileName = Join-Path $cv (Join-Path $rel.Version $f.Name)
                        Sha512   = $hash
                    }
                    $changed = $true
                    Write-Log "    published (SHA-512 matches Microsoft; signed by Microsoft)."
                }
                catch { Write-Log "  $cv $arch failed: $(Get-ErrorDetail $_). Keeping what's on the share." 'WARN' }
            }

            # Prune old releases in this channel (never the ones in use)
            if (Test-Path $chDir) {
                $inUse = @($out[$cv].Files.Values | ForEach-Object { Split-Path (Split-Path $_.FileName -Parent) -Leaf } | Sort-Object -Unique)
                Get-ChildItem -LiteralPath $chDir -Directory |
                    Where-Object { $inUse -notcontains $_.Name } |
                    Sort-Object { ConvertTo-Version $_.Name } -Descending |
                    Select-Object -Skip ([math]::Max(0, $KeepVersions - $inUse.Count)) |
                    ForEach-Object { Write-Log "  Removing old $cv release folder $($_.Name)"; Remove-Item $_.FullName -Recurse -Force }
            }
        }
        catch { Write-Log "$cv failed: $(Get-ErrorDetail $_)" 'WARN' }
    }

    if ($changed -or -not $existing) {
        $manifest = [ordered]@{
            Product   = 'Microsoft .NET Windows Desktop Runtime'
            UpdatedAt = (Get-Date).ToString('o')
            Channels  = $out
        }
        $tmp = "$manifestPath.tmp"
        $manifest | ConvertTo-Json -Depth 6 | Set-Content -Path $tmp -Encoding UTF8
        Move-Item -Path $tmp -Destination $manifestPath -Force
        Write-Log 'Manifest updated.'
    }
    else { Write-Log 'Nothing changed.' }

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
            Invoke-OTTOIntunePackageBuild -AppId 'DotNetDesktopRuntime' -DestinationPath $DestinationPath -OutputPath $IntuneOutputPath `
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
            Update-OTTOCatalogEntry -AppId 'DotNetDesktopRuntime' -DestinationPath $DestinationPath -ManifestBefore $script:ManifestBefore `
                -Failed ([bool]($script:SyncFailed -or $script:IntuneFailed)) -Script 'Sync\DotNetDesktopRuntime.ps1' `
                -BoundParameters $PSBoundParameters -CatalogPath $CatalogPath -Definition $OTTOAppDefinition -ScriptPath $PSCommandPath -Log { param($m, $l) Write-Log $m $l }
        }
        catch { Write-Log "Couldn't update the repo catalog: $($_.Exception.Message)" 'WARN' }
    }
    # Release the one-sync-per-share lock (it would otherwise stay held until this PowerShell
    # window closes, so a second run in the same window would think a sync is still running)
    if ($script:SyncLock) { $script:SyncLock.Dispose(); $script:SyncLock = $null }
    if ($script:IntuneFailed) { exit 1 }
}
