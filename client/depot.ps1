<#
.SYNOPSIS
    depot - command-line client for the AppDepot application repository.

.DESCRIPTION
    A winget-style front end to the AppDepot PowerShell module. Run 'depot help' for usage.

    Exit codes:
      0     success
      1     an operation failed
      2     invalid usage
      3010  success, a restart is required
#>
# Deliberately not an advanced script: common parameters would capture flags such as -v.
$CommandLine = @($args)

$ErrorActionPreference = 'Stop'
$modulePath = Join-Path $PSScriptRoot 'AppDepot\AppDepot.psd1'
if (Test-Path -LiteralPath $modulePath) { Import-Module $modulePath -Force } else { Import-Module AppDepot }

# ----------------------------------------------------------------------------- argument parsing
$positional = New-Object System.Collections.Generic.List[string]
$opts = @{}
$flagsWithValue = 'version', 'category', 'dest', 'server', 'last', 'app', 'method'
$argsList = @($CommandLine | Where-Object { $null -ne $_ })
for ($i = 0; $i -lt $argsList.Count; $i++) {
    $a = $argsList[$i]
    if ($a -match '^--?([A-Za-z][\w-]*)(=(.*))?$') {
        $name = $Matches[1].ToLowerInvariant()
        $aliases = @{ v = 'version'; f = 'force'; y = 'yes'; h = 'help'; a = 'all'; s = 'server'; d = 'dest'; q = 'quiet' }
        if ($aliases.ContainsKey($name)) { $name = $aliases[$name] }
        if ($Matches[2]) { $opts[$name] = $Matches[3] }
        elseif ($flagsWithValue -contains $name -and $i + 1 -lt $argsList.Count) { $opts[$name] = $argsList[++$i] }
        else { $opts[$name] = $true }
    }
    else { $positional.Add($a) }
}
$command = if ($positional.Count) { $positional[0].ToLowerInvariant() } else { 'help' }
$rest = @($positional | Select-Object -Skip 1)
if ($opts.help) { $rest = @($command); $command = 'help' }
if ($opts.server) { $env:APPDEPOT_SERVER = $opts.server }
if ($opts.verbose) { $VerbosePreference = 'Continue' }
$json = [bool]$opts.json

# ----------------------------------------------------------------------------- output helpers
function Format-Size($Bytes) {
    if (-not $Bytes) { return '' }
    if ($Bytes -ge 1MB) { return '{0:N1} MB' -f ($Bytes / 1MB) }
    return '{0:N0} KB' -f [Math]::Ceiling($Bytes / 1KB)
}

function Write-Out {
    param($Data, [object[]] $Property)
    if ($json) {
        $items = @($Data | ForEach-Object {
                if ($Property) { $_ | Select-Object -Property $Property } else { $_ | Select-Object -Property * -ExcludeProperty Raw }
            })
        ConvertTo-Json -InputObject $items -Depth 6
        return
    }
    if ($Property) { $Data | Format-Table -Property $Property -AutoSize | Out-String -Width 220 | Write-Host }
    else { $Data | Out-String -Width 220 | Write-Host }
}

function Write-Info([string] $Text, [string] $Color = 'Gray') { if (-not $json -and -not $opts.quiet) { Write-Host $Text -ForegroundColor $Color } }

function Exit-WithResults($Results) {
    $results = @($Results)
    if ($json) { Write-Out $results }
    foreach ($r in $results) {
        if ($json) { break }
        $color = switch ($r.Status) { 'Success' { 'Green' } 'Skipped' { 'Yellow' } 'NotInstalled' { 'Yellow' } default { 'Red' } }
        $text = "{0,-9} {1} {2}: {3}" -f $r.Action, $r.Id, $r.Version, $r.Status
        if ($null -ne $r.ExitCode) { $text += " (exit code $($r.ExitCode))" }
        if ($r.Status -ne 'Success' -and $r.Message) { $text += " - $($r.Message)" }
        Write-Host $text -ForegroundColor $color
    }
    if ($results | Where-Object { $_.Status -eq 'Failed' }) { exit 1 }
    if ($results | Where-Object { $_.RebootRequired }) { Write-Info 'A restart is required to complete the operation.' Yellow; exit 3010 }
    exit 0
}

function Assert-Arg([int] $Count, [string] $Usage) {
    if ($rest.Count -lt $Count) { Write-Host "Usage: $Usage" -ForegroundColor Yellow; exit 2 }
}

