function Get-DepotConfig {
    <#
    .SYNOPSIS
        Shows the AppDepot client configuration.

    .DESCRIPTION
        Returns the effective client configuration: values saved with Set-DepotConfig, overridden by
        the APPDEPOT_SERVER and APPDEPOT_API_KEY environment variables, with defaults for the rest.
        The configuration file is %ProgramData%\AppDepot\client.json.

        The API key is masked in the output.

    .EXAMPLE
        Get-DepotConfig

        ServerUrl      : http://appdepot.corp.example.com:8080
        TransferMethod : Auto
        CachePath      : C:\ProgramData\AppDepot\Cache
        ...

    .OUTPUTS
        AppDepot.Config

    .LINK
        Set-DepotConfig
    #>
    [CmdletBinding()]
    [OutputType('AppDepot.Config')]
    param()
    $config = Read-DepotConfig
    $out = [ordered]@{ PSTypeName = 'AppDepot.Config' }
    foreach ($p in $config.PSObject.Properties) { $out[$p.Name] = $p.Value }
    if ($out.ApiKey) { $out.ApiKey = '********' }
    $out.ConfigFile = Join-Path (Get-DepotDataPath) 'client.json'
    [pscustomobject]$out
}

function Set-DepotConfig {
    <#
    .SYNOPSIS
        Changes the AppDepot client configuration.

    .DESCRIPTION
        Saves settings to %ProgramData%\AppDepot\client.json (administrator rights are needed on
        most systems). Only the parameters you specify are changed.

    .PARAMETER ServerUrl
        URL of the AppDepot server, e.g. http://appdepot.corp.example.com:8080

    .PARAMETER TransferMethod
        How installers are fetched from the repository:
          Auto - use the SMB share (UNC path) when reachable, otherwise HTTP (default)
          Unc  - always copy from the SMB share
          Http - always download over HTTP

    .PARAMETER CachePath
        Folder where installers are staged before installation.

    .PARAMETER LogPath
        Folder for the client log (AppDepot.log) and MSI verbose logs.

    .PARAMETER TimeoutSec
        Timeout for API requests.

    .PARAMETER InstallTimeoutMinutes
        Maximum time an installer may run before it is terminated.

    .PARAMETER KeepInstallers
        Keep installers in the cache after a successful installation.

    .PARAMETER ApiKey
        Server API key, required only for the administrative cmdlets (Invoke-DepotServerCheck,
        Set-DepotSchedule). It is stored in plain text in client.json; on shared machines prefer the
        APPDEPOT_API_KEY environment variable.

    .PARAMETER Reset
        Restore all defaults before applying the other parameters.

    .EXAMPLE
        Set-DepotConfig -ServerUrl http://appdepot.corp.example.com:8080

    .EXAMPLE
        Set-DepotConfig -TransferMethod Http -KeepInstallers $true

    .LINK
        Get-DepotConfig
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [ValidatePattern('^https?://')] [string] $ServerUrl,
        [ValidateSet('Auto', 'Unc', 'Http')] [string] $TransferMethod,
        [string] $CachePath,
        [string] $LogPath,
        [ValidateRange(5, 3600)] [int] $TimeoutSec,
        [ValidateRange(1, 1440)] [int] $InstallTimeoutMinutes,
        [bool] $KeepInstallers,
        [string] $ApiKey,
        [switch] $Reset
    )
    $path = Join-Path (Get-DepotDataPath) 'client.json'
    $saved = [ordered]@{}
    if (-not $Reset -and (Test-Path -LiteralPath $path)) {
        $json = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        foreach ($p in $json.PSObject.Properties) { $saved[$p.Name] = $p.Value }
    }
    foreach ($name in 'ServerUrl', 'TransferMethod', 'CachePath', 'LogPath', 'TimeoutSec',
        'InstallTimeoutMinutes', 'KeepInstallers', 'ApiKey') {
        if ($PSBoundParameters.ContainsKey($name)) {
            $value = $PSBoundParameters[$name]
            if ($name -eq 'ServerUrl') { $value = $value.TrimEnd('/') }
            $saved[$name] = $value
        }
    }
    if ($PSCmdlet.ShouldProcess($path, 'Save AppDepot client configuration')) {
        Write-DepotConfig -Config ([pscustomobject]$saved) | Out-Null
        Get-DepotConfig
    }
}

function Test-DepotConnection {
    <#
    .SYNOPSIS
        Tests the connection to the AppDepot server and the repository share.

    .DESCRIPTION
        Calls the server health endpoint and checks whether the repository UNC share is reachable
        from this computer. Returns an object describing the result; use -Quiet to get $true/$false.

    .PARAMETER ServerUrl
        Test a different server than the configured one.

    .PARAMETER Quiet
        Return only $true (server reachable) or $false.

    .EXAMPLE
        Test-DepotConnection

        ServerUrl     : http://appdepot:8080
        Reachable     : True
        ServerVersion : 1.0.0
        Applications  : 8
        UncRoot       : \\appdepot\AppDepot
        UncReachable  : True

    .EXAMPLE
        if (Test-DepotConnection -Quiet) { Update-DepotApp -All }
    #>
    [CmdletBinding()]
    param([string] $ServerUrl, [switch] $Quiet)
    $config = Read-DepotConfig
    $url = if ($ServerUrl) { $ServerUrl.TrimEnd('/') } else { $config.ServerUrl }
    $result = [ordered]@{
        PSTypeName = 'AppDepot.Connection'; ServerUrl = $url; Reachable = $false; ServerVersion = $null
        Applications = $null; UncRoot = $null; UncReachable = $false; Error = $null
    }
    try {
        $health = Invoke-DepotApi -Path 'health' -ServerUrl $url
        $result.Reachable = $true
        $result.ServerVersion = $health.version
        $result.Applications = $health.applications
        $result.UncRoot = $health.unc_root
        if ($health.unc_root -and (Test-DepotWindows)) {
            $result.UncReachable = Test-Path -LiteralPath $health.unc_root -ErrorAction SilentlyContinue
        }
    }
    catch {
        $result.Error = $_.Exception.Message
    }
    if ($Quiet) { return $result.Reachable }
    [pscustomobject]$result
}
