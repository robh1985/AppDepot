#Requires -RunAsAdministrator
#Requires -Version 5.1
<#
.SYNOPSIS
    Installs (or removes) the AppDepot client on a Windows computer.

.DESCRIPTION
    * Copies the AppDepot PowerShell module to %ProgramFiles%\WindowsPowerShell\Modules
      (available to Windows PowerShell 5.1 and PowerShell 7)
    * Installs the 'depot' command-line tool to %ProgramFiles%\AppDepot and adds it to PATH
    * Creates a Start menu shortcut for the AppDepot GUI
    * Points the client at your server (client.json in %ProgramData%\AppDepot)
    * Optionally registers a daily scheduled task that installs available updates as SYSTEM

    Suitable for deployment through Intune, Group Policy or ConfigMgr:
      powershell.exe -ExecutionPolicy Bypass -File Install-AppDepotClient.ps1 -ServerUrl http://appdepot:8080

.PARAMETER ServerUrl
    URL of the AppDepot server.

.PARAMETER AutoUpdate
    Register the "AppDepot Auto Update" scheduled task (runs 'depot upgrade --all' as SYSTEM).

.PARAMETER AutoUpdateTime
    Time of day for the automatic update task. Default 12:30.

.PARAMETER Uninstall
    Remove the client, its shortcut, PATH entry and scheduled task.

.EXAMPLE
    .\Install-AppDepotClient.ps1 -ServerUrl http://appdepot.corp.example.com:8080 -AutoUpdate

.EXAMPLE
    .\Install-AppDepotClient.ps1 -Uninstall
#>
[CmdletBinding(DefaultParameterSetName = 'Install')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Install')] [ValidatePattern('^https?://')] [string] $ServerUrl,
    [Parameter(ParameterSetName = 'Install')] [switch] $AutoUpdate,
    [Parameter(ParameterSetName = 'Install')] [string] $AutoUpdateTime = '12:30',
    [Parameter(Mandatory, ParameterSetName = 'Uninstall')] [switch] $Uninstall
)
$ErrorActionPreference = 'Stop'
$moduleTarget = Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules\AppDepot'
$toolTarget = Join-Path $env:ProgramFiles 'AppDepot'
$dataPath = Join-Path $env:ProgramData 'AppDepot'
$shortcut = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\AppDepot.lnk'
$taskName = 'AppDepot Auto Update'

function Set-MachinePath([string] $Folder, [bool] $Add) {
    $path = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $parts = @($path -split ';' | Where-Object { $_ -and $_.TrimEnd('\') -ne $Folder.TrimEnd('\') })
    if ($Add) { $parts += $Folder }
    [Environment]::SetEnvironmentVariable('Path', ($parts -join ';'), 'Machine')
}

if ($Uninstall) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Item $moduleTarget, $toolTarget, $shortcut -Recurse -Force -ErrorAction SilentlyContinue
    Set-MachinePath $toolTarget $false
    Write-Host 'AppDepot client removed. Configuration and logs in' $dataPath 'were kept.'
    return
}

# Module
$version = (Import-PowerShellDataFile (Join-Path $PSScriptRoot 'AppDepot\AppDepot.psd1')).ModuleVersion
$versionTarget = Join-Path $moduleTarget $version
Remove-Item $moduleTarget -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $versionTarget -Force | Out-Null
Copy-Item -Path (Join-Path $PSScriptRoot 'AppDepot\*') -Destination $versionTarget -Recurse -Force

# CLI (depot.ps1 imports the installed module when it is not next to it)
New-Item -ItemType Directory -Path $toolTarget -Force | Out-Null
Copy-Item -Path (Join-Path $PSScriptRoot 'depot.ps1'), (Join-Path $PSScriptRoot 'depot.cmd') -Destination $toolTarget -Force
Set-MachinePath $toolTarget $true

# Data folder stays admin-writable only: the SYSTEM update task trusts client.json and the cache.
# (Standard users automatically use %LOCALAPPDATA%\AppDepot for their own cache and logs.)
foreach ($sub in 'Cache', 'Logs') { New-Item -ItemType Directory -Path (Join-Path $dataPath $sub) -Force | Out-Null }

Import-Module $versionTarget\AppDepot.psd1 -Force
Set-DepotConfig -ServerUrl $ServerUrl -Confirm:$false | Out-Null

# Start menu shortcut
$shell = New-Object -ComObject WScript.Shell
$lnk = $shell.CreateShortcut($shortcut)
$lnk.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$lnk.Arguments = '-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -Command "Import-Module AppDepot; Show-DepotGui"'
$lnk.IconLocation = "$env:SystemRoot\System32\imageres.dll,186"
$lnk.Description = 'Install and update applications from the AppDepot repository'
$lnk.Save()

if ($AutoUpdate) {
    $action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
        -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$toolTarget\depot.ps1`" upgrade --all --quiet"
    $trigger = New-ScheduledTaskTrigger -Daily -At $AutoUpdateTime
    $trigger.RandomDelay = 'PT1H'   # spread load on the repository
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -RunOnlyIfNetworkAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 3)
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -User 'SYSTEM' -RunLevel Highest -Force | Out-Null
}

$test = Test-DepotConnection
Write-Host "AppDepot client $version installed." -ForegroundColor Green
Write-Host "  Server: $ServerUrl  (reachable: $($test.Reachable); share reachable: $($test.UncReachable))"
Write-Host "  CLI:    depot help   (open a new console for PATH changes)"
Write-Host "  GUI:    Start menu > AppDepot"
if ($AutoUpdate) { Write-Host "  Updates are installed daily around $AutoUpdateTime (task '$taskName')." }
