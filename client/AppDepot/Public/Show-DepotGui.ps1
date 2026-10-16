function Show-DepotGui {
    <#
    .SYNOPSIS
        Opens the AppDepot graphical client.

    .DESCRIPTION
        A WPF application for browsing the repository and managing applications on this computer:

          Catalog    every application in the repository, with details, versions and install button
          Installed  catalog applications installed on this computer
          Updates    installed applications with a newer version available, with "Update all"
          Add apps   search winget and add applications to the repository (needs the API key)
          Activity   the server's event log and the operations performed in this session
          Settings   server URL, transfer method, cache options and API key

        All server calls and installations run in the background so the window stays responsive.
        Run it elevated (as administrator) to install machine-wide applications; the window offers
        to restart itself elevated when needed.

    .EXAMPLE
        Show-DepotGui

    .EXAMPLE
        depot gui

        The same, from the command-line client.
    #>
    [CmdletBinding()]
    param()
    if (-not (Test-DepotWindows)) { throw 'The AppDepot GUI requires Windows.' }

    if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
        # WPF needs a single-threaded apartment: relaunch in a new STA process.
        $exe = (Get-Process -Id $PID).Path
        Start-Process -FilePath $exe -ArgumentList @('-NoProfile', '-STA', '-WindowStyle', 'Hidden', '-Command',
            "Import-Module '$script:ModuleManifest'; Show-DepotGui")
        return
    }

    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

    $xamlText = Get-Content -LiteralPath (Join-Path $script:ModuleRoot 'GUI\MainWindow.xaml') -Raw
    $window = [Windows.Markup.XamlReader]::Parse($xamlText)
    $ui = @{}
    foreach ($m in [regex]::Matches($xamlText, 'x:Name="([^"]+)"')) { $ui[$m.Groups[1].Value] = $window.FindName($m.Groups[1].Value) }

    $script:Gui = @{
        Window    = $window
        UI        = $ui
        Rows      = @()
        View      = 'Catalog'
        Jobs      = @()   # plain array: generic List enumeration fails in WPF timer callbacks
        Actions   = 0
        Selected  = $null
        Connected = $false
        AddPreview = $null
    }

    # ---------------------------------------------------------------- timer for background jobs
    $timer = New-Object Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(150)
    $timer.Add_Tick({
            try { Receive-GuiJob }
            catch { Write-GuiLog "Internal error while processing background work: $($_.Exception.Message)" }
        })
    $timer.Start()

    # ---------------------------------------------------------------- navigation
    $ui.NavCatalog.Add_Checked({ Set-GuiView 'Catalog' })
    $ui.NavInstalled.Add_Checked({ Set-GuiView 'Installed' })
    $ui.NavUpdates.Add_Checked({ Set-GuiView 'Updates' })
    $ui.NavAdd.Add_Checked({ Set-GuiView 'Add' })
    $ui.NavActivity.Add_Checked({ Set-GuiView 'Activity' })
    $ui.NavSettings.Add_Checked({ Set-GuiView 'Settings' })

    $ui.SearchText.Add_TextChanged({
            $script:Gui.UI.SearchHint.Visibility = if ($script:Gui.UI.SearchText.Text) { 'Collapsed' } else { 'Visible' }
            Update-GuiList
        })
    $ui.RefreshButton.Add_Click({ Update-GuiData })
    $ui.AppList.Add_SelectionChanged({ Show-GuiDetail $script:Gui.UI.AppList.SelectedItem })
    $ui.InstallButton.Add_Click({ Invoke-GuiInstall })
    $ui.UninstallButton.Add_Click({ Invoke-GuiUninstall })
    $ui.UpdateAllButton.Add_Click({ Invoke-GuiUpdateAll })
    $ui.DetailHomepage.Add_Click({
            $url = $script:Gui.UI.DetailHomepageText.Text
            if ($url -match '^https?://') { Start-Process $url }
        })
    $ui.SaveSettingsButton.Add_Click({ Save-GuiSettings })
    $ui.WingetSearchButton.Add_Click({ Search-GuiWinget })
    $ui.WingetQuery.Add_KeyDown({
            param($sender, $e)
            if ($e.Key -eq 'Return') { Search-GuiWinget }
        })
    $ui.WingetResults.Add_SelectionChanged({ Show-GuiAddPreview $script:Gui.UI.WingetResults.SelectedItem })
    $ui.AddButton.Add_Click({ Invoke-GuiAddApp })
    $ui.AddOpenSettings.Add_Click({ $script:Gui.UI.NavSettings.IsChecked = $true })
    $ui.TestConnectionButton.Add_Click({ Test-GuiConnection })
    $ui.OpenLogButton.Add_Click({
            $path = (Read-DepotConfig).LogPath
            if (-not (Test-Path -LiteralPath $path)) { New-Item -ItemType Directory -Path $path -Force | Out-Null }
            Start-Process explorer.exe -ArgumentList "`"$path`""
        })
    $ui.ElevateButton.Add_Click({
            $exe = (Get-Process -Id $PID).Path
            try {
                Start-Process -FilePath $exe -Verb RunAs -ArgumentList @('-NoProfile', '-STA', '-WindowStyle', 'Hidden', '-Command',
                    "Import-Module '$script:ModuleManifest'; Show-DepotGui")
                $script:Gui.Window.Close()
            }
            catch { Write-GuiLog 'Elevation was cancelled.' }
        })
    $window.Add_KeyDown({
            param($sender, $e)
            if ($e.Key -eq 'F5') { Update-GuiData }
        })
    $window.Add_Loaded({
            if (-not (Test-DepotElevated)) { $script:Gui.UI.ElevationBanner.Visibility = 'Visible' }
            Import-GuiSettings
            Update-GuiData
        })
    $window.Add_Closing({
            param($sender, $e)
            if ($script:Gui.Actions -gt 0) {
                $answer = [Windows.MessageBox]::Show('An installation is still running. Close AppDepot anyway? The installation continues in the background.',
                    'AppDepot', 'YesNo', 'Warning')
                if ($answer -ne 'Yes') { $e.Cancel = $true }
            }
        })

    Write-GuiLog "AppDepot client $script:ModuleVersion started$(if (Test-DepotElevated) { ' (administrator)' })."
    [void]$window.ShowDialog()
    $timer.Stop()
}
