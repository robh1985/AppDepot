#Requires -RunAsAdministrator
#Requires -Version 5.1
<#
.SYNOPSIS
    Removes the AppDepot server from Windows Server.

.DESCRIPTION
    Undoes what Install-AppDepotServer.ps1 did:

    1. Stops AppDepot and removes the Windows service (NSSM) or the "AppDepot Server" startup task
    2. Removes the SMB share and the "AppDepot API" / "AppDepot SMB" firewall rules
    3. Deletes the program folder: Python environment, logs, appdepot.yaml, database and manifests
    4. Deletes the repository folder (installers and Intune packages)

    The program folder and repository are found from the registered service or task and from
    appdepot.yaml. A summary is shown and confirmed before anything is removed.

    Only files AppDepot created are deleted from the program folder; the folder itself is removed
    when it is empty afterwards. Python, and applications installed on client computers, are not
    touched. Remove the client from computers with Install-AppDepotClient.ps1 -Uninstall.

.PARAMETER InstallPath
    Program folder. Default: found from the registered service or task, otherwise C:\AppDepot or
    D:\AppDepot.

.PARAMETER RepositoryPath
    Repository folder. Default: repository.root from appdepot.yaml.

.PARAMETER ShareName
    SMB share name. Default AppDepot.

.PARAMETER KeepRepository
    Keep the installers and Intune packages, and the share. Use this when computers or Intune
    apps still install from \\<server>\AppDepot, or to reinstall AppDepot later.

.PARAMETER KeepConfig
    Keep appdepot.yaml (API key, settings), the database (version history) and the manifests in
    the program folder, so a later Install-AppDepotServer.ps1 picks them up again. Only the
    Python environment and logs are deleted.

.PARAMETER BackupPath
    Copy appdepot.yaml, the database and the manifests to this folder before deleting anything.

.EXAMPLE
    .\Uninstall-AppDepotServer.ps1
    Removes everything (asks for confirmation).

.EXAMPLE
    .\Uninstall-AppDepotServer.ps1 -KeepRepository -BackupPath D:\AppDepot-backup
    Removes the server, keeps the installers and the share, and saves the configuration first.

.EXAMPLE
    .\Uninstall-AppDepotServer.ps1 -KeepRepository -KeepConfig
    Removes only the program, service, task and firewall rules (e.g. before a clean reinstall).

.EXAMPLE
    .\Uninstall-AppDepotServer.ps1 -WhatIf
    Shows what would be removed.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [string] $InstallPath,
    [string] $RepositoryPath,
    [string] $ShareName = 'AppDepot',
    [switch] $KeepRepository,
    [switch] $KeepConfig,
    [string] $BackupPath
)
$ErrorActionPreference = 'Stop'

function Write-Step($text) { Write-Host "==> $text" -ForegroundColor Cyan }

function Get-RegisteredExe {
    $exe = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\AppDepot\Parameters' -ErrorAction SilentlyContinue).Application
    if (-not $exe) {
        $task = Get-ScheduledTask -TaskName 'AppDepot Server' -ErrorAction SilentlyContinue
        if ($task) { $exe = $task.Actions[0].Execute }
    }
    $exe
}

function Get-YamlValue([string] $File, [string] $Section, [string] $Key) {
    # Minimal reader for "section:\n  key: value" in appdepot.yaml
    $inSection = $false
    foreach ($line in Get-Content $File -Encoding UTF8) {
        if ($line -match '^(\w[\w-]*)\s*:') { $inSection = ($Matches[1] -eq $Section); continue }
        if ($inSection -and $line -match "^\s+$Key\s*:\s*(.+?)\s*$") {
            $value = ($Matches[1] -replace '\s+#.*$', '').Trim().Trim('"', "'")
            if ($value -and $value -ne 'null') { return $value }
        }
    }
    $null
}

