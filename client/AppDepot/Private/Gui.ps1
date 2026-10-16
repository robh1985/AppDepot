# Helpers for Show-DepotGui. All functions run on the WPF dispatcher thread except the
# script blocks passed to Start-GuiJob, which run in a background runspace.

$script:GuiPalette = @('#2563EB', '#7C3AED', '#DB2777', '#DC2626', '#EA580C', '#D97706',
    '#059669', '#0891B2', '#4F46E5', '#0D9488', '#9333EA', '#65A30D')

function Write-GuiLog {
    param([string] $Message)
    $box = $script:Gui.UI.LocalLog
    $box.AppendText(('{0:HH:mm:ss}  {1}{2}' -f (Get-Date), $Message, [Environment]::NewLine))
    $box.ScrollToEnd()
}

function Set-GuiStatus {
    param([string] $Text)
    $script:Gui.UI.StatusText.Text = $Text
}

function Start-GuiJob {
    <#
        Runs $Work in a background runspace with the AppDepot module loaded, then calls
        $OnComplete (on the UI thread) with the output and error messages.
    #>
    param(
        [string] $Status,
        [scriptblock] $Work,
        [object[]] $ArgumentList = @(),
        [scriptblock] $OnComplete,
        [switch] $Action
    )
    $ps = [powershell]::Create()
    $null = $ps.AddScript({
            param($ModulePath, $WorkText, $WorkArgs)
            Import-Module $ModulePath -Force
            $ConfirmPreference = 'None'
            & ([scriptblock]::Create($WorkText)) @WorkArgs
        }).AddArgument($script:ModuleManifest).AddArgument($Work.ToString()).AddArgument($ArgumentList)
    $job = @{ PS = $ps; Handle = $ps.BeginInvoke(); OnComplete = $OnComplete; Status = $Status; Action = [bool]$Action }
    if ($Action) { $script:Gui.Actions++ }
    $script:Gui.Jobs = @($script:Gui.Jobs) + @($job)
    Update-GuiBusy
}

function Receive-GuiJob {
    # Split finished and running jobs first; OnComplete handlers may start new jobs.
    $done = @()
    $pending = @()
    foreach ($job in $script:Gui.Jobs) {
        if ($job.Handle.IsCompleted) { $done += , $job } else { $pending += , $job }
    }
    if ($done.Count -eq 0) { return }
    $script:Gui.Jobs = $pending

    foreach ($job in $done) {
        if ($job.Action) { $script:Gui.Actions-- }
        $output = @()
        $errors = @()
        try { $output = @($job.PS.EndInvoke($job.Handle)) }
        catch {
            $inner = $_.Exception
            while ($inner.InnerException) { $inner = $inner.InnerException }
            $errors += $inner.Message
        }
        $errors += @($job.PS.Streams.Error | ForEach-Object { $_.ToString() })
        $job.PS.Dispose()
        if ($job.OnComplete) {
            try { & $job.OnComplete $output $errors }
            catch {
                Write-GuiLog "Internal error: $($_.Exception.Message)"
                Set-GuiStatus "Error: $($_.Exception.Message) (see Activity)"
            }
        }
    }
    Update-GuiBusy
}

function Update-GuiBusy {
    $ui = $script:Gui.UI
    $busy = $script:Gui.Jobs.Count -gt 0
    $ui.Busy.IsIndeterminate = $busy
    $ui.Busy.Visibility = if ($busy) { 'Visible' } else { 'Hidden' }
    if ($busy) { Set-GuiStatus $script:Gui.Jobs[$script:Gui.Jobs.Count - 1].Status }
    $idle = $script:Gui.Actions -eq 0
    $ui.InstallButton.IsEnabled = $idle
    $ui.UninstallButton.IsEnabled = $idle -and $script:Gui.Selected -and $script:Gui.Selected.IsInstalled
    $ui.UpdateAllButton.IsEnabled = $idle
}

function Set-GuiConnection {
    param([bool] $Connected, [string] $Detail)
    $ui = $script:Gui.UI
    $script:Gui.Connected = $Connected
    $ui.ConnDot.Fill = if ($Connected) { '#22C55E' } else { '#EF4444' }
    $ui.ConnText.Text = if ($Connected) { 'Connected' } else { 'Offline' }
    $ui.ServerText.Text = (Read-DepotConfig).ServerUrl
    $ui.ServerText.ToolTip = $Detail
}

