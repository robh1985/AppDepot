function Get-DepotApp {
    <#
    .SYNOPSIS
        Lists the applications available in the AppDepot repository.

    .DESCRIPTION
        Returns the catalog of applications that have at least one version stored in the repository.
        Filter by id/name wildcards or category. With -Id and an exact id, -Detailed adds the
        source definition, next scheduled check and every stored version.

    .PARAMETER Id
        Application id, e.g. 7zip.7zip. Wildcards are supported.

    .PARAMETER Name
        Display-name filter. Wildcards are supported.

    .PARAMETER Category
        Only return applications in this category (e.g. Browsers, Utilities).

    .PARAMETER Detailed
        Include detailed information (versions, source, next check). Slower: one request per app.

    .EXAMPLE
        Get-DepotApp

        Id                          Name                Latest      Category
        --                          ----                ------      --------
        7zip.7zip                   7-Zip               24.08       Utilities
        Google.Chrome               Google Chrome       130.0.6723  Browsers

    .EXAMPLE
        Get-DepotApp -Name *chrome*

    .EXAMPLE
        Get-DepotApp -Category Browsers | Install-DepotApp

        Installs every application in the Browsers category.

    .OUTPUTS
        AppDepot.App

    .LINK
        Find-DepotApp
    .LINK
        Get-DepotAppVersion
    #>
    [CmdletBinding()]
    [OutputType('AppDepot.App')]
    param(
        [Parameter(Position = 0, ValueFromPipelineByPropertyName)] [SupportsWildcards()] [string] $Id,
        [SupportsWildcards()] [string] $Name,
        [string] $Category,
        [switch] $Detailed
    )
    process {
        if ($Id -and -not [WildcardPattern]::ContainsWildcardCharacters($Id) -and $Detailed) {
            $raw = Invoke-DepotApi -Path ("apps/{0}" -f [uri]::EscapeDataString($Id))
            $app = $raw | ConvertTo-DepotApp
            $app | Add-Member -NotePropertyName Source -NotePropertyValue $raw.source
            $app | Add-Member -NotePropertyName NextCheck -NotePropertyValue (ConvertTo-DepotDate $raw.next_check)
            $app | Add-Member -NotePropertyName VersionDetails -NotePropertyValue @($raw.version_details | ConvertTo-DepotVersion)
            $app | Add-Member -NotePropertyName LastError -NotePropertyValue $raw.last_error
            return $app
        }
        $apps = Invoke-DepotApi -Path 'apps' -Query @{ category = $Category } | ConvertTo-DepotApp
        if ($Id) { $apps = $apps | Where-Object { $_.Id -like $Id } }
        if ($Name) { $apps = $apps | Where-Object { $_.Name -like $Name } }
        if ($Detailed) {
            $apps | ForEach-Object { Get-DepotApp -Id $_.Id -Detailed }
        }
        else {
            $apps
        }
    }
}

function Find-DepotApp {
    <#
    .SYNOPSIS
        Searches the AppDepot catalog.

    .DESCRIPTION
        Performs a server-side search of application ids, names, publishers and descriptions.

    .PARAMETER Query
        Text to search for, e.g. 'browser' or 'adobe'.

    .EXAMPLE
        Find-DepotApp editor

        Id                          Name                Latest   Category
        --                          ----                ------   --------
        Microsoft.VisualStudioCode  Visual Studio Code  1.94.2   Development
        Notepad++.Notepad++         Notepad++           8.7      Development

    .OUTPUTS
        AppDepot.App
    #>
    [CmdletBinding()]
    [OutputType('AppDepot.App')]
    param([Parameter(Mandatory, Position = 0)] [string] $Query)
    Invoke-DepotApi -Path 'apps' -Query @{ search = $Query } | ConvertTo-DepotApp
}

