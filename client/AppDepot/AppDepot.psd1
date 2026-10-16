@{
    RootModule           = 'AppDepot.psm1'
    ModuleVersion        = '1.0.0'
    GUID                 = '6f1d0a52-2c55-4c34-9a71-3d4c1f6a8e21'
    Author               = 'AppDepot'
    CompanyName          = 'AppDepot'
    Copyright            = '(c) AppDepot. All rights reserved.'
    Description          = 'Client for the AppDepot self-hosted application repository: browse, install, update and uninstall applications from your local repository, with a GUI (Show-DepotGui) and the depot command-line tool.'
    PowerShellVersion    = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')
    FormatsToProcess     = @('AppDepot.Format.ps1xml')
    FunctionsToExport    = @(
        'Get-DepotConfig', 'Set-DepotConfig', 'Test-DepotConnection',
        'Get-DepotApp', 'Find-DepotApp', 'Get-DepotAppVersion',
        'Get-DepotInstalledApp', 'Get-DepotUpdate',
        'Save-DepotInstaller', 'Install-DepotApp', 'Update-DepotApp', 'Uninstall-DepotApp',
        'Get-DepotServerStatus', 'Get-DepotEvent', 'Invoke-DepotServerCheck', 'Set-DepotSchedule',
        'Compare-DepotVersion', 'Show-DepotGui'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
    PrivateData          = @{
        PSData = @{
            Tags         = @('Repository', 'PackageManagement', 'Intune', 'Deployment', 'Windows', 'winget')
            ReleaseNotes = 'Initial release.'
        }
    }
}