function Set-GuiView {
    param([string] $View)
    $ui = $script:Gui.UI
    $script:Gui.View = $View
    $titles = @{
        Catalog   = @('Catalog', 'Applications available in the repository')
        Installed = @('Installed', 'Repository applications installed on this computer')
        Updates   = @('Updates', 'Installed applications with a newer version in the repository')
        Add       = @('Add applications', 'Search winget and add applications to the repository')
        Activity  = @('Activity', 'What the repository server and this client have been doing')
        Settings  = @('Settings', 'Client configuration')
    }
    $ui.PageTitle.Text = $titles[$View][0]
    $ui.PageSubtitle.Text = $titles[$View][1]
    $isApps = $View -in 'Catalog', 'Installed', 'Updates'
    $ui.AppsView.Visibility = if ($isApps) { 'Visible' } else { 'Collapsed' }
    $ui.ActivityView.Visibility = if ($View -eq 'Activity') { 'Visible' } else { 'Collapsed' }
    $ui.AddView.Visibility = if ($View -eq 'Add') { 'Visible' } else { 'Collapsed' }
    $ui.SettingsView.Visibility = if ($View -eq 'Settings') { 'Visible' } else { 'Collapsed' }
    $ui.SearchBox.Visibility = if ($isApps) { 'Visible' } else { 'Collapsed' }
    $ui.UpdateAllButton.Visibility = if ($View -eq 'Updates' -and @($script:Gui.Rows | Where-Object UpdateAvailable).Count) { 'Visible' } else { 'Collapsed' }
    if ($isApps) { Update-GuiList }
    if ($View -eq 'Activity') { Update-GuiEvents }
    if ($View -eq 'Settings') { Import-GuiSettings }
    if ($View -eq 'Add') { Initialize-GuiAdd }
}

function Get-GuiInitials {
    param([string] $Name)
    $words = @($Name -split '[^\p{L}\p{N}]+' | Where-Object { $_ })
    if ($words.Count -ge 2) { return ($words[0].Substring(0, 1) + $words[1].Substring(0, 1)).ToUpperInvariant() }
    if ($words.Count -eq 1) { return $words[0].Substring(0, [Math]::Min(2, $words[0].Length)).ToUpperInvariant() }
    return '?'
}

function Format-GuiSize {
    param($Bytes)
    if (-not $Bytes) { return '-' }
    if ($Bytes -ge 1GB) { return '{0:N1} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N1} MB' -f ($Bytes / 1MB) }
    return '{0:N0} KB' -f ($Bytes / 1KB)
}

function New-GuiRow {
    param($App, $Installed)
    $hash = 0
    foreach ($c in $App.Id.ToCharArray()) { $hash = ($hash * 31 + [int]$c) % 100003 }
    $isInstalled = [bool]$Installed
    $update = $isInstalled -and $Installed.UpdateAvailable
    if ($update) { $status = 'Update available'; $bg = '#FEF3C7'; $fg = '#92400E' }
    elseif ($isInstalled) { $status = 'Installed'; $bg = '#D1FAE5'; $fg = '#065F46' }
    else { $status = 'Available'; $bg = '#E0E7FF'; $fg = '#3730A3' }
    $versionText = if ($update) { "$($Installed.InstalledVersion)  ->  $($App.LatestVersion)" }
    elseif ($isInstalled) { "$($Installed.InstalledVersion)" } else { "$($App.LatestVersion)" }
    [pscustomobject]@{
        Id               = $App.Id
        Name             = $App.Name
        Publisher        = $App.Publisher
        Category         = $App.Category
        Description      = $App.Description
        Homepage         = $App.Homepage
        License          = $App.License
        LatestVersion    = $App.LatestVersion
        Versions         = @($App.Versions)
        InstallerType    = $App.InstallerType
        Architecture     = $App.Architecture
        Scope            = $App.Scope
        SizeText         = Format-GuiSize $App.SizeBytes
        DownloadedText   = $(if ($App.DownloadedAt) { $App.DownloadedAt.ToString('g') } else { '-' })
        InstalledVersion = $(if ($isInstalled) { $Installed.InstalledVersion } else { $null })
        IsInstalled      = $isInstalled
        UpdateAvailable  = [bool]$update
        Initials         = Get-GuiInitials $App.Name
        Color            = $script:GuiPalette[$hash % $script:GuiPalette.Count]
        VersionText      = $versionText
        StatusText       = $status
        StatusBackground = $bg
        StatusForeground = $fg
    }
}

