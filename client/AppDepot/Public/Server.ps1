function Get-DepotServerStatus {
    <#
    .SYNOPSIS
        Shows the status of the AppDepot server: version, schedules and per-application check results.

    .DESCRIPTION
        Combines the health, schedule and catalog endpoints into one overview. Use -Id to see the
        status of one application, including its last error and next scheduled check.

    .PARAMETER Id
        Show details for one application.

    .EXAMPLE
        Get-DepotServerStatus

    .EXAMPLE
        Get-DepotServerStatus -Id Google.Chrome | Format-List
    #>
    [CmdletBinding()]
    param([Parameter(Position = 0)] [string] $Id)
    if ($Id) {
        $app = Invoke-DepotApi -Path ("apps/{0}" -f [uri]::EscapeDataString($Id))
        return [pscustomobject]@{
            PSTypeName      = 'AppDepot.AppStatus'
            Id              = $app.id
            Name            = $app.name
            LatestVersion   = $app.latest_version
            Versions        = ($app.versions -join ', ')
            Source          = $app.source.type
            Schedule        = $app.schedule
            NextCheck       = ConvertTo-DepotDate $app.next_check
            LastChecked     = ConvertTo-DepotDate $app.last_checked_at
            LastUpdated     = ConvertTo-DepotDate $app.last_updated_at
            LastCheckStatus = $app.last_check_status
            LastError       = $app.last_error
        }
    }
    $health = Invoke-DepotApi -Path 'health'
    $schedule = Invoke-DepotApi -Path 'schedule'
    $apps = @(Invoke-DepotApi -Path 'apps' -Query @{ include_empty = 'true' })
    $globalJob = $schedule.jobs | Where-Object { $_.id -eq 'global' }
    [pscustomobject]@{
        PSTypeName      = 'AppDepot.ServerStatus'
        ServerUrl       = (Read-DepotConfig).ServerUrl
        Version         = $health.version
        Applications    = $health.applications
        UncRoot         = $health.unc_root
        GlobalSchedule  = $schedule.global
        NextGlobalCheck = ConvertTo-DepotDate $globalJob.next_run
        CustomSchedules = @($schedule.jobs | Where-Object { $_.id -like 'app:*' }).Count
        RunningChecks   = ($health.running_checks -join ', ')
        Failed          = @($apps | Where-Object { $_.last_check_status -eq 'failed' } | ForEach-Object { $_.id })
    }
}

function Get-DepotEvent {
    <#
    .SYNOPSIS
        Reads the server event log (downloads, updates, purges, schedule changes, errors).

    .PARAMETER Id
        Only events for this application.

    .PARAMETER Level
        Only events of this level (info, error).

    .PARAMETER Last
        Number of events to return (default 50, newest first).

    .EXAMPLE
        Get-DepotEvent -Level error

    .EXAMPLE
        Get-DepotEvent -Id Mozilla.Firefox -Last 10
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)] [string] $Id,
        [ValidateSet('info', 'error')] [string] $Level,
        [ValidateRange(1, 1000)] [int] $Last = 50
    )
    Invoke-DepotApi -Path 'events' -Query @{ app_id = $Id; level = $Level; limit = $Last } | ForEach-Object {
        [pscustomobject]@{
            PSTypeName = 'AppDepot.Event'
            Time       = ConvertTo-DepotDate $_.timestamp
            Level      = $_.level
            Event      = $_.event
            Id         = $_.app_id
            Version    = $_.version
            Message    = $_.message
        }
    }
}

function Invoke-DepotServerCheck {
    <#
    .SYNOPSIS
        Asks the server to check the internet for new versions now. (Administrative)

    .DESCRIPTION
        Triggers an immediate update check outside the normal schedule. Without -Wait the check is
        queued and runs in the background on the server; with -Wait (single application only) the
        command returns the result. Requires the server API key (Set-DepotConfig -ApiKey).

    .PARAMETER Id
        Application(s) to check. Omit to check every enabled application.

    .PARAMETER Force
        Download again even if the version is already in the repository.

    .PARAMETER Wait
        Wait for the result (single application).

    .EXAMPLE
        Invoke-DepotServerCheck -Id Google.Chrome -Wait

        app_id        status   version        message
        ------        ------   -------        -------
        Google.Chrome updated  130.0.6723.92  Downloaded version 130.0.6723.92

    .EXAMPLE
        Invoke-DepotServerCheck
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Position = 0, ValueFromPipelineByPropertyName)] [string[]] $Id,
        [switch] $Force,
        [switch] $Wait
    )
    process {
        if ($Id -and $Id.Count -eq 1 -and $Wait) {
            if ($PSCmdlet.ShouldProcess($Id[0], 'Check for updates')) {
                Invoke-DepotApi -Path ("apps/{0}/check" -f [uri]::EscapeDataString($Id[0])) -Method POST -Admin `
                    -Query @{ force = $(if ($Force) { 'true' } else { 'false' }); wait = 'true' }
            }
            return
        }
        $target = if ($Id) { $Id -join ', ' } else { 'all applications' }
        if ($PSCmdlet.ShouldProcess($target, 'Queue update check')) {
            $body = @{ force = [bool]$Force }
            if ($Id) { $body.app_ids = @($Id) }
            Invoke-DepotApi -Path 'check' -Method POST -Body $body -Admin
        }
    }
}

function Set-DepotSchedule {
    <#
    .SYNOPSIS
        Changes the global or a per-application update schedule on the server. (Administrative)

    .DESCRIPTION
        Schedules use 5-field cron syntax: minute hour day-of-month month day-of-week.
          '0 3 * * *'      every day at 03:00
          '0 */6 * * *'    every 6 hours
          '30 2 * * 1-5'   02:30 Monday to Friday
          '0 4 * * sun'    04:00 on Sundays
        For an application, 'manual' disables automatic checks and 'global' (or an empty value)
        returns it to the global schedule. Requires the server API key.

    .PARAMETER Global
        Change the global schedule.

    .PARAMETER Id
        Change the schedule of this application.

    .PARAMETER Schedule
        Cron expression, 'manual' or 'global'.

    .EXAMPLE
        Set-DepotSchedule -Global -Schedule '0 2 * * *'

    .EXAMPLE
        Set-DepotSchedule -Id Google.Chrome -Schedule '0 */4 * * *'

    .EXAMPLE
        Set-DepotSchedule -Id Contoso.LegacyApp -Schedule manual
    #>
    [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'App')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Global')] [switch] $Global,
        [Parameter(Mandatory, ParameterSetName = 'App', Position = 0)] [string] $Id,
        [Parameter(Mandatory, Position = 1)] [AllowEmptyString()] [string] $Schedule
    )
    if ($Global) {
        if ($PSCmdlet.ShouldProcess('global schedule', "Set to '$Schedule'")) {
            Invoke-DepotApi -Path 'schedule' -Method PUT -Body @{ schedule = $Schedule } -Admin
        }
    }
    else {
        $value = if ($Schedule -in '', 'global') { $null } else { $Schedule }
        if ($PSCmdlet.ShouldProcess($Id, "Set schedule to '$Schedule'")) {
            Invoke-DepotApi -Path ("apps/{0}/schedule" -f [uri]::EscapeDataString($Id)) -Method PUT -Body @{ schedule = $value } -Admin
        }
    }
}
