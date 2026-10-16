#Requires -RunAsAdministrator
#Requires -Version 5.1
<#
.SYNOPSIS
    Installs the AppDepot server on Windows Server.

.DESCRIPTION
    1. Creates a Python virtual environment and installs the AppDepot server into it
    2. Creates the repository folder and an SMB share for it (read access for authenticated
       users and computers, full control for administrators)
    3. Writes appdepot.yaml (with a random API key) if it does not exist
    4. Opens the API port in Windows Firewall, optionally limited to your VLAN subnets
    5. Registers AppDepot as a Windows service (NSSM) or, without NSSM, a startup scheduled task

    6. Adds the bundled application catalog (server\manifests) to the manifests folder

    Re-running the script upgrades the installation and keeps the existing configuration. New
    applications from the bundled catalog are added; manifests you have edited or removed are left
    alone (use -UpdateCatalog to replace edited ones, -SkipCatalog to add none).

.PARAMETER InstallPath
    Program folder (virtual environment, appdepot.yaml, database, logs, manifests).
    Default: an existing installation if there is one, otherwise \AppDepot on the same drive as
    -RepositoryPath (D:\AppDepot for the default repository path).

    To move an existing installation, give the new folder: the service is stopped, appdepot.yaml,
    the database, manifests and logs are copied there, paths in appdepot.yaml are updated and the
    service is re-registered from the new folder. The old folder is left in place for you to delete.

.PARAMETER RepositoryPath
    Folder that holds the installers and Intune packages. Default D:\AppDepot\Repository

.PARAMETER ShareName
    SMB share name for the repository. Default AppDepot  (\\<server>\AppDepot)

.PARAMETER Port
    HTTP port for the API. Default 8080

.PARAMETER AllowedSubnets
    Client subnets (VLANs) allowed to reach the API, e.g. '10.10.0.0/16','10.20.30.0/24'.
    Default: any address.

.PARAMETER PublicHostName
    DNS name clients use to reach this server. Default: the computer's FQDN.

.PARAMETER PythonPath
    python.exe to use (3.10 or newer). Default: 'py -3' / python on PATH.

.PARAMETER NssmPath
    Path to nssm.exe to run AppDepot as a real Windows service.

.PARAMETER SkipCatalog
    Do not add the bundled applications.

.PARAMETER UpdateCatalog
    Also replace installed manifests that differ from the bundled ones (each old file is kept as
    *.yaml.bak).

.PARAMETER CheckNow
    Download the newly added applications straight away instead of waiting for the schedule.

.EXAMPLE
    .\Install-AppDepotServer.ps1 -InstallPath D:\AppDepot
    Moves an installation from C:\AppDepot to D:\AppDepot (repository files are not touched).

.EXAMPLE
    .\Install-AppDepotServer.ps1 -RepositoryPath E:\AppDepot -AllowedSubnets 10.10.0.0/16,10.20.0.0/16 -NssmPath C:\Tools\nssm.exe
#>
[CmdletBinding()]
param(
    [string] $InstallPath,
    [string] $RepositoryPath = 'D:\AppDepot\Repository',
    [string] $ShareName = 'AppDepot',
    [int] $Port = 8080,
    [string[]] $AllowedSubnets = @('Any'),
    [string] $PublicHostName = ([System.Net.Dns]::GetHostEntry($env:COMPUTERNAME).HostName),
    [string] $PythonPath,
    [string] $NssmPath,
    [switch] $SkipCatalog,
    [switch] $UpdateCatalog,
    [switch] $CheckNow
)
$ErrorActionPreference = 'Stop'
$source = Split-Path -Parent $PSScriptRoot     # ...\server

function Write-Step($text) { Write-Host "==> $text" -ForegroundColor Cyan }

