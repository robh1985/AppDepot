function Save-DepotInstaller {
    <#
    .SYNOPSIS
        Copies an installer (and optionally its Intune package) from the repository.

    .DESCRIPTION
        Fetches the installer of an application version from the repository, using the SMB share
        (UNC path) or HTTP depending on the TransferMethod setting, and verifies its SHA-256 hash.
        Install-DepotApp uses this internally; you can also use it to stage installers or to collect
        the .intunewin package and deployment notes for Intune.

    .PARAMETER Id
        Application id.

    .PARAMETER Version
        Version to fetch (default: latest).

    .PARAMETER Destination
        Target folder. Defaults to the client cache (<CachePath>\<Id>\<Version>).

    .PARAMETER IncludeIntunePackage
        Also copy the .intunewin package, the deployment sheet (.intune.txt) and the detection script.

    .PARAMETER TransferMethod
        Override the configured transfer method (Auto, Unc or Http).

    .EXAMPLE
        Save-DepotInstaller 7zip.7zip -Destination C:\Temp\7zip

    .EXAMPLE
        Save-DepotInstaller Google.Chrome -IncludeIntunePackage -Destination \\fileserver\intune\chrome

    .OUTPUTS
        System.IO.FileInfo
    #>
    [CmdletBinding()]
    [OutputType([System.IO.FileInfo])]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipelineByPropertyName)] [string] $Id,
        [Parameter(Position = 1)] [string] $Version = 'latest',
        [string] $Destination,
        [switch] $IncludeIntunePackage,
        [ValidateSet('Auto', 'Unc', 'Http')] [string] $TransferMethod
    )
    process {
        $config = Read-DepotConfig
        $info = Invoke-DepotApi -Path ("apps/{0}/versions/{1}" -f [uri]::EscapeDataString($Id), [uri]::EscapeDataString($Version))
        if (-not $Destination) { $Destination = Join-Path (Join-Path $config.CachePath $info.app_id) $info.version }
        if (-not (Test-Path -LiteralPath $Destination)) { New-Item -ItemType Directory -Path $Destination -Force | Out-Null }
        $method = if ($TransferMethod) { $TransferMethod } else { $config.TransferMethod }

        $items = @(@{ Unc = $info.location.unc; Http = $info.location.http; Name = $info.filename; Sha = $info.sha256 })
        if ($IncludeIntunePackage) {
            foreach ($part in 'package', 'info', 'detection_script') {
                $loc = $info.intune.$part
                if ($loc -and $loc.http) {
                    $items += @{ Unc = $loc.unc; Http = $loc.http; Name = [uri]::UnescapeDataString(($loc.http -split '/')[-1]); Sha = $null }
                }
            }
        }

        foreach ($item in $items) {
            $target = Join-Path $Destination $item.Name
            if ($item.Sha -and (Test-Path -LiteralPath $target) -and
                ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -eq $item.Sha)) {
                Write-Verbose "Using cached $target"
                Get-Item -LiteralPath $target
                continue
            }
            $copied = $false
            if ($method -ne 'Http' -and $item.Unc -and (Test-DepotWindows)) {
                if (Test-Path -LiteralPath $item.Unc -ErrorAction SilentlyContinue) {
                    Write-DepotLog "Copying $($item.Unc)"
                    Copy-Item -LiteralPath $item.Unc -Destination $target -Force
                    $copied = $true
                }
                elseif ($method -eq 'Unc') {
                    throw "Repository share path $($item.Unc) is not reachable from this computer."
                }
                else {
                    Write-Verbose "UNC path not reachable, falling back to HTTP: $($item.Unc)"
                }
            }
            if (-not $copied) {
                if ($method -eq 'Unc') { throw "No UNC path is configured on the server for $($item.Name)." }
                Write-DepotLog "Downloading $($item.Http)"
                $params = @{ Uri = $item.Http; OutFile = $target; ErrorAction = 'Stop' }
                if ($PSVersionTable.PSVersion.Major -lt 6) { $params.UseBasicParsing = $true }
                $old = $ProgressPreference
                $ProgressPreference = 'SilentlyContinue'   # progress bar slows downloads 10x on 5.1
                try { Invoke-WebRequest @params } finally { $ProgressPreference = $old }
            }
            if ($item.Sha) {
                $hash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
                if ($hash -ne $item.Sha.ToUpperInvariant()) {
                    Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
                    throw "SHA-256 mismatch for $($item.Name): expected $($item.Sha), got $hash. The file was deleted."
                }
            }
            Get-Item -LiteralPath $target
        }
    }
}