function Update-GuiData {
    Start-GuiJob -Status 'Loading catalog...' -Work {
        $result = @{ Apps = @(); Installed = @(); Error = $null }
        try {
            $result.Apps = @(Get-DepotApp -ErrorAction Stop)
            $result.Installed = @(Get-DepotInstalledApp -ErrorAction Stop)
        }
        catch { $result.Error = $_.Exception.Message }
        [pscustomobject]$result
    } -OnComplete {
        param($output, $errors)
        $data = $output | Select-Object -Last 1
        if (-not $data -or $data.Error) {
            $msg = if ($data) { $data.Error } else { $errors -join '; ' }
            Set-GuiConnection $false $msg
            Set-GuiStatus "Could not reach the repository server: $msg"
            Write-GuiLog "Refresh failed: $msg"
            return
        }
        Set-GuiConnection $true ''
        $installedById = @{}
        foreach ($i in $data.Installed) { $installedById[$i.Id] = $i }
        $script:Gui.Rows = @($data.Apps | ForEach-Object { New-GuiRow $_ $installedById[$_.Id] })
        $updates = @($script:Gui.Rows | Where-Object UpdateAvailable).Count
        $ui = $script:Gui.UI
        $ui.UpdateBadgeText.Text = "$updates"
        $ui.UpdateBadge.Visibility = if ($updates) { 'Visible' } else { 'Collapsed' }
        $ui.UpdateAllButton.Visibility = if ($script:Gui.View -eq 'Updates' -and $updates) { 'Visible' } else { 'Collapsed' }
        Update-GuiList
        Set-GuiStatus ('{0} applications in the repository, {1} installed, {2} update(s) available - refreshed {3:t}' -f
            $script:Gui.Rows.Count, @($script:Gui.Rows | Where-Object IsInstalled).Count, $updates, (Get-Date))
    }
}

function Update-GuiList {
    $ui = $script:Gui.UI
    $rows = $script:Gui.Rows
    switch ($script:Gui.View) {
        'Installed' { $rows = @($rows | Where-Object IsInstalled) }
        'Updates' { $rows = @($rows | Where-Object UpdateAvailable) }
    }
    $q = $ui.SearchText.Text
    if ($q) {
        $rows = @($rows | Where-Object {
                $_.Name -like "*$q*" -or $_.Id -like "*$q*" -or $_.Publisher -like "*$q*" -or $_.Category -like "*$q*"
            })
    }
    $selectedId = if ($script:Gui.Selected) { $script:Gui.Selected.Id } else { $null }
    $ui.AppList.ItemsSource = @($rows)
    $ui.EmptyState.Visibility = if ($rows.Count) { 'Collapsed' } else { 'Visible' }
    $ui.EmptyText.Text = switch ($script:Gui.View) {
        'Updates' { 'Everything is up to date' }
        'Installed' { 'No repository applications are installed on this computer' }
        default { if ($script:Gui.Connected) { 'No applications match your search' } else { 'Not connected to the repository server' } }
    }
    $match = $rows | Where-Object { $_.Id -eq $selectedId } | Select-Object -First 1
    if ($match) { $ui.AppList.SelectedItem = $match } else { Show-GuiDetail $null }
}