function Get-ExistingInstallPath {
    # From the registered service (NSSM) or scheduled task: <InstallPath>\venv\Scripts\appdepot-server.exe
    $exePath = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\AppDepot\Parameters' -ErrorAction SilentlyContinue).Application
    if (-not $exePath) {
        $task = Get-ScheduledTask -TaskName 'AppDepot Server' -ErrorAction SilentlyContinue
        if ($task) { $exePath = $task.Actions[0].Execute }
    }
    if ($exePath -and $exePath -match '\\venv\\Scripts\\appdepot-server\.exe$') {
        $dir = Split-Path (Split-Path (Split-Path $exePath -Parent) -Parent) -Parent
        if (Test-Path (Join-Path $dir 'appdepot.yaml')) { return $dir }
    }
    if (Test-Path 'C:\AppDepot\appdepot.yaml') { return 'C:\AppDepot' }
    return $null
}

function Stop-AppDepotServer {
    if (Get-Service AppDepot -ErrorAction SilentlyContinue) { Stop-Service AppDepot -Force -ErrorAction SilentlyContinue }
    if (Get-ScheduledTask -TaskName 'AppDepot Server' -ErrorAction SilentlyContinue) {
        Stop-ScheduledTask -TaskName 'AppDepot Server' -ErrorAction SilentlyContinue
    }
    Get-Process appdepot-server -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
}

