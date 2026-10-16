<#
.SYNOPSIS
    SERVER SCRIPT - Keeps a network share stocked with the latest OpenVPN Connect (v3)
    MSI installers for Windows.

.DESCRIPTION
    - Reads OpenVPN's "Release Notes for OpenVPN Connect on Windows" page to find the
      latest version and build (e.g. 3.9.0 (5008)) and the SHA-256 checksum OpenVPN
      publishes for each MSI.
    - If the share already has that version, it stops.
    - Otherwise it downloads the MSIs:
          https://packages.openvpn.net/connect/v3/openvpn-connect-<ver>.<build>_signed.msi      (x64)
          https://packages.openvpn.net/connect/v3/openvpn-connect-<ver>.<build>_signed_x86.msi  (x86)
      (falling back to swupdate.openvpn.net if needed), checks each against OpenVPN's
      published SHA-256 and its Authenticode signature (OpenVPN Inc.), reads the
      MSI's own ProductVersion (what Windows reports once installed), and publishes to
      a version folder.
    - Writes latest.json last, so clients never see a half-published version.
    - Keeps the newest -KeepVersions version folders.

    Folder layout:
        <DestinationPath>\3.9.0.5008\openvpn-connect-3.9.0.5008_signed.msi
        <DestinationPath>\3.9.0.5008\openvpn-connect-3.9.0.5008_signed_x86.msi
        <DestinationPath>\latest.json
        <DestinationPath>\Logs\Sync-OpenVPNConnectRepo.log

    If OpenVPN changes the release notes page and the version can't be found, pass it
    yourself with -Version (e.g. -Version 3.9.0.5008).

    Must run on Windows (it reads the MSI version with the Windows Installer COM object).

.PARAMETER DestinationPath
    Folder (local path or UNC) where the installers are stored.
    Optional: if it's left out, the folder comes from the repo catalog
    (OTTOUpdate-Catalog.json): this app's Folder there (its full path), or
    <RepoRoot>\Applications\OpenVPNConnect if the app isn't in the catalog yet. The catalog is found
    automatically when this script runs from <RepoRoot>\Administrative\Sync;
    otherwise pass -CatalogPath.

.PARAMETER CatalogPath
    The repo catalog to take the folder from when -DestinationPath isn't given, e.g.
    \\fileserver\Software\OTTOUpdate-Catalog.json. Default: <RepoRoot>\OTTOUpdate-Catalog.json
    when this script is in <RepoRoot>\Administrative\Sync.

.PARAMETER Architectures
    Which builds to publish. Default: x64, x86. (ARM64 PCs use the x64 build.)

.PARAMETER Version
    Optional "<version>.<build>" to use instead of reading the release notes.

.PARAMETER KeepVersions
    How many version folders to keep. Default: 2.

.PARAMETER Proxy
    Proxy server for internet access, e.g. http://proxy.contoso.local:8080. Needed when
    the script runs as SYSTEM/a service account that doesn't get a user's proxy settings.

.PARAMETER ProxyUseDefaultCredentials
    Authenticate to the proxy as the account running the script.

.PARAMETER Force
    Download and republish even if the share already has this version.

.PARAMETER BuildIntunePackage
    After a successful sync, also build a Microsoft Intune Win32 app package from what is
    on the share: <IntuneOutputPath>\OpenVPNConnect\<version>\ gets OpenVPNConnect-<version>.intunewin,
    Detect-OpenVPNConnect.ps1 (custom detection script) and README-OpenVPNConnect.txt (the install/uninstall
    commands, return codes and detection settings to enter in Intune). Nothing is rebuilt
    if that version's package already exists (unless -Force). Needs <RepoRoot>\Administrative\Shared\OTTOUpdate-Common.ps1 and the app's client script (catalog ClientScript, normally Apps\OpenVPNConnect.ps1).

.PARAMETER IntuneOutputPath
    Where Intune packages are written. Default: <DestinationPath>\Intune

.PARAMETER ClientScriptPath
    Client script to put in the package. Default: the app's client script from the catalog (Apps\OpenVPNConnect.ps1 under <RepoRoot>\Administrative).