$help = @{
    ''        = @'
depot - AppDepot repository client

USAGE
  depot <command> [arguments] [options]

BROWSE
  list [filter] [--category C]       List applications in the repository
  search <query>                     Search ids, names, publishers and descriptions
  show <id>                          Details, stored versions and install commands
  versions <id>                      Versions kept in the repository

THIS COMPUTER
  installed                          Repository applications installed on this computer
  upgrade                            List available updates
  upgrade <id> [<id>...] | --all     Install updates
  install <id> [<id>...]             Install applications [--version V] [--force] [--keep]
  uninstall <id>                     Uninstall an application [--yes]
  download <id> [--dest DIR]         Copy an installer from the repository [--version V] [--intune]

SERVER
  status [<id>]                      Server status, schedules and failed checks
  events [--app ID] [--last N]       Server event log [--errors]
  server check [<id>...] [--force]   Check the internet for new versions now [--wait]   (API key)
  server schedule global "<cron>"    Change the global update schedule                  (API key)
  server schedule <id> "<cron>"      Per-app schedule; use manual or global as value    (API key)

CLIENT
  config                             Show configuration
  config set <name> <value>          ServerUrl, TransferMethod (Auto|Unc|Http), KeepInstallers, ApiKey ...
  test                               Test the connection to the server and share
  gui                                Open the graphical client
  help [command]                     Help for a command (or: Get-Help <cmdlet> -Full)

GLOBAL OPTIONS
  --json            Machine-readable output
  --server URL      Use another server for this command
  --quiet           Less output
  --verbose         Show detailed progress

EXIT CODES
  0 success, 1 failure, 2 usage error, 3010 success but restart required
'@
    'install' = "depot install <id> [<id>...] [--version V] [--force] [--keep]`n`nInstalls applications silently from the repository. Equivalent cmdlet: Install-DepotApp.`n  --version V   install a specific stored version (default latest)`n  --force       reinstall even if the same or newer version is installed`n  --keep        keep the installer in the local cache"
    'upgrade' = "depot upgrade                 list available updates`ndepot upgrade <id> [<id>...]  update specific applications`ndepot upgrade --all           update everything`n`nEquivalent cmdlets: Get-DepotUpdate, Update-DepotApp."
    'config'  = "depot config                        show configuration`ndepot config set <name> <value>     change a setting`n`nNames: ServerUrl, TransferMethod (Auto|Unc|Http), CachePath, LogPath, TimeoutSec,`n       InstallTimeoutMinutes, KeepInstallers (true|false), ApiKey`nExample: depot config set ServerUrl http://appdepot.corp.example.com:8080"
    'server'  = "depot server check [<id>...] [--force] [--wait]`ndepot server schedule global `"0 3 * * *`"`ndepot server schedule <id> `"0 */6 * * *`" | manual | global`n`nCron format: minute hour day-of-month month day-of-week. Requires the API key:`n  depot config set ApiKey <key>   (or set APPDEPOT_API_KEY)"
}

