#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
<#
    Unit tests for the AppDepot client module.
    Run from the repository root:  Invoke-Pester ./client/tests
    No server is needed: the API and all Windows-specific calls are mocked.
#>

BeforeAll {
    $env:APPDEPOT_HOME = Join-Path ([IO.Path]::GetTempPath()) ("AppDepotTests-" + [guid]::NewGuid())
    Import-Module (Join-Path $PSScriptRoot '..\AppDepot\AppDepot.psd1') -Force

    $script:VersionInfo = [pscustomobject]@{
        app_id = 'Contoso.Tool'; version = '2.1.0'; filename = 'tool-2.1.0.exe'; installer_type = 'nullsoft'
        scope = 'machine'; sha256 = 'ABC'; is_latest = $true
        location = [pscustomobject]@{ unc = '\\depot\AppDepot\Contoso.Tool\2.1.0\installer\tool-2.1.0.exe'; http = 'http://depot/files/x' }
        install = [pscustomobject]@{ executable = 'tool-2.1.0.exe'; arguments = '/S'; command = '"tool-2.1.0.exe" /S' }
        uninstall = [pscustomobject]@{ executable = $null; arguments = $null; command = $null }
        success_exit_codes = @(0, 1641, 1707, 3010); reboot_exit_codes = @(1641, 3010)
        intune = [pscustomobject]@{ status = 'ok' }
    }
    $script:AppInfo = [pscustomobject]@{
        id = 'Contoso.Tool'; name = 'Contoso Tool'; latest_version = '2.1.0'; installer_type = 'nullsoft'
        upgrade_behavior = 'install'; versions = @('2.1.0', '2.0.0')
        detection = [pscustomobject]@{ display_name = '^Contoso Tool'; publisher = $null; product_codes = @() }
        version_details = @($script:VersionInfo)
    }
}

AfterAll {
    Remove-Item -LiteralPath $env:APPDEPOT_HOME -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item Env:\APPDEPOT_HOME
}

Describe 'Compare-DepotVersion' {
    It 'agrees with the server on every shared test case' {
        $cases = Get-Content (Join-Path $PSScriptRoot '..\..\tests\version-cases.json') -Raw | ConvertFrom-Json
        $mismatches = @($cases | Where-Object { (Compare-DepotVersion $_.a $_.b) -ne $_.expected })
        $mismatches | Should -BeNullOrEmpty
    }

    It 'compares <a> to <b> as <expected>' -ForEach @(
        @{ a = '1.10'; b = '1.9'; expected = 1 }
        @{ a = '24.08'; b = '24.8.0'; expected = 0 }
        @{ a = '1.0-rc1'; b = '1.0'; expected = -1 }
        @{ a = 'v3.1'; b = '3.1'; expected = 0 }
    ) {
        Compare-DepotVersion $a $b | Should -Be $expected
    }
}

Describe 'Split-DepotCommandLine' {
    It 'splits <cmd>' -ForEach @(
        @{ cmd = '"C:\Program Files\App\uninst.exe" /S'; file = 'C:\Program Files\App\uninst.exe'; arguments = '/S' }
        @{ cmd = 'C:\App\unins000.exe /VERYSILENT'; file = 'C:\App\unins000.exe'; arguments = '/VERYSILENT' }
        @{ cmd = 'MsiExec.exe /X{1234}'; file = 'MsiExec.exe'; arguments = '/X{1234}' }
    ) {
        InModuleScope AppDepot -Parameters @{ cmd = $cmd; file = $file; arguments = $arguments } {
            param($cmd, $file, $arguments)
            $r = Split-DepotCommandLine $cmd
            $r.FilePath | Should -Be $file
            $r.Arguments | Should -Be $arguments
        }
    }
}