.PARAMETER IntuneWinAppUtilPath
    Path to IntuneWinAppUtil.exe (Microsoft Win32 Content Prep Tool). Default: the repo's
    shared copy, <RepoRoot>\Tools\IntuneWinAppUtil.exe (<RepoRoot> = the parent of
    -DestinationPath), which Update-IntuneWinAppUtil.ps1 downloads if it's missing.

.EXAMPLE
    .\Sync\OpenVPNConnect.ps1 -DestinationPath '\\fileserver\Software\Applications\OpenVPNConnect'

.EXAMPLE
    # Sync, then build the Intune package (.intunewin + detection script + README)
    .\Sync\OpenVPNConnect.ps1 -DestinationPath '\\fileserver\Software\Applications\OpenVPNConnect' -BuildIntunePackage
#>
[CmdletBinding()]
param(
    [string]$DestinationPath,

    [string]$CatalogPath,

    [ValidateSet('x64', 'x86')]
    [string[]]$Architectures = @('x64', 'x86'),

    [ValidatePattern('^\d+\.\d+\.\d+\.\d+$')]
    [string]$Version,

    [ValidateRange(1, 20)]
    [int]$KeepVersions = 2,

    # Proxy for internet access, e.g. http://proxy.contoso.local:8080
    [string]$Proxy,

    # Authenticate to the proxy as the account running the script
    [switch]$ProxyUseDefaultCredentials,

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
    AppId        = 'OpenVPNConnect'
    Name         = 'OpenVPN Connect'
    SyncScript   = 'Sync\OpenVPNConnect.ps1'
    ClientScript = 'Apps\OpenVPNConnect.ps1'
    Intune       = @{
        # Install command arguments after the script name. '-SourcePath .' becomes the repo path
        # plus the package's own copy as the fallback.
        InstallCommand  = '-SourcePath . -Install'
        InstallVariants = @(
            '-SourcePath . -Install -ConvertToNativeArchitecture   (replace an installed copy of another architecture, e.g. 32-bit, with the build for this Windows)',
            '-SourcePath . -Install -IgnoreActiveConnection   (updates even while a VPN is connected - drops the connection)'
        )
        # The app's Programs and Features entries (regular expressions), for detection logging and uninstall
        Match           = @{ Pattern = '^OpenVPN Connect'; Exclude = ''; KeyPattern = ''; Exe = '' }
        Detection       = @{
            # How it's detected, as written in Detect.log. Empty = the built-in check of the
            # Programs and Features entry (Match.Pattern) and, if newer, Match.Exe's file version
            Description     = ''
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
            Code            = ''
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
                    "Pass -DestinationPath <share>\OpenVPNConnect, or -CatalogPath <RepoRoot>\OTTOUpdate-Catalog.json " +
                    "(found automatically when this script runs from <RepoRoot>\Administrative\Sync).") -ForegroundColor Red
        exit 1
    }
    try { $catalogData = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $CatalogPath).ProviderPath) | ConvertFrom-Json }
    catch { Write-Host "The repo catalog $CatalogPath can't be read: $($_.Exception.Message). Pass -DestinationPath instead." -ForegroundColor Red; exit 1 }
    $catalogEntry = @($catalogData.Apps) | Where-Object { $_ -and [string]$_.AppId -eq 'OpenVPNConnect' } | Select-Object -First 1
    $catalogFolder = if ($catalogEntry -and $catalogEntry.Folder) { [string]$catalogEntry.Folder } else { 'Applications\OpenVPNConnect' }
    # Folder is the app's full path (e.g. \\fileserver\Software\Applications\Chrome); older catalogs hold a name under the repo root
    $DestinationPath = if ($catalogFolder -match '^\\\\' -or [IO.Path]::IsPathRooted($catalogFolder)) { $catalogFolder }
                       else { Join-Path (Split-Path (Resolve-Path -LiteralPath $CatalogPath).ProviderPath -Parent) $catalogFolder }
    Write-Host ("-DestinationPath from the repo catalog: $DestinationPath" + $(if (-not $catalogEntry) { " (OpenVPNConnect isn't in the catalog yet; it's added after this sync writes latest.json)" }))
}

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
try   { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13 }
catch { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 }   # older .NET has no TLS 1.3

