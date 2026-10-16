function Get-DepotDataPath {
    <#
    .SYNOPSIS
        Returns the AppDepot client data folder (config, cache, logs).
    .DESCRIPTION
        Defaults to %ProgramData%\AppDepot. Set $env:APPDEPOT_HOME to override (useful for testing).
    #>
    [CmdletBinding()]
    param()
    if ($env:APPDEPOT_HOME) { return $env:APPDEPOT_HOME }
    if ($env:ProgramData) { return (Join-Path $env:ProgramData 'AppDepot') }
    return (Join-Path ([IO.Path]::GetTempPath()) 'AppDepot')
}

$script:DefaultConfig = [ordered]@{
    ServerUrl      = 'http://appdepot:8080'
    TransferMethod = 'Auto'      # Auto | Unc | Http
    CachePath      = $null       # default: <data path>\Cache
    LogPath        = $null       # default: <data path>\Logs
    TimeoutSec     = 60
    InstallTimeoutMinutes = 60
    KeepInstallers = $false
    ApiKey         = $null       # only needed for admin cmdlets; prefer $env:APPDEPOT_API_KEY
}

function Read-DepotConfig {
    [CmdletBinding()]
    param()
    $config = [ordered]@{}
    foreach ($key in $script:DefaultConfig.Keys) { $config[$key] = $script:DefaultConfig[$key] }

    $path = Join-Path (Get-DepotDataPath) 'client.json'
    if (Test-Path -LiteralPath $path) {
        try {
            $saved = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json
            foreach ($prop in $saved.PSObject.Properties) { $config[$prop.Name] = $prop.Value }
        }
        catch {
            Write-Warning "AppDepot: could not read $path ($($_.Exception.Message)); using defaults."
        }
    }
    # Environment variables win (handy for scripts and task sequences)
    if ($env:APPDEPOT_SERVER) { $config.ServerUrl = $env:APPDEPOT_SERVER }
    if ($env:APPDEPOT_API_KEY) { $config.ApiKey = $env:APPDEPOT_API_KEY }

    # Elevated sessions (and the SYSTEM auto-update task) use the admin-only ProgramData folders.
    # Standard users get per-user folders so they can never tamper with what SYSTEM executes.
    $data = Get-DepotDataPath
    if (-not $env:APPDEPOT_HOME -and $env:LOCALAPPDATA -and -not (Test-DepotElevated)) {
        $data = Join-Path $env:LOCALAPPDATA 'AppDepot'
    }
    if (-not $config.CachePath) { $config.CachePath = Join-Path $data 'Cache' }
    if (-not $config.LogPath) { $config.LogPath = Join-Path $data 'Logs' }
    $config.ServerUrl = ([string]$config.ServerUrl).TrimEnd('/')
    return [pscustomobject]$config
}

function Write-DepotConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Config)
    $dir = Get-DepotDataPath
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $path = Join-Path $dir 'client.json'
    $Config | ConvertTo-Json | Set-Content -LiteralPath $path -Encoding UTF8
    return $path
}
