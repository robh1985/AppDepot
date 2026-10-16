#Requires -Version 5.1
<#
    AppDepot client module.
    See about_AppDepot (Get-Help about_AppDepot) for an overview.
#>

$script:ModuleRoot = $PSScriptRoot
$script:ModuleManifest = Join-Path $PSScriptRoot 'AppDepot.psd1'
$script:ModuleVersion = (Import-PowerShellDataFile -LiteralPath $script:ModuleManifest).ModuleVersion

foreach ($folder in 'Private', 'Public') {
    foreach ($file in Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot $folder) -Filter '*.ps1' -ErrorAction SilentlyContinue) {
        . $file.FullName
    }
}

# Tab completion of application ids for every cmdlet with an -Id parameter
$completer = {
    param($commandName, $parameterName, $wordToComplete)
    try {
        Invoke-DepotApi -Path 'apps' -ErrorAction Stop |
            Where-Object { $_.id -like "$wordToComplete*" } |
            ForEach-Object { [System.Management.Automation.CompletionResult]::new($_.id, $_.id, 'ParameterValue', "$($_.name) $($_.latest_version)") }
    }
    catch { }
}
foreach ($cmd in 'Get-DepotApp', 'Get-DepotAppVersion', 'Install-DepotApp', 'Update-DepotApp', 'Uninstall-DepotApp',
    'Save-DepotInstaller', 'Get-DepotServerStatus', 'Get-DepotEvent', 'Invoke-DepotServerCheck', 'Set-DepotSchedule',
    'Get-DepotInstalledApp', 'Get-DepotUpdate', 'Remove-DepotApp', 'Test-DepotAppSource', 'Publish-DepotInstaller') {
    Register-ArgumentCompleter -CommandName $cmd -ParameterName Id -ScriptBlock $completer
}
