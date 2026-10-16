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
    Program folder (code, virtual environment, config, database). Default C:\AppDepot

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
    .\Install-AppDepotServer.ps1 -RepositoryPath E:\AppDepot -AllowedSubnets 10.10.0.0/16,10.20.0.0/16 -NssmPath C:\Tools\nssm.exe
#>
[CmdletBinding()]
param(
    [string] $InstallPath = 'C:\AppDepot',
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

# ------------------------------------------------------------------ Python + venv
Write-Step 'Preparing Python environment'
if (-not $PythonPath) {
    $py = Get-Command py.exe -ErrorAction SilentlyContinue
    if ($py) { $PythonPath = (& py.exe -3 -c 'import sys; print(sys.executable)').Trim() }
    else { $PythonPath = (Get-Command python.exe -ErrorAction Stop).Source }
}
$ver = & $PythonPath -c 'import sys; print("%d.%d" % sys.version_info[:2])'
if ([version]$ver -lt [version]'3.10') { throw "Python 3.10 or newer is required (found $ver at $PythonPath)." }

New-Item -ItemType Directory -Path $InstallPath, "$InstallPath\Logs", $RepositoryPath -Force | Out-Null
$venv = Join-Path $InstallPath 'venv'
if (-not (Test-Path "$venv\Scripts\python.exe")) { & $PythonPath -m venv $venv }
& "$venv\Scripts\python.exe" -m pip install --upgrade pip --quiet
& "$venv\Scripts\python.exe" -m pip install --upgrade $source --quiet
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