# ----------------------------------------------------------------------------- commands
try {
    switch ($command) {
        { $_ -in 'help', '-?', '/?' } {
            $topic = if ($rest.Count) { $rest[0].ToLowerInvariant() } else { '' }
            if ($help.ContainsKey($topic)) { Write-Host $help[$topic] } else { Write-Host $help[''] }
            exit 0
        }
        'version' {
            Write-Host "AppDepot client $((Get-Module AppDepot).Version)"
            exit 0
        }
        { $_ -in 'list', 'ls' } {
            $apps = Get-DepotApp -Category $opts.category
            if ($rest.Count) { $f = $rest[0]; $apps = $apps | Where-Object { $_.Id -like "*$f*" -or $_.Name -like "*$f*" } }
            Write-Out $apps Id, Name, LatestVersion, Category, Publisher
            Write-Info ("{0} application(s)" -f @($apps).Count)
        }
        { $_ -in 'search', 'find' } {
            Assert-Arg 1 'depot search <query>'
            $apps = Find-DepotApp -Query ($rest -join ' ')
            if (-not $apps) { Write-Info 'No applications found.' Yellow; exit 0 }
            Write-Out $apps Id, Name, LatestVersion, Category, Publisher
        }
        { $_ -in 'show', 'info' } {
            Assert-Arg 1 'depot show <id>'
            $app = Get-DepotApp -Id $rest[0] -Detailed
            if ($json) { Write-Out $app; exit 0 }
            Write-Host ''
            Write-Host "$($app.Name)" -ForegroundColor Cyan -NoNewline
            Write-Host "  [$($app.Id)]"
            if ($app.Description) { Write-Host $app.Description }
            $app | Select-Object Publisher, Category, License, Homepage, LatestVersion, InstallerType, Architecture, Scope,
            @{ n = 'Size'; e = { Format-Size $_.SizeBytes } }, DownloadedAt, Schedule, NextCheck,
            LastCheckedAt, LastCheckStatus | Format-List | Out-String | Write-Host
            $latest = $app.VersionDetails | Where-Object IsLatest | Select-Object -First 1
            if ($latest) {
                Write-Host 'Install command   ' -NoNewline -ForegroundColor DarkGray; Write-Host $latest.InstallCommand
                Write-Host 'Uninstall command ' -NoNewline -ForegroundColor DarkGray; Write-Host $latest.UninstallCommand
                Write-Host 'Repository path   ' -NoNewline -ForegroundColor DarkGray; Write-Host $latest.UncPath
                Write-Host 'Intune package    ' -NoNewline -ForegroundColor DarkGray; Write-Host "$($latest.IntunePackage) ($($latest.IntuneStatus))"
                Write-Host ''
            }
            Write-Out $app.VersionDetails Version, IsLatest, InstallerType, @{ n = 'Size'; e = { Format-Size $_.SizeBytes } }, DownloadedAt, IntuneStatus
        }
        'versions' {
            Assert-Arg 1 'depot versions <id>'
            Write-Out (Get-DepotAppVersion -Id $rest[0] -IncludePurged:([bool]$opts.all)) Version, Status, IsLatest, InstallerType, @{ n = 'Size'; e = { Format-Size $_.SizeBytes } }, DownloadedAt, IntuneStatus, FileName
        }
        'installed' {
            $inst = Get-DepotInstalledApp
            if (-not $inst) { Write-Info 'No repository applications are installed on this computer.'; exit 0 }
            Write-Out $inst Id, Name, InstalledVersion, LatestVersion, UpdateAvailable, Scope
        }
        { $_ -in 'upgrade', 'update' } {
            if (-not $rest.Count -and -not $opts.all) {
                $updates = Get-DepotUpdate
                if (-not $updates) { Write-Info 'All repository applications are up to date.' Green; exit 0 }
                Write-Out $updates Id, Name, InstalledVersion, LatestVersion
                Write-Info ("{0} update(s) available. Run 'depot upgrade --all' to install them." -f @($updates).Count) Yellow
                exit 0
            }
            $results = if ($opts.all) { Update-DepotApp -All -Confirm:$false -KeepInstaller:([bool]$opts.keep) }
            else { Update-DepotApp -Id $rest -Confirm:$false -KeepInstaller:([bool]$opts.keep) }
            if (-not $results) { Write-Info 'Nothing to update.' Green; exit 0 }
            Exit-WithResults $results
        }
        'install' {
            Assert-Arg 1 'depot install <id> [--version V] [--force]'
            $version = if ($opts.version) { $opts.version } else { 'latest' }
            $results = foreach ($id in $rest) {
                Write-Info "Installing $id ($version)..." Cyan
                Install-DepotApp -Id $id -Version $version -Force:([bool]$opts.force) -KeepInstaller:([bool]$opts.keep) -Confirm:$false -ErrorAction Continue
            }
            Exit-WithResults $results
        }
        { $_ -in 'uninstall', 'remove' } {
            Assert-Arg 1 'depot uninstall <id> [--yes]'
            $results = foreach ($id in $rest) {
                if (-not $opts.yes -and -not $json) {
                    $answer = Read-Host "Uninstall $id? [y/N]"
                    if ($answer -notmatch '^(y|yes)$') { continue }
                }
                Uninstall-DepotApp -Id $id -Confirm:$false -ErrorAction Continue
            }
            Exit-WithResults $results
        }
        { $_ -in 'download', 'save' } {
            Assert-Arg 1 'depot download <id> [--dest DIR] [--version V] [--intune]'
            $params = @{ Id = $rest[0]; IncludeIntunePackage = [bool]$opts.intune }
            if ($opts.version) { $params.Version = $opts.version }
            $params.Destination = if ($opts.dest) { $opts.dest } else { (Get-Location).Path }
            if ($opts.method) { $params.TransferMethod = $opts.method }
            $files = Save-DepotInstaller @params
            Write-Out $files FullName, Length
        }
        'status' {
            if ($rest.Count) { Write-Out (Get-DepotServerStatus -Id $rest[0]) ; exit 0 }
            $s = Get-DepotServerStatus
            if ($json) { Write-Out $s; exit 0 }
            $s | Format-List | Out-String | Write-Host
            if ($s.Failed) { Write-Host "Failed checks: $($s.Failed -join ', ')  (see: depot events --errors)" -ForegroundColor Red }
        }
        'events' {
            $params = @{ Last = $(if ($opts.last) { [int]$opts.last } else { 30 }) }
            if ($opts.app) { $params.Id = $opts.app } elseif ($rest.Count) { $params.Id = $rest[0] }
            if ($opts.errors) { $params.Level = 'error' }
            Write-Out (Get-DepotEvent @params) Time, Level, Event, Id, Message
        }
        'server' {
            Assert-Arg 1 'depot server check|schedule ...'
            $sub = $rest[0].ToLowerInvariant()
            $subArgs = @($rest | Select-Object -Skip 1)
            if ($sub -eq 'check') {
                if ($opts.wait -and $subArgs.Count -eq 1) {
                    Write-Info "Checking $($subArgs[0]) for updates (this can take a while)..." Cyan
                    $r = Invoke-DepotServerCheck -Id $subArgs[0] -Force:([bool]$opts.force) -Wait -Confirm:$false
                    Write-Out $r app_id, status, version, message
                    if ($r.status -eq 'failed') { exit 1 }
                }
                else {
                    $r = if ($subArgs.Count) { Invoke-DepotServerCheck -Id $subArgs -Force:([bool]$opts.force) -Confirm:$false }
                    else { Invoke-DepotServerCheck -Force:([bool]$opts.force) -Confirm:$false }
                    Write-Info ("Queued update check for: {0}" -f ($r.queued -join ', ')) Green
                    Write-Info "Follow progress with 'depot events'."
                }
            }
            elseif ($sub -eq 'schedule') {
                if ($subArgs.Count -lt 2) { Write-Host 'Usage: depot server schedule global|<id> "<cron>|manual|global"' -ForegroundColor Yellow; exit 2 }
                if ($subArgs[0] -eq 'global') { $r = Set-DepotSchedule -Global -Schedule $subArgs[1] -Confirm:$false; Write-Info "Global schedule: $($r.global)" Green }
                else { $r = Set-DepotSchedule -Id $subArgs[0] -Schedule $subArgs[1] -Confirm:$false; Write-Info "$($r.id): schedule $($r.schedule), next check $($r.next_check)" Green }
            }
            else { Write-Host $help['server']; exit 2 }
        }
        'config' {
            if ($rest.Count -ge 3 -and $rest[0] -eq 'set') {
                $name = $rest[1]; $value = $rest[2]
                $valid = 'ServerUrl', 'TransferMethod', 'CachePath', 'LogPath', 'TimeoutSec', 'InstallTimeoutMinutes', 'KeepInstallers', 'ApiKey'
                $match = $valid | Where-Object { $_ -eq $name } | Select-Object -First 1
                if (-not $match) { Write-Host "Unknown setting '$name'. Valid: $($valid -join ', ')" -ForegroundColor Yellow; exit 2 }
                $typed = switch ($match) {
                    'KeepInstallers' { $value -in 'true', '1', 'yes', '$true' }
                    { $_ -in 'TimeoutSec', 'InstallTimeoutMinutes' } { [int]$value }
                    default { $value }
                }
                $p = @{ $match = $typed }
                Set-DepotConfig @p -Confirm:$false | Out-Null
                Write-Info "$match updated." Green
            }
            elseif ($rest.Count -and $rest[0] -eq 'reset') { Set-DepotConfig -Reset -Confirm:$false | Out-Null; Write-Info 'Configuration reset to defaults.' Green }
            else { Write-Out (Get-DepotConfig) }
        }
        'test' {
            $r = Test-DepotConnection
            Write-Out $r
            if (-not $r.Reachable) { exit 1 }
        }
        'gui' { Show-DepotGui }
        default {
            Write-Host "Unknown command '$command'. Run 'depot help'." -ForegroundColor Yellow
            exit 2
        }
    }
    exit 0
}
catch {
    if ($json) { ConvertTo-Json -InputObject @{ error = $_.Exception.Message } }
    else { Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red }
    exit 1
}