function Show-GuiDetail {
    param($Row)
    $ui = $script:Gui.UI
    $script:Gui.Selected = $Row
    if (-not $Row) {
        $ui.DetailsPane.Visibility = 'Collapsed'
        $ui.NoSelection.Visibility = 'Visible'
        return
    }
    $ui.DetailsPane.Visibility = 'Visible'
    $ui.NoSelection.Visibility = 'Collapsed'
    $ui.DetailBadge.Background = $Row.Color
    $ui.DetailInitials.Text = $Row.Initials
    $ui.DetailName.Text = $Row.Name
    $ui.DetailPublisher.Text = $Row.Publisher
    $ui.DetailDescription.Text = $Row.Description
    $ui.DetailLatest.Text = $Row.LatestVersion
    $ui.DetailInstalled.Text = if ($Row.IsInstalled) { $Row.InstalledVersion } else { 'Not installed' }
    $ui.DetailCategory.Text = $Row.Category
    $ui.DetailInstaller.Text = (@($Row.InstallerType, $Row.Architecture, $(if ($Row.Scope) { "$($Row.Scope) scope" })) | Where-Object { $_ }) -join ', '
    $ui.DetailSize.Text = $Row.SizeText
    $ui.DetailDownloaded.Text = $Row.DownloadedText
    $ui.DetailLicense.Text = if ($Row.License) { $Row.License } else { '-' }
    $ui.DetailId.Text = $Row.Id
    $ui.DetailHomepageText.Text = $Row.Homepage

    if ($Row.UpdateAvailable) {
        $ui.DetailStatus.Background = '#FEF3C7'; $ui.DetailStatusText.Foreground = '#92400E'
        $ui.DetailStatusText.Text = "Update available: $($Row.InstalledVersion) -> $($Row.LatestVersion)"
    }
    elseif ($Row.IsInstalled) {
        $ui.DetailStatus.Background = '#D1FAE5'; $ui.DetailStatusText.Foreground = '#065F46'
        $ui.DetailStatusText.Text = "Installed and up to date ($($Row.InstalledVersion))"
    }
    else {
        $ui.DetailStatus.Background = '#E0E7FF'; $ui.DetailStatusText.Foreground = '#3730A3'
        $ui.DetailStatusText.Text = 'Not installed on this computer'
    }

    $ui.VersionCombo.ItemsSource = @($Row.Versions)
    $ui.VersionCombo.SelectedIndex = 0
    $ui.InstallButton.Content = if ($Row.UpdateAvailable) { 'Update' } elseif ($Row.IsInstalled) { 'Reinstall' } else { 'Install' }
    $ui.ForceCheck.IsChecked = $false
    Update-GuiBusy
}

function Invoke-GuiInstall {
    $row = $script:Gui.Selected
    if (-not $row) { return }
    $version = [string]$script:Gui.UI.VersionCombo.SelectedItem
    if (-not $version) { $version = $row.LatestVersion }
    $force = [bool]$script:Gui.UI.ForceCheck.IsChecked -or ($row.IsInstalled -and -not $row.UpdateAvailable)
    $useUpdate = $row.UpdateAvailable -and $version -eq $row.LatestVersion
    $verb = if ($useUpdate) { 'Updating' } else { 'Installing' }
    Write-GuiLog "$verb $($row.Name) $version..."
    Start-GuiJob -Action -Status "$verb $($row.Name) $version..." -ArgumentList @($row.Id, $version, $force, $useUpdate) -Work {
        param($Id, $Version, $Force, $UseUpdate)
        if ($UseUpdate) { Update-DepotApp -Id $Id -Confirm:$false }
        else { Install-DepotApp -Id $Id -Version $Version -Force:$Force -Confirm:$false }
    } -OnComplete {
        param($output, $errors)
        Complete-GuiAction $output $errors
    }
}

function Invoke-GuiUninstall {
    $row = $script:Gui.Selected
    if (-not $row -or -not $row.IsInstalled) { return }
    $answer = [Windows.MessageBox]::Show("Uninstall $($row.Name) $($row.InstalledVersion) from this computer?", 'AppDepot', 'YesNo', 'Question')
    if ($answer -ne 'Yes') { return }
    Write-GuiLog "Uninstalling $($row.Name)..."
    Start-GuiJob -Action -Status "Uninstalling $($row.Name)..." -ArgumentList @($row.Id) -Work {
        param($Id)
        Uninstall-DepotApp -Id $Id -Confirm:$false
    } -OnComplete {
        param($output, $errors)
        Complete-GuiAction $output $errors
    }
}

function Invoke-GuiUpdateAll {
    $count = @($script:Gui.Rows | Where-Object UpdateAvailable).Count
    if (-not $count) { return }
    $answer = [Windows.MessageBox]::Show("Install $count update(s) now?", 'AppDepot', 'YesNo', 'Question')
    if ($answer -ne 'Yes') { return }
    Write-GuiLog "Installing $count update(s)..."
    Start-GuiJob -Action -Status "Installing $count update(s)..." -Work {
        Update-DepotApp -All -Confirm:$false
    } -OnComplete {
        param($output, $errors)
        Complete-GuiAction $output $errors
    }
}