function Test-SafeToDelete([string] $Path) {
    if (-not $Path) { return $false }
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    if ($full.Length -le 3) { return $false }                       # a drive root such as D:\
    foreach ($protected in $env:SystemRoot, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData, 'C:\Users') {
        if ($protected -and $full -ieq $protected.TrimEnd('\')) { return $false }
    }
    $true
}

# ------------------------------------------------------------------ find the installation
$exe = Get-RegisteredExe
if (-not $InstallPath) {
    if ($exe -and $exe -match '\\venv\\Scripts\\appdepot-server\.exe$') {
        $InstallPath = Split-Path (Split-Path (Split-Path $exe -Parent) -Parent) -Parent
    }
    else {
        $InstallPath = @('C:\AppDepot', 'D:\AppDepot') | Where-Object { Test-Path (Join-Path $_ 'appdepot.yaml') } | Select-Object -First 1
    }
}
$config = if ($InstallPath) { Join-Path $InstallPath 'appdepot.yaml' }
if (-not $RepositoryPath -and $config -and (Test-Path $config)) {
    $RepositoryPath = Get-YamlValue $config 'repository' 'root'
    if ($RepositoryPath -and -not [IO.Path]::IsPathRooted($RepositoryPath)) { $RepositoryPath = Join-Path $InstallPath $RepositoryPath }
}
$share = Get-SmbShare -Name $ShareName -ErrorAction SilentlyContinue
if (-not $RepositoryPath -and $share) { $RepositoryPath = $share.Path }

$service = Get-Service AppDepot -ErrorAction SilentlyContinue
$task = Get-ScheduledTask -TaskName 'AppDepot Server' -ErrorAction SilentlyContinue
$rules = @(Get-NetFirewallRule -DisplayName 'AppDepot API', 'AppDepot SMB' -ErrorAction SilentlyContinue)

# ------------------------------------------------------------------ summary
$programItems = if ($KeepConfig) { 'venv', 'Logs' } else { 'venv', 'Logs', 'appdepot.yaml', 'appdepot.db', 'appdepot.db-wal', 'appdepot.db-shm', 'manifests' }

Write-Host ''
Write-Host 'AppDepot server uninstall' -ForegroundColor White
Write-Host "  Service 'AppDepot'          : $(if ($service) { 'remove' } else { 'not found' })"
Write-Host "  Task 'AppDepot Server'      : $(if ($task) { 'remove' } else { 'not found' })"
Write-Host "  Firewall rules              : $(if ($rules.Count) { "remove $($rules.Count)" } else { 'not found' })"
Write-Host "  Share \\$env:COMPUTERNAME\$ShareName : $(if (-not $share) { 'not found' } elseif ($KeepRepository) { 'keep' } else { 'remove' })"
Write-Host "  Program folder              : $(if (-not $InstallPath -or -not (Test-Path $InstallPath)) { 'not found' } else { "$InstallPath  (delete: $($programItems -join ', '))" })"
Write-Host "  Repository                  : $(if (-not $RepositoryPath -or -not (Test-Path $RepositoryPath)) { 'not found' } elseif ($KeepRepository) { "$RepositoryPath  (keep)" } else { "$RepositoryPath  (DELETE all installers and Intune packages)" })"
if ($BackupPath) { Write-Host "  Backup to                   : $BackupPath" }
Write-Host ''

if (-not $KeepRepository -and $RepositoryPath -and (Test-Path $RepositoryPath) -and -not (Test-SafeToDelete $RepositoryPath)) {
    throw "Refusing to delete the repository '$RepositoryPath' (a drive root or system folder). Delete its contents yourself or use -KeepRepository."
}
if (-not $PSCmdlet.ShouldProcess("AppDepot server on $env:COMPUTERNAME", 'Uninstall')) { return }

# ------------------------------------------------------------------ backup
if ($BackupPath -and $InstallPath -and (Test-Path $InstallPath)) {
    Write-Step "Backing up configuration, database and manifests to $BackupPath"
    New-Item -ItemType Directory -Path $BackupPath -Force | Out-Null
    foreach ($item in 'appdepot.yaml', 'appdepot.db', 'appdepot.db-wal', 'appdepot.db-shm', 'manifests') {
        $src = Join-Path $InstallPath $item
        if (Test-Path $src) { Copy-Item -Path $src -Destination $BackupPath -Recurse -Force }
    }
}

# ------------------------------------------------------------------ service / task
if ($service) {
    Write-Step "Removing service 'AppDepot'"
    Stop-Service AppDepot -Force -ErrorAction SilentlyContinue
    & sc.exe delete AppDepot | Out-Null
}
if ($task) {
    Write-Step "Removing scheduled task 'AppDepot Server'"
    Stop-ScheduledTask -TaskName 'AppDepot Server' -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName 'AppDepot Server' -Confirm:$false
}
# Anything still running from the venv (e.g. a manual 'check') holds files open
Get-Process appdepot-server, python, pythonw -ErrorAction SilentlyContinue |
    Where-Object { $InstallPath -and $_.Path -and $_.Path.StartsWith((Join-Path $InstallPath 'venv'), [StringComparison]::OrdinalIgnoreCase) } |
    Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2

# ------------------------------------------------------------------ firewall / share
if ($rules.Count) {
    Write-Step 'Removing firewall rules'
    $rules | Remove-NetFirewallRule
}
if ($share -and -not $KeepRepository) {
    Write-Step "Removing share $ShareName"
    Remove-SmbShare -Name $ShareName -Force
}

# ------------------------------------------------------------------ files
$failed = @()
if ($InstallPath -and (Test-Path $InstallPath)) {
    Write-Step "Deleting AppDepot files in $InstallPath"
    foreach ($item in $programItems) {
        $path = Join-Path $InstallPath $item
        if (Test-Path $path) {
            try { Remove-Item -Path $path -Recurse -Force }
            catch { $failed += $path; Write-Warning "Could not delete ${path}: $($_.Exception.Message)" }
        }
    }
}
if (-not $KeepRepository -and $RepositoryPath -and (Test-Path $RepositoryPath)) {
    Write-Step "Deleting repository $RepositoryPath"
    try { Remove-Item -Path $RepositoryPath -Recurse -Force }
    catch { $failed += $RepositoryPath; Write-Warning "Could not delete ${RepositoryPath}: $($_.Exception.Message)" }
}
# Remove the program folder (and an empty parent such as D:\AppDepot) once nothing else is in it
foreach ($dir in @($RepositoryPath, $InstallPath) | Where-Object { $_ }) {
    foreach ($candidate in $dir, (Split-Path $dir -Parent)) {
        if ($candidate -and (Test-SafeToDelete $candidate) -and (Test-Path $candidate) -and
            -not (Get-ChildItem $candidate -Force -ErrorAction SilentlyContinue)) {
            Remove-Item $candidate -Force -ErrorAction SilentlyContinue
        }
    }
}

Write-Host ''
if ($failed) {
    Write-Warning "Some files could not be deleted (in use?). Restart the server and delete them: $($failed -join ', ')"
}
else {
    Write-Host 'AppDepot server removed.' -ForegroundColor Green
}
if ($InstallPath -and (Test-Path $InstallPath)) { Write-Host "Kept in ${InstallPath}: $((Get-ChildItem $InstallPath -Force | ForEach-Object Name) -join ', ')" }
if ($KeepRepository -and $RepositoryPath) { Write-Host "Repository kept: $RepositoryPath$(if ($share) { " (share \\$env:COMPUTERNAME\$ShareName)" })" }
if ($BackupPath) { Write-Host "Backup: $BackupPath" }
Write-Host 'Python is still installed; remove it in Apps & features if nothing else uses it.'
Write-Host 'Remove the client from computers with: Install-AppDepotClient.ps1 -Uninstall'