Describe 'Find-DepotInstalledEntry' {
    BeforeAll {
        $script:Entries = @(
            [pscustomobject]@{ DisplayName = 'Contoso Tool'; DisplayVersion = '1.0'; Publisher = 'Contoso'; KeyName = 'Contoso Tool' }
            [pscustomobject]@{ DisplayName = 'Contoso Tool (x64)'; DisplayVersion = '2.0'; Publisher = 'Contoso'; KeyName = 'Tool64' }
            [pscustomobject]@{ DisplayName = 'Contoso Agent'; DisplayVersion = '7.0'; Publisher = 'Contoso'; KeyName = '{GUID-1}' }
            [pscustomobject]@{ DisplayName = 'Fabrikam Tool'; DisplayVersion = '9.0'; Publisher = 'Fabrikam'; KeyName = 'Fab' }
        )
    }
    It 'returns the highest matching version' {
        InModuleScope AppDepot -Parameters @{ Entries = $script:Entries } {
            param($Entries)
            $d = [pscustomobject]@{ display_name = '^Contoso Tool'; publisher = $null; product_codes = @() }
            (Find-DepotInstalledEntry -Detection $d -Entries $Entries).DisplayVersion | Should -Be '2.0'
        }
    }
    It 'matches MSI product codes' {
        InModuleScope AppDepot -Parameters @{ Entries = $script:Entries } {
            param($Entries)
            $d = [pscustomobject]@{ display_name = '^No Match'; publisher = $null; product_codes = @('{GUID-1}') }
            (Find-DepotInstalledEntry -Detection $d -Entries $Entries).DisplayName | Should -Be 'Contoso Agent'
        }
    }
    It 'applies the publisher filter' {
        InModuleScope AppDepot -Parameters @{ Entries = $script:Entries } {
            param($Entries)
            $d = [pscustomobject]@{ display_name = 'Tool$'; publisher = '^Fabrikam'; product_codes = @() }
            (Find-DepotInstalledEntry -Detection $d -Entries $Entries).KeyName | Should -Be 'Fab'
        }
    }
}

Describe 'Configuration' {
    It 'saves and reads settings' {
        Set-DepotConfig -ServerUrl 'http://depot.test:8080/' -TransferMethod Http -Confirm:$false | Out-Null
        $c = Get-DepotConfig
        $c.ServerUrl | Should -Be 'http://depot.test:8080'
        $c.TransferMethod | Should -Be 'Http'
    }
    It 'masks the API key' {
        Set-DepotConfig -ApiKey 'secret' -Confirm:$false | Out-Null
        (Get-DepotConfig).ApiKey | Should -Be '********'
    }
    It 'lets APPDEPOT_SERVER override the saved server' {
        $env:APPDEPOT_SERVER = 'http://other:1'
        try { (Get-DepotConfig).ServerUrl | Should -Be 'http://other:1' } finally { Remove-Item Env:\APPDEPOT_SERVER }
    }
}

Describe 'Catalog cmdlets' {
    BeforeAll {
        Mock -ModuleName AppDepot Invoke-DepotApi {
            @(
                [pscustomobject]@{ id = 'Contoso.Tool'; name = 'Contoso Tool'; latest_version = '2.1.0'; category = 'Utilities'; versions = @('2.1.0') }
                [pscustomobject]@{ id = 'Fabrikam.App'; name = 'Fabrikam App'; latest_version = '1.0'; category = 'Office'; versions = @('1.0') }
            )
        } -ParameterFilter { $Path -eq 'apps' }
    }
    It 'converts API objects' {
        $apps = Get-DepotApp
        $apps.Count | Should -Be 2
        $apps[0].PSObject.TypeNames[0] | Should -Be 'AppDepot.App'
        $apps[0].LatestVersion | Should -Be '2.1.0'
    }
    It 'filters by id wildcard' {
        (Get-DepotApp -Id 'Fab*').Id | Should -Be 'Fabrikam.App'
    }
}