function Complete-GuiAction {
    param($Output, $Errors)
    $reboot = $false
    foreach ($r in @($Output | Where-Object { $_.PSObject.TypeNames -contains 'AppDepot.Result' -or $_.Status })) {
        $line = "$($r.Action) $($r.Name) $($r.Version): $($r.Status)"
        if ($null -ne $r.ExitCode) { $line += " (exit code $($r.ExitCode))" }
        if ($r.Message -and $r.Status -ne 'Success') { $line += " - $($r.Message)" }
        Write-GuiLog $line
        if ($r.RebootRequired) { $reboot = $true }
    }
    foreach ($e in $Errors) { Write-GuiLog "Error: $e" }
    if ($Errors.Count) {
        [void][Windows.MessageBox]::Show(($Errors -join [Environment]::NewLine), 'AppDepot', 'OK', 'Error')
    }
    elseif ($reboot) {
        [void][Windows.MessageBox]::Show('A restart is required to finish the installation.', 'AppDepot', 'OK', 'Information')
    }
    Update-GuiData
}

function Update-GuiEvents {
    Start-GuiJob -Status 'Loading server activity...' -Work { Get-DepotEvent -Last 200 } -OnComplete {
        param($output, $errors)
        $script:Gui.UI.EventList.ItemsSource = @($output | ForEach-Object {
                [pscustomobject]@{
                    TimeText = $(if ($_.Time) { $_.Time.ToString('g') } else { '' })
                    Level    = $_.Level; Event = $_.Event; Id = $_.Id; Message = $_.Message
                }
            })
        if ($errors.Count) { Write-GuiLog "Could not load server activity: $($errors -join '; ')" }
        Set-GuiStatus 'Ready'
    }
}

function Import-GuiSettings {
    $ui = $script:Gui.UI
    $config = Read-DepotConfig
    $ui.SettingServer.Text = $config.ServerUrl
    foreach ($item in $ui.SettingTransfer.Items) { if ($item.Tag -eq $config.TransferMethod) { $ui.SettingTransfer.SelectedItem = $item } }
    $ui.SettingKeep.IsChecked = [bool]$config.KeepInstallers
    $ui.SettingApiKey.Password = ''
    $ui.SettingApiKeyState.Text = if ($config.ApiKey) { 'A key is saved' } else { 'No key saved' }
    $ui.SettingPaths.Text = "Configuration: $(Join-Path (Get-DepotDataPath) 'client.json')`nCache: $($config.CachePath)`nLogs: $($config.LogPath)"
}

function Save-GuiSettings {
    $ui = $script:Gui.UI
    try {
        $transfer = if ($ui.SettingTransfer.SelectedItem) { $ui.SettingTransfer.SelectedItem.Tag } else { 'Auto' }
        $params = @{ ServerUrl = $ui.SettingServer.Text.Trim(); TransferMethod = $transfer; KeepInstallers = [bool]$ui.SettingKeep.IsChecked }
        if ($ui.SettingApiKey.Password) { $params.ApiKey = $ui.SettingApiKey.Password }
        Set-DepotConfig @params -Confirm:$false -ErrorAction Stop | Out-Null
        Import-GuiSettings
        $ui.SettingsResult.Foreground = '#065F46'
        $ui.SettingsResult.Text = 'Settings saved.'
        Write-GuiLog 'Settings saved.'
        Update-GuiData
    }
    catch {
        $ui.SettingsResult.Foreground = '#B91C1C'
        $ui.SettingsResult.Text = "Could not save settings: $($_.Exception.Message) (saving requires administrator rights)."
    }
}

function Test-GuiConnection {
    $url = $script:Gui.UI.SettingServer.Text.Trim()
    $script:Gui.UI.SettingsResult.Text = "Testing $url..."
    Start-GuiJob -Status "Testing connection to $url..." -ArgumentList @($url) -Work {
        param($Url)
        Test-DepotConnection -ServerUrl $Url
    } -OnComplete {
        param($output, $errors)
        $r = $output | Select-Object -Last 1
        $ui = $script:Gui.UI
        if ($r -and $r.Reachable) {
            $ui.SettingsResult.Foreground = '#065F46'
            $share = if ($r.UncRoot) { if ($r.UncReachable) { "share $($r.UncRoot) reachable" } else { "share $($r.UncRoot) NOT reachable (HTTP will be used)" } } else { 'no share configured' }
            $ui.SettingsResult.Text = "Connected to AppDepot $($r.ServerVersion): $($r.Applications) applications, $share."
        }
        else {
            $ui.SettingsResult.Foreground = '#B91C1C'
            $ui.SettingsResult.Text = "Connection failed: $(if ($r) { $r.Error } else { $errors -join '; ' })"
        }
        Set-GuiStatus 'Ready'
    }
}