# Apply proxy settings to every web request in this script
if ($Proxy) {
    $PSDefaultParameterValues['Invoke-WebRequest:Proxy']  = $Proxy
    $PSDefaultParameterValues['Invoke-RestMethod:Proxy']  = $Proxy
    if ($ProxyUseDefaultCredentials) {
        $PSDefaultParameterValues['Invoke-WebRequest:ProxyUseDefaultCredentials'] = $true
        $PSDefaultParameterValues['Invoke-RestMethod:ProxyUseDefaultCredentials'] = $true
    }
}

$ReleaseNotesUrl = 'https://openvpn.net/connect-docs/windows-release-notes.html'
$BaseUrls        = @('https://packages.openvpn.net/connect/v3', 'https://swupdate.openvpn.net/downloads/connect')
$Suffix          = @{ x64 = '_signed.msi'; x86 = '_signed_x86.msi' }
$SignerPattern   = 'OpenVPN'
$UserAgent       = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Sync-OpenVPNConnectRepo.ps1'

# --- Helpers -----------------------------------------------------------------
if (-not (Test-Path $DestinationPath)) { New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null }
$logDir = Join-Path $DestinationPath 'Logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$LogFile = Join-Path $logDir 'Sync-OpenVPNConnectRepo.log'

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

function ConvertTo-Version([string]$Text) {
    $m = [regex]::Match([string]$Text, '\d+(\.\d+){0,3}')
    if (-not $m.Success) { return $null }
    $parts = @($m.Value.Split('.')) + @('0', '0', '0', '0') | Select-Object -First 4
    return [version]($parts -join '.')
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

function Get-ErrorDetail($ErrorRecord) {
    # "An error occurred while sending the request" hides the real cause in inner exceptions
    $msgs = @()
    $e = $ErrorRecord.Exception
    while ($e) { $msgs += $e.Message; $e = $e.InnerException }
    return ($msgs | Select-Object -Unique) -join ' --> '
}

function Get-LatestFromWinget {
    # Fallback source: Microsoft's winget package list on GitHub, which records each
    # OpenVPN Connect release with its official download URL and SHA-256.
    $headers = @{ 'User-Agent' = 'Sync-OpenVPNConnectRepo.ps1'; 'Accept' = 'application/vnd.github+json' }
    $root = 'https://api.github.com/repos/microsoft/winget-pkgs/contents/manifests/o/OpenVPNTechnologies/OpenVPNConnect'
    # Assign first, then filter: Windows PowerShell 5.1 and PowerShell 7 differ in whether
    # a JSON array from Invoke-RestMethod is passed down the pipeline item by item.
    $listing = Invoke-RestMethod -Uri $root -Headers $headers
    $dir = @($listing) | ForEach-Object { $_ } |
        Where-Object { $_.type -eq 'dir' -and (ConvertTo-Version $_.name) } |
        Sort-Object { ConvertTo-Version $_.name } -Descending | Select-Object -First 1
    if (-not $dir) { throw 'No OpenVPN Connect versions found in the winget package list.' }
    Write-Log "Latest OpenVPN Connect in winget list: $($dir.name)"

    $folder   = Invoke-RestMethod -Uri ([string]$dir.url) -Headers $headers
    $yamlItem = @($folder) | ForEach-Object { $_ } | Where-Object { $_.name -like '*.installer.yaml' } | Select-Object -First 1
    if (-not $yamlItem) { throw "No installer manifest in winget folder $($dir.name)." }
    $yaml = [string](Invoke-WebRequest -Uri ([string]$yamlItem.download_url) -UseBasicParsing -Headers $headers).Content

    $release = $null
    $hashes  = @{}
    # Each installer entry has an InstallerUrl and an InstallerSha256
    foreach ($block in ($yaml -split '(?m)^\s*-\s+(?=\w+:)')) {
        $u = [regex]::Match($block, 'InstallerUrl:\s*\S*?(openvpn-connect-(\d+\.\d+\.\d+\.\d+)_signed(?:_x86)?\.msi)')
        $h = [regex]::Match($block, 'InstallerSha256:\s*([0-9A-Fa-f]{64})')
        if ($u.Success) {
            $release = $u.Groups[2].Value
            if ($h.Success) { $hashes[$u.Groups[1].Value] = $h.Groups[1].Value.ToUpper() }
        }
    }
    if (-not $release) { throw "Couldn't find an OpenVPN Connect MSI URL in winget manifest $($dir.name)." }
    return @{ Release = $release; Hashes = $hashes }
}

function Get-LatestRelease {
    # Returns @{ Release = '3.9.0.5008'; Hashes = @{ '<file name>' = '<sha256>' } }
    # Primary source: OpenVPN's release notes. Fallback: winget package list on GitHub.
    try {
        # Browser-like headers; openvpn.net's bot protection may cut off bare script requests
        $browserHeaders = @{
            'Accept'          = 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8'
            'Accept-Language' = 'en-US,en;q=0.9'
        }
        $html = (Invoke-WebRequest -Uri $ReleaseNotesUrl -UseBasicParsing -UserAgent $UserAgent -Headers $browserHeaders).Content
    }
    catch {
        Write-Log "Couldn't read $ReleaseNotesUrl : $(Get-ErrorDetail $_)" 'WARN'
        Write-Log 'Trying the winget package list on GitHub instead...'
        try { return Get-LatestFromWinget }
        catch { throw "Both version sources failed. Release notes: see warning above. winget: $(Get-ErrorDetail $_)" }
    }
    $text = [Net.WebUtility]::HtmlDecode(($html -replace '<[^>]+>', ' ')) -replace '\s+', ' '

    # Release headings look like "3.9.0 (5008)"; the first one on the page is the newest
    # (major version limited to 3-9 so things like Windows build numbers aren't picked up)
    $heads = [regex]::Matches($text, '(?<![\d.])([3-9]\.\d{1,2}\.\d{1,2})\s*\((\d{3,6})\)')
    if ($heads.Count -eq 0) { throw 'No release versions found on the release notes page. Use -Version.' }
    $best = $heads | Sort-Object { [version]("$($_.Groups[1].Value).$($_.Groups[2].Value)") } -Descending | Select-Object -First 1
    $release = "$($best.Groups[1].Value).$($best.Groups[2].Value)"

    # Checksums: "openvpn-connect-3.9.0.5008_signed.msi <64 hex>"
    $hashes = @{}
    $pattern = 'openvpn-connect-' + [regex]::Escape($release) + '_signed(?:_x86)?\.msi\W{0,40}?([0-9a-fA-F]{64})'
    foreach ($m in [regex]::Matches($text, $pattern)) {
        $name = [regex]::Match($m.Value, 'openvpn-connect-[\d.]+_signed(?:_x86)?\.msi').Value
        $hashes[$name] = $m.Groups[1].Value.ToUpper()
    }
    return @{ Release = $release; Hashes = $hashes }
}

# --- Main --------------------------------------------------------------------
$tempDir = Join-Path $env:TEMP "ovpnc-sync-$([guid]::NewGuid().ToString('N'))"
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
    Write-Log "Release on share: $(if ($existing) { $existing.Release } else { 'none' })"

    # --- Latest release -------------------------------------------------------
    $published = @{}
    if ($Version) {
        $release = $Version
        Write-Log "Using -Version $release"
        try { $published = (Get-LatestRelease).Hashes } catch { }
    }
    else {
        $info      = Get-LatestRelease
        $release   = $info.Release
        $published = $info.Hashes
        Write-Log "Latest release on OpenVPN's release notes: $release"
    }

    # --- Anything new? -------------------------------------------------------
    if ($existing -and -not $Force -and (ConvertTo-Version $existing.Release) -ge (ConvertTo-Version $release)) {
        $allPresent = $true
        foreach ($arch in $Architectures) {
            $e = $existing.Files.$arch
            if (-not $e -or -not (Test-Path -LiteralPath (Join-Path $DestinationPath $e.FileName))) { $allPresent = $false }
        }
        if ($allPresent) {
            Write-Log 'Share already has the latest release. Nothing to do.'
            exit 0
        }
    }

    # --- Download and verify -------------------------------------------------
    $found = @{}
    foreach ($arch in $Architectures) {
        $fileName = "openvpn-connect-$release$($Suffix[$arch])"
        $local    = Join-Path $tempDir $fileName
        $ok = $false
        foreach ($base in $BaseUrls) {
            $url = "$base/$fileName"
            try {
                Write-Log "Downloading $url"
                Invoke-WebRequest -Uri $url -OutFile $local -UseBasicParsing -UserAgent $UserAgent
                $ok = $true; break
            }
            catch { Write-Log "  failed: $(Get-ErrorDetail $_)" 'WARN' }
        }
        if (-not $ok) { throw "Could not download $fileName from any source." }

        $hash = (Get-FileHash -LiteralPath $local -Algorithm SHA256).Hash
        if ($published[$fileName]) {
            if ($hash -ne $published[$fileName]) { throw "SHA-256 mismatch for $fileName. OpenVPN lists $($published[$fileName]), got $hash." }
            Write-Log "$fileName matches OpenVPN's published SHA-256."
        }
        else {
            Write-Log "No published SHA-256 found for $fileName; relying on the signature check." 'WARN'
        }

        $sig = Get-AuthenticodeSignature -FilePath $local
        if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch $SignerPattern) {
            throw "Signature check failed for $fileName (status: $($sig.Status), signer: $($sig.SignerCertificate.Subject))."
        }

        $productVersion = Get-MsiProperty $local 'ProductVersion'
        $productName    = Get-MsiProperty $local 'ProductName'
        Write-Log "$arch : $productName  ProductVersion $productVersion  signed by $($sig.SignerCertificate.Subject)"
        $found[$arch] = @{ Path = $local; Name = $fileName; Hash = $hash; ProductVersion = $productVersion; ProductName = $productName }
    }

    $pv = @($found.Values | ForEach-Object { $_.ProductVersion } | Sort-Object -Unique)
    if ($pv.Count -gt 1) { throw "The builds report different ProductVersions: $($pv -join ', ')" }

    # --- Publish -------------------------------------------------------------
    $verFolder = Join-Path $DestinationPath $release
    $staging   = "$verFolder.partial"
    if (Test-Path $staging) { Remove-Item $staging -Recurse -Force }
    New-Item -ItemType Directory -Path $staging | Out-Null

    $files = [ordered]@{}
    foreach ($arch in $found.Keys) {
        Copy-Item -LiteralPath $found[$arch].Path -Destination (Join-Path $staging $found[$arch].Name)
        $files[$arch] = [ordered]@{
            FileName = Join-Path $release $found[$arch].Name
            Sha256   = $found[$arch].Hash
        }
    }
    if (Test-Path $verFolder) { Remove-Item $verFolder -Recurse -Force }
    Rename-Item -Path $staging -NewName $release

    $manifest = [ordered]@{
        Product     = 'OpenVPN Connect'
        ProductName = @($found.Values)[0].ProductName
        Release     = $release          # e.g. 3.9.0.5008 (version + build, used for file names)
        Version     = $pv[0]            # MSI ProductVersion = what Programs and Features shows
        UpdatedAt   = (Get-Date).ToString('o')
        Files       = $files
    }
    $tmp = "$manifestPath.tmp"
    $manifest | ConvertTo-Json -Depth 5 | Set-Content -Path $tmp -Encoding UTF8
    Move-Item -Path $tmp -Destination $manifestPath -Force
    Write-Log "Published OpenVPN Connect $release (ProductVersion $($pv[0])) and updated manifest."

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
            Invoke-OTTOIntunePackageBuild -AppId 'OpenVPNConnect' -DestinationPath $DestinationPath -OutputPath $IntuneOutputPath `
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
            Update-OTTOCatalogEntry -AppId 'OpenVPNConnect' -DestinationPath $DestinationPath -ManifestBefore $script:ManifestBefore `
                -Failed ([bool]($script:SyncFailed -or $script:IntuneFailed)) -Script 'Sync\OpenVPNConnect.ps1' `
                -BoundParameters $PSBoundParameters -CatalogPath $CatalogPath -Definition $OTTOAppDefinition -ScriptPath $PSCommandPath -Log { param($m, $l) Write-Log $m $l }
        }
        catch { Write-Log "Couldn't update the repo catalog: $($_.Exception.Message)" 'WARN' }
    }
    # Release the one-sync-per-share lock (it would otherwise stay held until this PowerShell
    # window closes, so a second run in the same window would think a sync is still running)
    if ($script:SyncLock) { $script:SyncLock.Dispose(); $script:SyncLock = $null }
    if ($script:IntuneFailed) { exit 1 }
}
