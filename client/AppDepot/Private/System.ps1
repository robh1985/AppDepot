function Write-DepotLog {
    <#
    .SYNOPSIS
        Appends a line to the AppDepot client log and writes it to the verbose stream.
    #>
    param(
        [Parameter(Mandatory)] [string] $Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')] [string] $Level = 'INFO'
    )
    Write-Verbose $Message
    try {
        $dir = (Read-DepotConfig).LogPath
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $line = '{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}: {3}' -f (Get-Date), $Level, $env:USERNAME, $Message
        Add-Content -LiteralPath (Join-Path $dir 'AppDepot.log') -Value $line -Encoding UTF8
    }
    catch {
        Write-Verbose "Could not write log: $($_.Exception.Message)"
    }
}

function Test-DepotWindows {
    return ($PSVersionTable.PSVersion.Major -lt 6) -or $IsWindows
}

function Test-DepotElevated {
    if (-not (Test-DepotWindows)) { return $false }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-DepotUninstallEntry {
    <#
    .SYNOPSIS
        Reads Programs and Features entries from the registry (machine 64/32-bit and current user).
    #>
    [CmdletBinding()]
    param()
    if (-not (Test-DepotWindows)) {
        Write-Verbose 'Installed-application detection is only available on Windows.'
        return
    }
    $roots = @(
        @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'; Scope = 'Machine'; Arch = 'x64' },
        @{ Path = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'; Scope = 'Machine'; Arch = 'x86' },
        @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'; Scope = 'User'; Arch = '' }
    )
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root.Path)) { continue }
        foreach ($key in Get-ChildItem -LiteralPath $root.Path -ErrorAction SilentlyContinue) {
            $p = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction SilentlyContinue
            if (-not $p -or -not $p.DisplayName -or $p.SystemComponent -eq 1) { continue }
            [pscustomobject]@{
                DisplayName          = [string]$p.DisplayName
                DisplayVersion       = [string]$p.DisplayVersion
                Publisher            = [string]$p.Publisher
                KeyName              = $key.PSChildName
                UninstallString      = [string]$p.UninstallString
                QuietUninstallString = [string]$p.QuietUninstallString
                WindowsInstaller     = ($p.WindowsInstaller -eq 1)
                InstallLocation      = [string]$p.InstallLocation
                Scope                = $root.Scope
                RegistryArch         = $root.Arch
            }
        }
    }
}

function Find-DepotInstalledEntry {
    <#
    .SYNOPSIS
        Finds the registry entry that corresponds to a catalog application.
    .DESCRIPTION
        Matches MSI product codes first, then the detection display-name regex (and optional
        publisher regex). When several entries match, the highest version wins.
    #>
    param(
        [Parameter(Mandatory)] $Detection,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Entries
    )
    $codes = @($Detection.product_codes | Where-Object { $_ })
    $matched = @(foreach ($e in $Entries) {
            if ($codes -contains $e.KeyName) { $e; continue }
            if ($Detection.display_name -and $e.DisplayName -match $Detection.display_name) {
                if ($Detection.publisher -and $e.Publisher -notmatch $Detection.publisher) { continue }
                $e
            }
        })
    if ($matched.Count -eq 0) { return $null }
    if ($matched.Count -eq 1) { return $matched[0] }
    $best = $matched[0]
    foreach ($m in $matched) {
        if ((Compare-DepotVersion $m.DisplayVersion $best.DisplayVersion) -gt 0) { $best = $m }
    }
    return $best
}

function Split-DepotCommandLine {
    <#
    .SYNOPSIS
        Splits '"C:\path\app.exe" /S' or 'C:\path\app.exe /S' into executable and arguments.
    #>
    param([Parameter(Mandatory)] [string] $CommandLine)
    $cmd = [Environment]::ExpandEnvironmentVariables($CommandLine.Trim())
    if ($cmd -match '^"([^"]+)"\s*(.*)$') {
        return [pscustomobject]@{ FilePath = $Matches[1]; Arguments = $Matches[2] }
    }
    if ($cmd -match '^(.+?\.(exe|cmd|bat|com))(\s+(.*))?$') {
        return [pscustomobject]@{ FilePath = $Matches[1]; Arguments = [string]$Matches[4] }
    }
    $parts = $cmd.Split(' ', 2)
    return [pscustomobject]@{ FilePath = $parts[0]; Arguments = $(if ($parts.Count -gt 1) { $parts[1] } else { '' }) }
}

function Invoke-DepotProcess {
    <#
    .SYNOPSIS
        Runs an installer/uninstaller, waits for it and returns the exit code.
    #>
    param(
        [Parameter(Mandatory)] [string] $FilePath,
        [string] $Arguments = '',
        [string] $WorkingDirectory,
        [int] $TimeoutMinutes = 60
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = $Arguments
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }

    Write-DepotLog "Running: `"$FilePath`" $Arguments"
    $process = [System.Diagnostics.Process]::Start($psi)
    if (-not $process.WaitForExit($TimeoutMinutes * 60 * 1000)) {
        try { $process.Kill() } catch { Write-Verbose $_ }
        throw "Process '$FilePath' did not finish within $TimeoutMinutes minutes and was terminated."
    }
    return $process.ExitCode
}

function Get-DepotExitCodeMeaning {
    param([int] $ExitCode)
    switch ($ExitCode) {
        0 { 'Success' }
        1602 { 'Cancelled by user' }
        1603 { 'Fatal error during installation' }
        1618 { 'Another installation is in progress' }
        1619 { 'Installation package could not be opened' }
        1638 { 'Another version of this product is already installed' }
        1641 { 'Success - restart initiated' }
        1707 { 'Success' }
        3010 { 'Success - restart required' }
        default { "Exit code $ExitCode" }
    }
}

function Get-DepotSilentUninstallArgs {
    param([string] $InstallerType)
    switch ($InstallerType) {
        'nullsoft' { '/S' }
        'inno' { '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART' }
        'burn' { '/uninstall /quiet /norestart' }
        default { '' }
    }
}

function New-DepotResult {
    param(
        [string] $Id, [string] $Name, [string] $Version, [string] $Action,
        [string] $Status, [Nullable[int]] $ExitCode, [bool] $RebootRequired = $false, [string] $Message
    )
    [pscustomobject]@{
        PSTypeName     = 'AppDepot.Result'
        Id             = $Id
        Name           = $Name
        Version        = $Version
        Action         = $Action
        Status         = $Status
        ExitCode       = $ExitCode
        RebootRequired = $RebootRequired
        Message        = $Message
        Timestamp      = Get-Date
    }
}