# ----------------------------------------------------------------------------- Add applications
$script:GuiDefaultCategories = @('Browsers', 'Communication', 'Development', 'Multimedia', 'Networking', 'Office', 'Security', 'Utilities')

function Initialize-GuiAdd {
    $ui = $script:Gui.UI
    $ui.AddKeyBanner.Visibility = if ((Read-DepotConfig).ApiKey) { 'Collapsed' } else { 'Visible' }
    $cats = @($script:GuiDefaultCategories) + @($script:Gui.Rows | ForEach-Object { $_.Category } | Where-Object { $_ })
    $ui.AddCategory.ItemsSource = @($cats | Sort-Object -Unique)
    $ui.WingetQuery.Focus() | Out-Null
}

function Search-GuiWinget {
    $ui = $script:Gui.UI
    $q = $ui.WingetQuery.Text.Trim()
    if ($q.Length -lt 2) { $ui.WingetHint.Text = 'Type at least two characters.'; return }
    $ui.WingetHint.Foreground = '#6B7280'
    $ui.WingetHint.Text = "Searching winget for '$q'..."
    Start-GuiJob -Status "Searching winget for '$q'..." -ArgumentList @($q) -Work {
        param($Query)
        Find-DepotWingetPackage -Query $Query -Limit 50
    } -OnComplete {
        param($output, $errors)
        $ui = $script:Gui.UI
        if ($errors.Count) {
            $ui.WingetHint.Foreground = '#B91C1C'
            $ui.WingetHint.Text = "Search failed: $($errors -join '; ')"
            $ui.WingetResults.ItemsSource = $null
        }
        else {
            $rows = @($output | ForEach-Object {
                    [pscustomobject]@{ Id = $_.Id; Name = $_.Name; Version = $_.Version; InRepository = $_.InRepository
                        InRepositoryText = $(if ($_.InRepository) { 'Yes' } else { '' }) }
                })
            $ui.WingetResults.ItemsSource = $rows
            $ui.WingetHint.Foreground = '#6B7280'
            $ui.WingetHint.Text = if ($rows.Count) { "$($rows.Count) result(s). Select one to see which installer would be used." } else { 'No packages found.' }
        }
        Set-GuiStatus 'Ready'
    }
}

function Show-GuiAddPreview {
    param($Row)
    $ui = $script:Gui.UI
    $script:Gui.AddPreview = $null
    if (-not $Row) { $ui.AddPane.Visibility = 'Collapsed'; $ui.AddNoSelection.Visibility = 'Visible'; return }
    $ui.AddPane.Visibility = 'Visible'
    $ui.AddNoSelection.Visibility = 'Collapsed'
    $ui.AddName.Text = $Row.Name
    $ui.AddPublisher.Text = ''
    $ui.AddDescription.Text = ''
    $ui.AddId.Text = $Row.Id
    $ui.AddVersion.Text = $Row.Version
    $ui.AddInstaller.Text = ''; $ui.AddAllInstallers.Text = ''; $ui.AddFile.Text = ''
    $ui.AddResult.Text = ''
    $ui.AddMsiBadge.Background = '#F3F4F6'; $ui.AddMsiText.Foreground = '#374151'
    $ui.AddMsiText.Text = 'Checking the installers available for this application...'
    $ui.AddButton.IsEnabled = $false
    $ui.AddButton.Content = if ($Row.InRepository) { 'Replace in repository' } else { 'Add to repository' }

    Start-GuiJob -Status "Previewing $($Row.Id)..." -ArgumentList @($Row.Id) -Work {
        param($Id)
        Test-DepotAppSource -WingetId $Id
    } -OnComplete {
        param($output, $errors)
        $ui = $script:Gui.UI
        $pv = $output | Select-Object -Last 1
        Set-GuiStatus 'Ready'
        if (-not $pv -or $pv.Id -ne $ui.AddId.Text) {
            if ($errors.Count -and $ui.AddPane.Visibility -eq 'Visible') {
                $ui.AddMsiBadge.Background = '#FEE2E2'; $ui.AddMsiText.Foreground = '#991B1B'
                $ui.AddMsiText.Text = "Preview failed: $($errors -join '; ')"
            }
            return   # a newer selection replaced this one
        }
        $script:Gui.AddPreview = $pv
        $m = $pv.Manifest
        $ui.AddName.Text = $m.name
        $ui.AddPublisher.Text = $m.publisher
        $ui.AddDescription.Text = $m.description
        $ui.AddVersion.Text = $pv.LatestVersion
        $ui.AddInstaller.Text = if ($pv.Installer) { "$($pv.Installer) from $($pv.Source)" } else { 'none found' }
        $ui.AddAllInstallers.Text = ($pv.WingetInstallers | Sort-Object -Unique) -join ', '
        $ui.AddFile.Text = $pv.FileName
        $ui.AddCategory.Text = $m.category
        if ($pv.MsiAvailable) {
            $ui.AddMsiBadge.Background = '#D1FAE5'; $ui.AddMsiText.Foreground = '#065F46'
            $ui.AddMsiText.Text = 'MSI installer available - it will be used.'
        }
        elseif ($pv.Ok) {
            $ui.AddMsiBadge.Background = '#FEF3C7'; $ui.AddMsiText.Foreground = '#92400E'
            $ui.AddMsiText.Text = "No MSI available. $($pv.Note)"
        }
        else {
            $ui.AddMsiBadge.Background = '#FEE2E2'; $ui.AddMsiText.Foreground = '#991B1B'
            $ui.AddMsiText.Text = "No usable installer found. $($pv.Errors -join '; ')"
        }
        $ui.AddButton.IsEnabled = $script:Gui.Actions -eq 0
    }
}

