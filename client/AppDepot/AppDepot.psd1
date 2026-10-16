@{
    RootModule           = 'AppDepot.psm1'
    ModuleVersion        = '1.4.0'
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
        'Find-DepotWingetPackage', 'Test-DepotAppSource', 'New-DepotApp', 'Publish-DepotInstaller', 'Remove-DepotApp', 'Get-DepotManifestTemplate', 'Add-DepotCatalogApp',
        'Compare-DepotVersion', 'Show-DepotGui'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
    PrivateData          = @{
        PSData = @{
            Tags         = @('Repository', 'PackageManagement', 'Intune', 'Deployment', 'Windows', 'winget')
            ReleaseNotes = '1.4.0: Add-DepotCatalogApp adds the bundled application catalog. 1.3.0: app dependencies (requires), MSIX/AppX detection (Teams), detection exclude patterns. 1.2.0: manual applications (New-DepotApp -Id/-Name, Publish-DepotInstaller), Adobe Acrobat/Reader support (MSP patches, zip installers, update_with). 1.1.0: add applications to the repository (Find-DepotWingetPackage, Test-DepotAppSource, New-DepotApp, Remove-DepotApp, Get-DepotManifestTemplate); MSI-first installer selection; GUI fixes.'
        }
    }
}