Describe 'Install-DepotApp' {
    BeforeAll {
        Mock -ModuleName AppDepot Test-DepotWindows { $true }
        Mock -ModuleName AppDepot Test-DepotElevated { $true }
        Mock -ModuleName AppDepot Invoke-DepotApi { $script:VersionInfo } -ParameterFilter { $Path -like 'apps/*/versions/*' }
        Mock -ModuleName AppDepot Invoke-DepotApi { $script:AppInfo } -ParameterFilter { $Path -eq 'apps/Contoso.Tool' }
        Mock -ModuleName AppDepot Save-DepotInstaller {
            $dir = Join-Path $env:APPDEPOT_HOME 'Cache\Contoso.Tool\2.1.0'
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $f = Join-Path $dir 'tool-2.1.0.exe'
            Set-Content -LiteralPath $f -Value 'x'
            Get-Item -LiteralPath $f
        }
    }

    It 'runs the installer from the cache and reports success' {
        Mock -ModuleName AppDepot Get-DepotUninstallEntry { }
        Mock -ModuleName AppDepot Invoke-DepotProcess { 0 }
        $r = Install-DepotApp Contoso.Tool -Confirm:$false
        $r.Status | Should -Be 'Success'
        Should -Invoke -ModuleName AppDepot Invoke-DepotProcess -Times 1 -ParameterFilter {
            $FilePath -like '*tool-2.1.0.exe' -and $Arguments -eq '/S'
        }
    }

    It 'flags a required restart for exit code 3010' {
        Mock -ModuleName AppDepot Get-DepotUninstallEntry { }
        Mock -ModuleName AppDepot Invoke-DepotProcess { 3010 }
        $r = Install-DepotApp Contoso.Tool -Confirm:$false -WarningAction SilentlyContinue
        $r.Status | Should -Be 'Success'
        $r.RebootRequired | Should -BeTrue
    }

    It 'reports failure exit codes' {
        Mock -ModuleName AppDepot Get-DepotUninstallEntry { }
        Mock -ModuleName AppDepot Invoke-DepotProcess { 1603 }
        $r = Install-DepotApp Contoso.Tool -Confirm:$false -ErrorAction SilentlyContinue
        $r.Status | Should -Be 'Failed'
        $r.ExitCode | Should -Be 1603
    }

    It 'skips when the same version is installed' {
        Mock -ModuleName AppDepot Get-DepotUninstallEntry { [pscustomobject]@{ DisplayName = 'Contoso Tool'; DisplayVersion = '2.1.0'; KeyName = 'x' } }
        Mock -ModuleName AppDepot Invoke-DepotProcess { 0 }
        (Install-DepotApp Contoso.Tool -Confirm:$false).Status | Should -Be 'Skipped'
        Should -Invoke -ModuleName AppDepot Invoke-DepotProcess -Times 0
    }

    It 'does nothing with -WhatIf' {
        Mock -ModuleName AppDepot Get-DepotUninstallEntry { }
        Mock -ModuleName AppDepot Invoke-DepotProcess { 0 }
        Install-DepotApp Contoso.Tool -WhatIf
        Should -Invoke -ModuleName AppDepot Invoke-DepotProcess -Times 0
    }
}

Describe 'Uninstall-DepotApp' {
    BeforeAll {
        Mock -ModuleName AppDepot Test-DepotWindows { $true }
        Mock -ModuleName AppDepot Invoke-DepotApi { $script:AppInfo }
        Mock -ModuleName AppDepot Invoke-DepotProcess { 0 }
    }
    It 'adds NSIS silent switches to the UninstallString' {
        Mock -ModuleName AppDepot Get-DepotUninstallEntry {
            [pscustomobject]@{ DisplayName = 'Contoso Tool'; DisplayVersion = '2.0'; KeyName = 'Contoso Tool'
                UninstallString = '"C:\Program Files\Contoso\uninst.exe"'; QuietUninstallString = ''; WindowsInstaller = $false }
        }
        (Uninstall-DepotApp Contoso.Tool -Confirm:$false).Status | Should -Be 'Success'
        Should -Invoke -ModuleName AppDepot Invoke-DepotProcess -ParameterFilter {
            $FilePath -eq 'C:\Program Files\Contoso\uninst.exe' -and $Arguments -eq '/S'
        }
    }
    It 'uses msiexec for Windows Installer products' {
        Mock -ModuleName AppDepot Get-DepotUninstallEntry {
            [pscustomobject]@{ DisplayName = 'Contoso Tool'; DisplayVersion = '2.0'; KeyName = '{0F0F0F0F-1111-2222-3333-444444444444}'
                UninstallString = 'MsiExec.exe /X{0F0F0F0F-1111-2222-3333-444444444444}'; QuietUninstallString = ''; WindowsInstaller = $true }
        }
        Uninstall-DepotApp Contoso.Tool -Confirm:$false | Out-Null
        Should -Invoke -ModuleName AppDepot Invoke-DepotProcess -ParameterFilter {
            $FilePath -eq 'msiexec.exe' -and $Arguments -eq '/x {0F0F0F0F-1111-2222-3333-444444444444} /qn /norestart'
        }
    }
    It 'reports NotInstalled when nothing matches' {
        Mock -ModuleName AppDepot Get-DepotUninstallEntry { }
        (Uninstall-DepotApp Contoso.Tool -Confirm:$false).Status | Should -Be 'NotInstalled'
    }
}

Describe 'Module quality' {
    It 'has comment-based help with examples for every exported command' {
        foreach ($cmd in Get-Command -Module AppDepot) {
            $help = Get-Help $cmd.Name -Full
            $help.Synopsis | Should -Not -BeNullOrEmpty -Because "$($cmd.Name) needs a synopsis"
            @($help.Examples.Example).Count | Should -BeGreaterThan 0 -Because "$($cmd.Name) needs examples"
        }
    }
}