function Invoke-GuiAddApp {
    $ui = $script:Gui.UI
    $pv = $script:Gui.AddPreview
    if (-not $pv) { return }
    $category = $ui.AddCategory.Text.Trim()
    $check = [bool]$ui.AddCheckNow.IsChecked
    $replace = [bool]$pv.InRepository
    $ui.AddButton.IsEnabled = $false
    $ui.AddResult.Foreground = '#374151'
    $ui.AddResult.Text = "Adding $($pv.Id)..."
    Write-GuiLog "Adding $($pv.Id) to the repository$(if ($check) { ' and downloading it' })..."
    Start-GuiJob -Action -Status "Adding $($pv.Id) to the repository..." -ArgumentList @($pv.Id, $category, $check, $replace) -Work {
        param($Id, $Category, $Check, $Replace)
        $p = @{ WingetId = $Id; CheckNow = $Check; Replace = $Replace; Confirm = $false }
        if ($Category) { $p.Category = $Category }
        New-DepotApp @p
    } -OnComplete {
        param($output, $errors)
        $ui = $script:Gui.UI
        $r = $output | Select-Object -Last 1
        if ($errors.Count -or -not $r -or -not $r.InRepository) {
            $msg = if ($errors.Count) { $errors -join '; ' } else { 'The server did not add the application.' }
            $ui.AddResult.Foreground = '#B91C1C'
            $ui.AddResult.Text = "Could not add the application: $msg"
            Write-GuiLog "Add failed: $msg"
        }
        else {
            $ui.AddResult.Foreground = '#065F46'
            $ui.AddResult.Text = if ($r.CheckQueued) {
                "Added. The server is downloading $($r.Installer) $($r.LatestVersion) now; it appears in the Catalog when the download finishes (Refresh)."
            } else { 'Added. It will be downloaded at the next scheduled check.' }
            Write-GuiLog "Added $($r.Id) ($($r.Installer) $($r.LatestVersion))."
            foreach ($row in @($ui.WingetResults.ItemsSource)) {
                if ($row.Id -eq $r.Id) { $row.InRepository = $true; $row.InRepositoryText = 'Yes' }
            }
            $ui.WingetResults.Items.Refresh()
            $ui.AddButton.Content = 'Replace in repository'
            if ($r.CheckQueued) { Start-GuiRefreshLater }
        }
        $ui.AddButton.IsEnabled = $true
    }
}

function Start-GuiRefreshLater {
    # Refresh the catalog after the server has had time to download the new application.
    Start-GuiJob -Status 'Waiting for the server download...' -Work { Start-Sleep -Seconds 45 } -OnComplete {
        param($output, $errors)
        Update-GuiData
    }
}