function Move-AppDepotInstallation([string] $From, [string] $To) {
    Write-Step "Moving the installation from $From to $To"
    Stop-AppDepotServer
    New-Item -ItemType Directory -Path $To -Force | Out-Null
    foreach ($item in 'appdepot.yaml', 'appdepot.db', 'appdepot.db-wal', 'appdepot.db-shm', 'manifests', 'Logs') {
        $src = Join-Path $From $item
        if (Test-Path $src) { Copy-Item -Path $src -Destination $To -Recurse -Force }
    }
    # Point paths in appdepot.yaml (database, log file, manifests) at the new folder. The repository
    # root is left alone: moving installers and Intune packages is a separate, deliberate step.
    $configFile = Join-Path $To 'appdepot.yaml'
    $fromPattern = '(?i)' + [regex]::Escape($From.TrimEnd('\')).Replace('\\', '[\\/]') + '(?=[\\/''"\s]|$)'
    $lines = foreach ($line in Get-Content $configFile -Encoding UTF8) {
        if ($line -match '^\s*root\s*:' -and $line -match $fromPattern) {
            Write-Warning "repository.root is inside $From and was not changed: $($line.Trim())"
            $line
        }
        else {
            [regex]::Replace($line, $fromPattern, { param($m) if ($m.Value.Contains('/')) { $To.Replace('\', '/') } else { $To.TrimEnd('\') } })
        }
    }
    Set-Content -Path $configFile -Value $lines -Encoding UTF8
    Write-Host "    Copied configuration, database, manifests and logs. When AppDepot runs from $To, delete $From."
}

# ------------------------------------------------------------------ Python + venv
Write-Step 'Preparing Python environment'
if (-not $PythonPath) {
    $py = Get-Command py.exe -ErrorAction SilentlyContinue
    if ($py) { $PythonPath = (& py.exe -3 -c 'import sys; print(sys.executable)').Trim() }
    else { $PythonPath = (Get-Command python.exe -ErrorAction Stop).Source }
}
$ver = & $PythonPath -c 'import sys; print("%d.%d" % sys.version_info[:2])'
if ([version]$ver -lt [version]'3.10') { throw "Python 3.10 or newer is required (found $ver at $PythonPath)." }

$repoDrive = Split-Path -Qualifier $RepositoryPath -ErrorAction SilentlyContinue
if ($repoDrive -and -not (Test-Path "$repoDrive\")) { throw "Drive $repoDrive (from -RepositoryPath $RepositoryPath) does not exist." }
$existing = Get-ExistingInstallPath
if (-not $InstallPath) {
    $InstallPath = if ($existing) { $existing } elseif ($repoDrive) { "$repoDrive\AppDepot" } else { 'C:\AppDepot' }
}
$InstallPath = $InstallPath.TrimEnd('\')
Write-Host "    Program folder: $InstallPath    Repository: $RepositoryPath"
if ($existing -and -not $PSBoundParameters.ContainsKey('InstallPath') -and $repoDrive -and
    -not $InstallPath.StartsWith($repoDrive, [StringComparison]::OrdinalIgnoreCase)) {
    Write-Host "    Upgrading the existing installation in $InstallPath. To move it to $repoDrive, run again with -InstallPath $repoDrive\AppDepot" -ForegroundColor Yellow
}
if ($existing -and $existing.TrimEnd('\') -ne $InstallPath -and -not (Test-Path (Join-Path $InstallPath 'appdepot.yaml'))) {
    Move-AppDepotInstallation -From $existing -To $InstallPath
}

New-Item -ItemType Directory -Path $InstallPath, "$InstallPath\Logs", $RepositoryPath -Force | Out-Null
$venv = Join-Path $InstallPath 'venv'
if (-not (Test-Path "$venv\Scripts\python.exe")) { & $PythonPath -m venv $venv }
& "$venv\Scripts\python.exe" -m pip install --upgrade pip --quiet --no-cache-dir
& "$venv\Scripts\python.exe" -m pip install --upgrade $source --quiet --no-cache-dir
if ($LASTEXITCODE) { throw 'pip install failed' }

# ------------------------------------------------------------------ configuration
Write-Step 'Writing configuration'
$manifests = Join-Path $InstallPath 'manifests'
New-Item -ItemType Directory -Path $manifests -Force | Out-Null
$config = Join-Path $InstallPath 'appdepot.yaml'
if (-not (Test-Path $config)) {
    $bytes = New-Object byte[] 32
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $apiKey = [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    $yaml = (Get-Content (Join-Path $source 'appdepot.example.yaml') -Raw)
    $yaml = $yaml.Replace('http://appdepot.corp.example.com:8080', "http://${PublicHostName}:$Port")
    $yaml = $yaml.Replace('replace-with-a-long-random-string', $apiKey)
    $yaml = $yaml.Replace('D:\AppDepot\Repository', $RepositoryPath)
    $yaml = $yaml.Replace('\\appdepot\AppDepot', "\\$PublicHostName\$ShareName")
    $yaml = $yaml.Replace('sqlite:///D:/AppDepot/appdepot.db', 'sqlite:///' + ($InstallPath -replace '\\', '/') + '/appdepot.db')
    $yaml = $yaml.Replace('D:\AppDepot\Logs\appdepot.log', "$InstallPath\Logs\appdepot.log")
    $yaml = $yaml -replace 'port: 8080', "port: $Port"
    Set-Content -Path $config -Value $yaml -Encoding UTF8
    Write-Host "    API key (store it safely, needed for admin commands): $apiKey" -ForegroundColor Yellow
}
else { Write-Host "    Keeping existing $config" }

# ------------------------------------------------------------------ SMB share
Write-Step "Sharing $RepositoryPath as \\$env:COMPUTERNAME\$ShareName"
if (-not (Get-SmbShare -Name $ShareName -ErrorAction SilentlyContinue)) {
    New-SmbShare -Name $ShareName -Path $RepositoryPath -ReadAccess 'Authenticated Users' -FullAccess 'BUILTIN\Administrators' `
        -Description 'AppDepot application repository' -FolderEnumerationMode AccessBased | Out-Null
}
# NTFS: read for authenticated users (includes computer accounts used by SYSTEM installs)
$acl = Get-Acl $RepositoryPath
$rule = New-Object Security.AccessControl.FileSystemAccessRule('Authenticated Users', 'ReadAndExecute', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
$acl.AddAccessRule($rule)
Set-Acl -Path $RepositoryPath -AclObject $acl

# ------------------------------------------------------------------ firewall
Write-Step "Opening TCP $Port for: $($AllowedSubnets -join ', ')"
Get-NetFirewallRule -DisplayName 'AppDepot API' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
New-NetFirewallRule -DisplayName 'AppDepot API' -Direction Inbound -Protocol TCP -LocalPort $Port `
    -RemoteAddress $AllowedSubnets -Action Allow -Profile Domain, Private | Out-Null
if ($AllowedSubnets -notcontains 'Any') {
    # SMB is usually already open on servers; make sure the client VLANs can reach it too.
    Get-NetFirewallRule -DisplayName 'AppDepot SMB' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    New-NetFirewallRule -DisplayName 'AppDepot SMB' -Direction Inbound -Protocol TCP -LocalPort 445 `
        -RemoteAddress $AllowedSubnets -Action Allow -Profile Domain, Private | Out-Null
}

# ------------------------------------------------------------------ service
$exe = "$venv\Scripts\appdepot-server.exe"
if (-not $NssmPath) {
    # Re-runs keep using the NSSM service an earlier run registered
    $svc = Get-CimInstance Win32_Service -Filter "Name='AppDepot'" -ErrorAction SilentlyContinue
    if ($svc -and $svc.PathName -match 'nssm') { $NssmPath = ($svc.PathName -replace '^"([^"]+)".*$', '$1').Trim() }
}
& "$venv\Scripts\python.exe" -m appdepot_server -c $config sync | Out-Null
if (-not $SkipCatalog) {
    Write-Step 'Adding the bundled application catalog'
    $catalogArgs = @('-m', 'appdepot_server', '-c', $config, 'app', 'add-catalog')
    if ($UpdateCatalog) { $catalogArgs += '--overwrite' }
    & "$venv\Scripts\python.exe" @catalogArgs | ForEach-Object { "    $_" }
}
if ($NssmPath) {
    Write-Step 'Registering Windows service "AppDepot" (NSSM)'
    if (Get-Service AppDepot -ErrorAction SilentlyContinue) { & $NssmPath stop AppDepot | Out-Null; & $NssmPath remove AppDepot confirm | Out-Null }
    & $NssmPath install AppDepot $exe "--config `"$config`" serve" | Out-Null
    & $NssmPath set AppDepot AppDirectory $InstallPath | Out-Null
    & $NssmPath set AppDepot DisplayName 'AppDepot Application Repository' | Out-Null
    & $NssmPath set AppDepot Start SERVICE_AUTO_START | Out-Null
    & $NssmPath set AppDepot AppStdout "$InstallPath\Logs\service.log" | Out-Null
    & $NssmPath set AppDepot AppStderr "$InstallPath\Logs\service.log" | Out-Null
    & $NssmPath set AppDepot AppRotateFiles 1 | Out-Null
    Start-Service AppDepot
}
else {
    Write-Step 'Registering startup scheduled task "AppDepot Server" (install NSSM for a real service)'
    $action = New-ScheduledTaskAction -Execute $exe -Argument "--config `"$config`" serve" -WorkingDirectory $InstallPath
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $settings = New-ScheduledTaskSettingsSet -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero)
    Register-ScheduledTask -TaskName 'AppDepot Server' -Action $action -Trigger $trigger -Settings $settings `
        -User 'SYSTEM' -RunLevel Highest -Force | Out-Null
    Start-ScheduledTask -TaskName 'AppDepot Server'
}

Start-Sleep -Seconds 5
try {
    $h = Invoke-RestMethod "http://localhost:$Port/api/v1/health" -UseBasicParsing
    Write-Host "`nAppDepot $($h.version) is running: http://${PublicHostName}:$Port  (dashboard), /docs (API)" -ForegroundColor Green
    Write-Host "Repository share: \\$PublicHostName\$ShareName"
    if ($CheckNow) {
        Start-Process -FilePath $exe -ArgumentList "--config `"$config`" check" -WindowStyle Hidden `
            -RedirectStandardOutput "$InstallPath\Logs\first-check.log" -RedirectStandardError "$InstallPath\Logs\first-check.err.log"
        Write-Host "Downloading all applications in the background ($InstallPath\Logs\first-check.log)."
        Write-Host "Follow it with: & '$exe' --config '$config' events"
    }
    else {
        Write-Host "Next: review $config and the manifests in $manifests, then download everything with:"
        Write-Host "  & '$exe' --config '$config' check"
    }
}
catch { Write-Warning "The server did not answer yet. Check $InstallPath\Logs." }