Describe 'Adding applications' {
    BeforeAll {
        $env:APPDEPOT_API_KEY = 'test-key'
        $script:Generated = [pscustomobject]@{
            manifest = [pscustomobject]@{ id = 'Contoso.Viewer'; name = 'Contoso PDF Viewer'; category = 'Office' }
            info = [pscustomobject]@{ installer_types = @('wix', 'nullsoft') }
            in_repository = $false
            preview = [pscustomobject]@{
                id = 'Contoso.Viewer'; ok = $true; latest_version = '3.2.1'; msi_available = $true
                note = 'Selected MSI from winget (source 1 of 1)'; errors = @()
                selected = [pscustomobject]@{ type = 'wix'; source = 'winget'; source_index = 1; filename = 'viewer.msi' }
                candidates = @([pscustomobject]@{ version = '3.2.1'; type = 'wix'; source = 'winget'; source_index = 1; filename = 'viewer.msi' })
            }
        }
    }
    AfterAll { Remove-Item Env:\APPDEPOT_API_KEY }

    It 'previews a winget package' {
        Mock -ModuleName AppDepot Invoke-DepotApi { $script:Generated } -ParameterFilter { $Path -eq 'winget/packages/Contoso.Viewer' }
        $pv = Test-DepotAppSource -WingetId Contoso.Viewer
        $pv.Installer | Should -Be 'wix'
        $pv.MsiAvailable | Should -BeTrue
        $pv.Category | Should -Be 'Office'
    }

    It 'adds the generated manifest and passes -CheckNow' {
        Mock -ModuleName AppDepot Invoke-DepotApi { $script:Generated } -ParameterFilter { $Path -eq 'winget/packages/Contoso.Viewer' }
        Mock -ModuleName AppDepot Invoke-DepotApi { [pscustomobject]@{ id = 'Contoso.Viewer'; manifest_path = 'C:\m\Contoso.Viewer.yaml'; check_queued = $true } } -ParameterFilter { $Path -eq 'apps' }
        $r = New-DepotApp -WingetId Contoso.Viewer -CheckNow -Confirm:$false
        $r.InRepository | Should -BeTrue
        $r.CheckQueued | Should -BeTrue
        Should -Invoke -ModuleName AppDepot Invoke-DepotApi -ParameterFilter { $Path -eq 'apps' -and $Method -eq 'POST' -and $Query.check -eq $true }
    }

    It 'does not add anything with -WhatIf' {
        Mock -ModuleName AppDepot Invoke-DepotApi { $script:Generated } -ParameterFilter { $Path -eq 'winget/packages/Contoso.Viewer' }
        Mock -ModuleName AppDepot Invoke-DepotApi { throw 'should not be called' } -ParameterFilter { $Path -eq 'apps' }
        { New-DepotApp -WingetId Contoso.Viewer -WhatIf } | Should -Not -Throw
        Should -Invoke -ModuleName AppDepot Invoke-DepotApi -Times 0 -ParameterFilter { $Path -eq 'apps' }
    }

    It 'refuses to overwrite an existing application without -Replace' {
        $existing = $script:Generated.PSObject.Copy(); $existing.in_repository = $true
        Mock -ModuleName AppDepot Invoke-DepotApi { $existing } -ParameterFilter { $Path -like 'winget/packages/*' }
        Mock -ModuleName AppDepot Invoke-DepotApi { } -ParameterFilter { $Path -eq 'apps' }
        New-DepotApp -WingetId Contoso.Viewer -Confirm:$false -WarningAction SilentlyContinue | Out-Null
        Should -Invoke -ModuleName AppDepot Invoke-DepotApi -Times 0 -ParameterFilter { $Path -eq 'apps' }
    }

    It 'removes an application and its files' {
        Mock -ModuleName AppDepot Invoke-DepotApi { [pscustomobject]@{ deleted = 'Contoso.Old' } }
        Remove-DepotApp Contoso.Old -DeleteFiles -Confirm:$false | Out-Null
        Should -Invoke -ModuleName AppDepot Invoke-DepotApi -ParameterFilter { $Method -eq 'DELETE' -and $Query.delete_files -eq $true }
    }
}

Describe 'File encoding' {
    It 'keeps client files ASCII-only so Windows PowerShell 5.1 (ANSI default) reads them correctly' {
        $root = Join-Path $PSScriptRoot '..'
        $bad = Get-ChildItem $root -Recurse -Include *.ps1, *.psm1, *.psd1, *.xaml, *.ps1xml |
            Where-Object { [IO.File]::ReadAllBytes($_.FullName) | Where-Object { $_ -gt 127 } | Select-Object -First 1 }
        $bad.Name | Should -BeNullOrEmpty
    }
}