function Get-DepotAppVersion {
    <#
    .SYNOPSIS
        Lists the versions of an application stored in the repository.

    .DESCRIPTION
        The repository keeps the most recent versions of each application (3 by default). Each
        version object includes the file locations (UNC and HTTP), SHA-256, silent install and
        uninstall commands and the Intune package location.

    .PARAMETER Id
        Application id.

    .PARAMETER Version
        A specific version, or 'latest'.

    .PARAMETER IncludePurged
        Also list versions that were removed by the retention policy (history only).

    .EXAMPLE
        Get-DepotAppVersion 7zip.7zip

        Version  Latest  Type      Size (MB)  Downloaded         Intune
        -------  ------  ----      ---------  ----------         ------
        24.08    True    exe            1.6   16/10/2026 03:00   ok
        24.07    False   exe            1.6   20/06/2026 03:00   ok

    .EXAMPLE
        (Get-DepotAppVersion Google.Chrome -Version latest).InstallCommand

    .EXAMPLE
        Get-DepotAppVersion Mozilla.Firefox latest | Select-Object IntunePackage, IntuneInfo

        Shows where the .intunewin file and the Intune deployment sheet are stored.

    .OUTPUTS
        AppDepot.AppVersion
    #>
    [CmdletBinding()]
    [OutputType('AppDepot.AppVersion')]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipelineByPropertyName)] [string] $Id,
        [Parameter(Position = 1)] [string] $Version,
        [switch] $IncludePurged
    )
    process {
        $escaped = [uri]::EscapeDataString($Id)
        if ($Version) {
            Invoke-DepotApi -Path ("apps/{0}/versions/{1}" -f $escaped, [uri]::EscapeDataString($Version)) | ConvertTo-DepotVersion
        }
        else {
            Invoke-DepotApi -Path ("apps/{0}/versions" -f $escaped) -Query @{ include_purged = $(if ($IncludePurged) { 'true' } else { $null }) } |
                ForEach-Object { $_ } | ConvertTo-DepotVersion
        }
    }
}

function Get-DepotInstalledApp {
    <#
    .SYNOPSIS
        Lists catalog applications that are installed on this computer.

    .DESCRIPTION
        Reads Programs and Features (machine and current-user uninstall registry keys) and matches
        entries to catalog applications using each application's detection rule (MSI product codes
        or a display-name regular expression). Returns installed and latest versions and whether
        an update is available.

    .PARAMETER Id
        Only return this application (wildcards supported).

    .EXAMPLE
        Get-DepotInstalledApp

        Id                  Name       Installed  Latest  Update
        --                  ----       ---------  ------  ------
        7zip.7zip           7-Zip      24.07      24.08   True
        Notepad++.Notepad++ Notepad++  8.7        8.7     False

    .OUTPUTS
        AppDepot.InstalledApp

    .LINK
        Get-DepotUpdate
    #>
    [CmdletBinding()]
    [OutputType('AppDepot.InstalledApp')]
    param([Parameter(Position = 0)] [SupportsWildcards()] [string] $Id)
    if (-not (Test-DepotWindows)) {
        Write-Warning 'Installed-application detection is only available on Windows.'
        return
    }
    $catalog = Invoke-DepotApi -Path 'apps'
    if ($Id) { $catalog = $catalog | Where-Object { $_.id -like $Id } }
    $entries = @(Get-DepotUninstallEntry)
    foreach ($app in $catalog) {
        $entry = Find-DepotInstalledEntry -Detection $app.detection -Entries $entries
        if (-not $entry) { continue }
        $update = $false
        if ($app.latest_version -and $entry.DisplayVersion) {
            $update = (Compare-DepotVersion $app.latest_version $entry.DisplayVersion) -gt 0
        }
        [pscustomobject]@{
            PSTypeName       = 'AppDepot.InstalledApp'
            Id               = $app.id
            Name             = $app.name
            InstalledVersion = $entry.DisplayVersion
            LatestVersion    = $app.latest_version
            UpdateAvailable  = $update
            DisplayName      = $entry.DisplayName
            Publisher        = $entry.Publisher
            Scope            = $entry.Scope
            ProductCode      = $(if ($entry.WindowsInstaller) { $entry.KeyName } else { $null })
            UninstallString  = $entry.UninstallString
            UpgradeBehavior  = $app.upgrade_behavior
            InstallerType    = $app.installer_type
        }
    }
}

function Get-DepotUpdate {
    <#
    .SYNOPSIS
        Lists installed applications that have a newer version in the repository.

    .DESCRIPTION
        Equivalent to Get-DepotInstalledApp | Where-Object UpdateAvailable.

    .PARAMETER Id
        Only check this application (wildcards supported).

    .EXAMPLE
        Get-DepotUpdate

    .EXAMPLE
        Get-DepotUpdate | Update-DepotApp

        Installs all available updates.

    .OUTPUTS
        AppDepot.InstalledApp
    #>
    [CmdletBinding()]
    [OutputType('AppDepot.InstalledApp')]
    param([Parameter(Position = 0)] [SupportsWildcards()] [string] $Id)
    Get-DepotInstalledApp -Id $Id | Where-Object { $_.UpdateAvailable }
}
