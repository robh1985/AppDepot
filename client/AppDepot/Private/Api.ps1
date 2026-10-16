function Invoke-DepotApi {
    <#
    .SYNOPSIS
        Calls the AppDepot REST API and returns the parsed JSON.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [ValidateSet('GET', 'POST', 'PUT', 'DELETE')] [string] $Method = 'GET',
        $Body,
        [string] $RawBody,
        [string] $InFile,
        [string] $ContentType = 'application/json; charset=utf-8',
        [hashtable] $Query,
        [switch] $Admin,
        [string] $ServerUrl
    )
    $config = Read-DepotConfig
    $base = if ($ServerUrl) { $ServerUrl.TrimEnd('/') } else { $config.ServerUrl }
    $uri = '{0}/api/v1/{1}' -f $base, $Path.TrimStart('/')
    if ($Query -and $Query.Count) {
        $pairs = foreach ($k in $Query.Keys) {
            $v = $Query[$k]
            if ($v -is [bool] -or $v -is [switch]) { $v = ([bool]$v).ToString().ToLowerInvariant() }
            if ($null -ne $v -and "$v" -ne '') {
                '{0}={1}' -f [uri]::EscapeDataString($k), [uri]::EscapeDataString([string]$v)
            }
        }
        if ($pairs) { $uri += '?' + ($pairs -join '&') }
    }

    $params = @{
        Uri         = $uri
        Method      = $Method
        TimeoutSec  = [int]$config.TimeoutSec
        ErrorAction = 'Stop'
        Headers     = @{ 'User-Agent' = "AppDepotClient/$script:ModuleVersion" }
    }
    if ($PSVersionTable.PSVersion.Major -lt 6) { $params.UseBasicParsing = $true }
    if ($Admin) {
        if (-not $config.ApiKey) {
            throw 'This operation requires the server API key. Run Set-DepotConfig -ApiKey <key> or set $env:APPDEPOT_API_KEY.'
        }
        $params.Headers['X-Api-Key'] = [string]$config.ApiKey
    }
    if ($PSBoundParameters.ContainsKey('Body')) {
        $params.Body = ConvertTo-Json -InputObject $Body -Depth 10 -Compress
        $params.ContentType = 'application/json; charset=utf-8'
    }
    elseif ($InFile) {
        $params.InFile = $InFile           # streamed from disk, fine for large installers
        $params.ContentType = 'application/octet-stream'
        $params.TimeoutSec = 3600
    }
    elseif ($PSBoundParameters.ContainsKey('RawBody')) {
        $params.Body = [Text.Encoding]::UTF8.GetBytes($RawBody)
        $params.ContentType = $ContentType
    }

    Write-Verbose "AppDepot API: $Method $uri"
    try {
        # Assign first: Windows PowerShell 5.1 emits a JSON array as one object; returning the
        # variable enumerates it consistently on every PowerShell version.
        $response = Invoke-RestMethod @params
        return $response
    }
    catch {
        $detail = $null
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
            try { $detail = ($_.ErrorDetails.Message | ConvertFrom-Json).detail } catch { $detail = $_.ErrorDetails.Message }
        }
        $status = $null
        if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
        if ($status -eq 404) {
            throw [System.Management.Automation.ItemNotFoundException]::new($(if ($detail) { $detail } else { "Not found: $Path" }))
        }
        $msg = "AppDepot server request failed ($Method $uri)"
        if ($status) { $msg += " - HTTP $status" }
        if ($detail) { $msg += ": $detail" } else { $msg += ": $($_.Exception.Message)" }
        throw $msg
    }
}

function Add-DepotTypeName {
    param([Parameter(ValueFromPipeline)] $InputObject, [string] $TypeName)
    process {
        if ($null -ne $InputObject) {
            $InputObject.PSObject.TypeNames.Insert(0, $TypeName)
            $InputObject
        }
    }
}

function ConvertTo-DepotDate {
    param([string] $Value)
    if ([string]::IsNullOrEmpty($Value)) { return $null }
    try { return [datetime]::Parse($Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal).ToLocalTime() }
    catch { return $null }
}

function ConvertTo-DepotApp {
    param([Parameter(ValueFromPipeline)] $App)
    process {
        [pscustomobject]@{
            PSTypeName      = 'AppDepot.App'
            Id              = $App.id
            Name            = $App.name
            Publisher       = $App.publisher
            LatestVersion   = $App.latest_version
            Versions        = @($App.versions)
            Category        = $App.category
            Description     = $App.description
            Homepage        = $App.homepage
            License         = $App.license
            Tags            = @($App.tags)
            InstallerType   = $App.installer_type
            Architecture    = $App.architecture
            Scope           = $App.scope
            SizeBytes       = $App.size_bytes
            DownloadedAt    = ConvertTo-DepotDate $App.downloaded_at
            LastCheckedAt   = ConvertTo-DepotDate $App.last_checked_at
            LastCheckStatus = $App.last_check_status
            Schedule        = $App.schedule
            UpgradeBehavior = $App.upgrade_behavior
            UpdateWith      = $App.update_with
            IsPatch         = [bool]$App.is_patch
            Manual          = [bool]$App.manual
            Detection       = $App.detection
        }
    }
}

function ConvertTo-DepotVersion {
    param([Parameter(ValueFromPipeline)] $Version)
    process {
        [pscustomobject]@{
            PSTypeName       = 'AppDepot.AppVersion'
            Id               = $Version.app_id
            Version          = $Version.version
            IsLatest         = [bool]$Version.is_latest
            Status           = $Version.status
            FileName         = $Version.filename
            SetupPath        = $Version.setup_path
            InstallerType    = $Version.installer_type
            Architecture     = $Version.architecture
            Scope            = $Version.scope
            SizeBytes        = $Version.size_bytes
            Sha256           = $Version.sha256
            DownloadedAt     = ConvertTo-DepotDate $Version.downloaded_at
            UncPath          = $Version.location.unc
            HttpUrl          = $Version.location.http
            InstallCommand   = $Version.install.command
            UninstallCommand = $Version.uninstall.command
            ProductCode      = $Version.product_code
            IntuneStatus     = $Version.intune.status
            IntunePackage    = $Version.intune.package.unc
            IntuneInfo       = $Version.intune.info.unc
            SourceUrl        = $Version.source_url
            Raw              = $Version
        }
    }
}