function Install-DepotApp {
    <#
    .SYNOPSIS
        Installs an application from the AppDepot repository.

    .DESCRIPTION
        Fetches the installer from the repository (SMB share or HTTP), verifies its SHA-256 hash and
        runs the silent install command stored in the database. Exit codes 0, 1707, 3010 and 1641
        (plus any extra success codes defined for the application) are treated as success; 3010 and
        1641 set RebootRequired. Exit code 1618 (another installation in progress) is retried.

        If the same or a newer version is already installed the application is skipped unless
        -Force is used. Machine-wide installers require an elevated session.

        Every action is logged to <LogPath>\AppDepot.log; MSI installs also write a verbose MSI log.

    .PARAMETER Id
        Application id. Accepts pipeline input from Get-DepotApp / Find-DepotApp.

    .PARAMETER Version
        Version to install (default: latest). Must be one of the versions kept in the repository.

    .PARAMETER Force
        Install even if the same or a newer version is already installed.

    .PARAMETER KeepInstaller
        Keep the installer in the cache after a successful installation.

    .PARAMETER RetryCount
        Number of retries when another installation is in progress (exit code 1618). Default 3.

    .EXAMPLE
        Install-DepotApp 7zip.7zip

    .EXAMPLE
        Install-DepotApp Mozilla.Firefox -Version 131.0.2

        Installs a specific (older) version that is still kept in the repository.

    .EXAMPLE
        Find-DepotApp browser | Install-DepotApp -WhatIf

        Shows what would be installed without doing it.

    .EXAMPLE
        'Google.Chrome', '7zip.7zip', 'Notepad++.Notepad++' | Install-DepotApp

    .OUTPUTS
        AppDepot.Result

    .LINK
        Update-DepotApp
    .LINK
        Uninstall-DepotApp
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType('AppDepot.Result')]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)] [string] $Id,
        [Parameter(Position = 1, ValueFromPipelineByPropertyName)] [Alias('LatestVersion')] [string] $Version = 'latest',
        [switch] $Force,
        [switch] $KeepInstaller,
        [ValidateRange(0, 10)] [int] $RetryCount = 3
    )
    process {
        $config = Read-DepotConfig
        if (-not $Version) { $Version = 'latest' }
        try {
            $info = Invoke-DepotApi -Path ("apps/{0}/versions/{1}" -f [uri]::EscapeDataString($Id), [uri]::EscapeDataString($Version))
            $app = Invoke-DepotApi -Path ("apps/{0}" -f [uri]::EscapeDataString($Id))
        }
        catch {
            Write-Error -Message $_.Exception.Message -Category ObjectNotFound -TargetObject $Id
            return
        }

        if (-not (Test-DepotWindows)) {
            Write-Error 'Installing applications is only supported on Windows.'
            return
        }

        $installed = Find-DepotInstalledEntry -Detection $app.detection -Entries @(Get-DepotUninstallEntry)
        if ($installed -and -not $Force -and $installed.DisplayVersion -and
            (Compare-DepotVersion $installed.DisplayVersion $info.version) -ge 0) {
            $msg = "$($app.name) $($installed.DisplayVersion) is already installed (repository: $($info.version)). Use -Force to reinstall."
            Write-Verbose $msg
            return New-DepotResult -Id $app.id -Name $app.name -Version $info.version -Action 'Install' -Status 'Skipped' -Message $msg
        }

        if (-not $PSCmdlet.ShouldProcess("$($app.name) $($info.version)", 'Install')) { return }

        if ($info.scope -ne 'user' -and -not (Test-DepotElevated)) {
            Write-Warning "$($app.name) installs for all users and normally requires an elevated (Run as administrator) session."
        }

        Write-DepotLog "Installing $($app.id) $($info.version)"
        Write-Progress -Activity "Installing $($app.name) $($info.version)" -Status 'Fetching installer from repository' -PercentComplete 10
        try {
            $file = Save-DepotInstaller -Id $app.id -Version $info.version | Select-Object -First 1
        }
        catch {
            Write-Progress -Activity "Installing $($app.name)" -Completed
            Write-DepotLog "Download failed for $($app.id): $($_.Exception.Message)" -Level ERROR
            Write-Error "Could not fetch the installer for $($app.name): $($_.Exception.Message)"
            return New-DepotResult -Id $app.id -Name $app.name -Version $info.version -Action 'Install' -Status 'Failed' -Message $_.Exception.Message
        }

        # Resolve the command against the cached file
        $exe = $info.install.executable
        $arguments = [string]$info.install.arguments
        if ($exe -eq $info.filename) { $exe = $file.FullName }
        $arguments = $arguments.Replace('"' + $info.filename + '"', '"' + $file.FullName + '"').Replace("'" + $info.filename + "'", "'" + $file.FullName + "'")
        if ($info.installer_type -in 'msi', 'wix') {
            if (-not (Test-Path -LiteralPath $config.LogPath)) { New-Item -ItemType Directory -Path $config.LogPath -Force | Out-Null }
            $msiLog = Join-Path $config.LogPath ('{0}_{1}_{2:yyyyMMddHHmmss}.msi.log' -f $app.id, $info.version, (Get-Date))
            $arguments += " /l*v `"$msiLog`""
        }

        Write-Progress -Activity "Installing $($app.name) $($info.version)" -Status 'Running installer' -PercentComplete 50
        $attempt = 0
        do {
            $code = Invoke-DepotProcess -FilePath $exe -Arguments $arguments -WorkingDirectory $file.DirectoryName -TimeoutMinutes $config.InstallTimeoutMinutes
            if ($code -eq 1618 -and $attempt -lt $RetryCount) {
                Write-Verbose 'Another installation is in progress; retrying in 30 seconds.'
                Start-Sleep -Seconds 30
            }
            $attempt++
        } while ($code -eq 1618 -and $attempt -le $RetryCount)
        Write-Progress -Activity "Installing $($app.name)" -Completed

        $successCodes = @($info.success_exit_codes)
        $rebootCodes = @($info.reboot_exit_codes)
        $ok = $successCodes -contains $code
        $reboot = $rebootCodes -contains $code
        $meaning = Get-DepotExitCodeMeaning $code
        if ($ok) {
            Write-DepotLog "Installed $($app.id) $($info.version) (exit code $code)"
            if (-not ($KeepInstaller -or $config.KeepInstallers)) {
                Remove-Item -LiteralPath $file.DirectoryName -Recurse -Force -ErrorAction SilentlyContinue
            }
            if ($reboot) { Write-Warning "$($app.name) requires a restart to complete installation." }
            New-DepotResult -Id $app.id -Name $app.name -Version $info.version -Action 'Install' -Status 'Success' -ExitCode $code -RebootRequired $reboot -Message $meaning
        }
        else {
            Write-DepotLog "Install of $($app.id) $($info.version) failed: exit code $code ($meaning)" -Level ERROR
            Write-Error "Installation of $($app.name) $($info.version) failed with exit code $code ($meaning)."
            New-DepotResult -Id $app.id -Name $app.name -Version $info.version -Action 'Install' -Status 'Failed' -ExitCode $code -Message $meaning
        }
    }
}

function Update-DepotApp {
    <#
    .SYNOPSIS
        Updates installed applications to the latest version in the repository.

    .DESCRIPTION
        Compares installed versions with the repository and installs newer versions. Applications
        whose upgrade behaviour is 'uninstall_previous' are removed before the new version is
        installed; all others are upgraded in place.

    .PARAMETER Id
        Application(s) to update. Accepts pipeline input from Get-DepotUpdate.

    .PARAMETER All
        Update every installed catalog application that has an update.

    .EXAMPLE
        Update-DepotApp -All

    .EXAMPLE
        Update-DepotApp Google.Chrome

    .EXAMPLE
        Get-DepotUpdate | Where-Object Id -like 'Mozilla.*' | Update-DepotApp

    .EXAMPLE
        Update-DepotApp -All -WhatIf

    .OUTPUTS
        AppDepot.Result
    #>
    [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'ById')]
    [OutputType('AppDepot.Result')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'ById', Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [string[]] $Id,
        [Parameter(Mandatory, ParameterSetName = 'All')] [switch] $All,
        [switch] $KeepInstaller
    )
    begin {
        $updates = @(Get-DepotUpdate)
        $requested = New-Object System.Collections.Generic.List[string]
    }
    process {
        if ($PSCmdlet.ParameterSetName -eq 'ById') { foreach ($i in $Id) { $requested.Add($i) } }
    }
    end {
        if ($All) { $targets = $updates }
        else {
            $targets = foreach ($i in $requested) {
                $u = $updates | Where-Object { $_.Id -eq $i }
                if ($u) { $u }
                else {
                    $state = Get-DepotInstalledApp -Id $i
                    if (-not $state) { Write-Warning "$i is not installed. Use Install-DepotApp to install it." }
                    else { Write-Verbose "$i is up to date ($($state.InstalledVersion))." }
                }
            }
        }
        if (-not $targets) {
            Write-Verbose 'No updates available.'
            return
        }
        foreach ($t in $targets) {
            if (-not $PSCmdlet.ShouldProcess("$($t.Name) $($t.InstalledVersion) -> $($t.LatestVersion)", 'Update')) { continue }
            Write-DepotLog "Updating $($t.Id) $($t.InstalledVersion) -> $($t.LatestVersion)"
            if ($t.UpgradeBehavior -eq 'uninstall_previous') {
                $removed = Uninstall-DepotApp -Id $t.Id -Confirm:$false
                if ($removed.Status -ne 'Success') {
                    $removed
                    continue
                }
            }
            $result = Install-DepotApp -Id $t.Id -Version $t.LatestVersion -Force -KeepInstaller:$KeepInstaller -Confirm:$false
            if ($result) { $result.Action = 'Update' }
            $result
        }
    }
}

function Uninstall-DepotApp {
    <#
    .SYNOPSIS
        Silently uninstalls an application that was installed from the repository.

    .DESCRIPTION
        Finds the application's Programs and Features entry using its detection rule and removes it:
          1. MSI products are removed with msiexec /x {ProductCode} /qn
          2. otherwise an uninstall command defined for the application on the server is used
          3. otherwise the entry's QuietUninstallString is used
          4. otherwise its UninstallString with the silent switches for the installer technology

    .PARAMETER Id
        Application id.

    .EXAMPLE
        Uninstall-DepotApp VideoLAN.VLC

    .EXAMPLE
        Get-DepotInstalledApp -Id 'Mozilla.*' | Uninstall-DepotApp -WhatIf

    .OUTPUTS
        AppDepot.Result
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType('AppDepot.Result')]
    param([Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)] [string] $Id)
    process {
        if (-not (Test-DepotWindows)) { Write-Error 'Uninstalling applications is only supported on Windows.'; return }
        $config = Read-DepotConfig
        try { $app = Invoke-DepotApi -Path ("apps/{0}" -f [uri]::EscapeDataString($Id)) }
        catch { Write-Error -Message $_.Exception.Message -TargetObject $Id; return }

        $entry = Find-DepotInstalledEntry -Detection $app.detection -Entries @(Get-DepotUninstallEntry)
        if (-not $entry) {
            return New-DepotResult -Id $app.id -Name $app.name -Action 'Uninstall' -Status 'NotInstalled' -Message "$($app.name) is not installed."
        }
        $latest = @($app.version_details) | Where-Object { $_.is_latest } | Select-Object -First 1

        if ($entry.WindowsInstaller -and $entry.KeyName -match '^\{[0-9A-Fa-f-]{36}\}$') {
            $exe = 'msiexec.exe'; $arguments = "/x $($entry.KeyName) /qn /norestart"
        }
        elseif ($latest -and $latest.uninstall.executable -and $latest.uninstall.executable -ne 'powershell.exe') {
            $exe = [Environment]::ExpandEnvironmentVariables($latest.uninstall.executable); $arguments = [string]$latest.uninstall.arguments
        }
        elseif ($entry.QuietUninstallString) {
            $parts = Split-DepotCommandLine $entry.QuietUninstallString
            $exe = $parts.FilePath; $arguments = $parts.Arguments
        }
        elseif ($entry.UninstallString) {
            $parts = Split-DepotCommandLine $entry.UninstallString
            $exe = $parts.FilePath
            $arguments = ($parts.Arguments + ' ' + (Get-DepotSilentUninstallArgs $app.installer_type)).Trim()
            if ($exe -match 'msiexec') { $arguments = ($arguments -replace '/I', '/X') + ' /qn /norestart' }
        }
        else {
            Write-Error "No uninstall command is available for $($app.name)."
            return
        }

        if (-not $PSCmdlet.ShouldProcess("$($app.name) $($entry.DisplayVersion)", 'Uninstall')) { return }
        Write-DepotLog "Uninstalling $($app.id) $($entry.DisplayVersion)"
        $code = Invoke-DepotProcess -FilePath $exe -Arguments $arguments -TimeoutMinutes $config.InstallTimeoutMinutes
        $meaning = Get-DepotExitCodeMeaning $code
        $ok = @(0, 1605, 1614, 1641, 3010) -contains $code
        $status = if ($ok) { 'Success' } else { 'Failed' }
        Write-DepotLog "Uninstall of $($app.id) finished with exit code $code ($meaning)" -Level $(if ($ok) { 'INFO' } else { 'ERROR' })
        if (-not $ok) { Write-Error "Uninstall of $($app.name) failed with exit code $code ($meaning)." }
        New-DepotResult -Id $app.id -Name $app.name -Version $entry.DisplayVersion -Action 'Uninstall' -Status $status -ExitCode $code -RebootRequired (@(1641, 3010) -contains $code) -Message $meaning
    }
}
