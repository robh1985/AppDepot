function ConvertTo-DepotPreview {
    param($Preview, $Manifest, $Info, [bool] $InRepository)
    $sel = $Preview.selected
    [pscustomobject]@{
        PSTypeName      = 'AppDepot.SourcePreview'
        Id              = $Preview.id
        Name            = $(if ($Manifest) { $Manifest.name } else { $null })
        LatestVersion   = $Preview.latest_version
        Installer       = $(if ($sel) { $sel.type } else { $null })
        MsiAvailable    = [bool]$Preview.msi_available
        Source          = $(if ($sel) { "$($sel.source) (#$($sel.source_index))" } else { $null })
        FileName        = $(if ($sel) { $sel.filename } else { $null })
        Note            = $Preview.note
        Ok              = [bool]$Preview.ok
        InRepository    = $InRepository
        Candidates      = @($Preview.candidates | ForEach-Object {
                [pscustomobject]@{ Version = $_.version; Type = $_.type; Source = "$($_.source) (#$($_.source_index))"; FileName = $_.filename; Url = $_.url }
            })
        Errors          = @($Preview.errors)
        Category        = $(if ($Manifest) { $Manifest.category } else { $null })
        Manifest        = $Manifest
        WingetInstallers = $(if ($Info) { @($Info.installer_types) } else { @() })
    }
}

function Find-DepotWingetPackage {
    <#
    .SYNOPSIS
        Searches the winget catalog for applications to add to the repository. (Administrative)

    .DESCRIPTION
        Searches winget package ids, names and monikers through the AppDepot server. Each result
        shows whether the application is already in the repository. Add a result with
        New-DepotApp -WingetId <Id>. Requires the server API key.

    .PARAMETER Query
        Text to search for, e.g. 'chrome' or 'Adobe Acrobat'.

    .PARAMETER Limit
        Maximum number of results (default 25).

    .EXAMPLE
        Find-DepotWingetPackage chrome

        Id                   Name                 Version         InRepository
        --                   ----                 -------         ------------
        Google.Chrome        Google Chrome        130.0.6723.92   True
        Google.Chrome.Beta   Google Chrome Beta   131.0.6778.24   False

    .EXAMPLE
        Find-DepotWingetPackage 'remote desktop' | Where-Object -Not InRepository

    .OUTPUTS
        AppDepot.WingetPackage

    .LINK
        New-DepotApp
    #>
    [CmdletBinding()]
    [OutputType('AppDepot.WingetPackage')]
    param(
        [Parameter(Mandatory, Position = 0)] [string] $Query,
        [ValidateRange(1, 100)] [int] $Limit = 25
    )
    Invoke-DepotApi -Path 'winget/search' -Query @{ q = $Query; limit = $Limit } -Admin | ForEach-Object {
        [pscustomobject]@{
            PSTypeName   = 'AppDepot.WingetPackage'
            Id           = $_.id
            Name         = $_.name
            Version      = $_.version
            InRepository = [bool]$_.in_repository
        }
    }
}

function Test-DepotAppSource {
    <#
    .SYNOPSIS
        Previews what the server would download for an application, without saving anything.

    .DESCRIPTION
        Asks the server to query every source of an application and report the newest version,
        every installer candidate, whether an MSI is available and which installer would be
        selected (MSI is preferred over all other types). Nothing is saved or downloaded.

        Use it before New-DepotApp, to check a manifest you are writing, or to see why an
        existing application uses a particular installer. Requires the server API key.

    .PARAMETER WingetId
        A winget package id; the manifest is generated from winget's metadata.

    .PARAMETER Path
        A manifest YAML file.

    .PARAMETER Manifest
        A manifest as a hashtable (same keys as the YAML file).

    .PARAMETER Id
        An application already in the repository.

    .PARAMETER Category
        Category to use for a generated winget manifest.

    .PARAMETER Architecture
        Architecture for a generated winget manifest (default x64).

    .EXAMPLE
        Test-DepotAppSource -WingetId Notepad++.Notepad++

        Id            : Notepad++.Notepad++
        LatestVersion : 8.7.1
        Installer     : nullsoft
        MsiAvailable  : False
        Note          : No MSI available for version 8.7.1 from 1 source(s) (found: nullsoft); using nullsoft from winget (source 1 of 1)

    .EXAMPLE
        (Test-DepotAppSource -Path .\Contoso.App.yaml).Candidates | Format-Table

    .EXAMPLE
        Test-DepotAppSource -Id 7zip.7zip

    .OUTPUTS
        AppDepot.SourcePreview
    #>
    [CmdletBinding(DefaultParameterSetName = 'Winget')]
    [OutputType('AppDepot.SourcePreview')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Winget', Position = 0)] [string] $WingetId,
        [Parameter(Mandatory, ParameterSetName = 'Path')] [string] $Path,
        [Parameter(Mandatory, ParameterSetName = 'Manifest')] [hashtable] $Manifest,
        [Parameter(Mandatory, ParameterSetName = 'Existing')] [string] $Id,
        [Parameter(ParameterSetName = 'Winget')] [string] $Category,
        [Parameter(ParameterSetName = 'Winget')] [ValidateSet('x64', 'x86', 'arm64')] [string] $Architecture = 'x64'
    )
    switch ($PSCmdlet.ParameterSetName) {
        'Winget' {
            $r = Invoke-DepotApi -Path ("winget/packages/{0}" -f [uri]::EscapeDataString($WingetId)) -Admin `
                -Query @{ category = $Category; architecture = $Architecture }
            ConvertTo-DepotPreview $r.preview $r.manifest $r.info ([bool]$r.in_repository)
        }
        'Path' {
            $text = Get-Content -LiteralPath $Path -Raw
            $r = Invoke-DepotApi -Path 'apps/preview/yaml' -Method POST -RawBody $text -ContentType 'application/yaml' -Admin
            ConvertTo-DepotPreview $r $null $null $false
        }
        'Manifest' {
            $r = Invoke-DepotApi -Path 'apps/preview' -Method POST -Body $Manifest -Admin
            ConvertTo-DepotPreview $r ([pscustomobject]$Manifest) $null $false
        }
        'Existing' {
            $r = Invoke-DepotApi -Path ("apps/{0}/preview" -f [uri]::EscapeDataString($Id)) -Method POST -Admin
            ConvertTo-DepotPreview $r $null $null $true
        }
    }
}

function New-DepotApp {
    <#
    .SYNOPSIS
        Adds a new application to the repository. (Administrative)

    .DESCRIPTION
        Adds an application in one of three ways:

          -WingetId   the server generates the manifest from the winget catalog (name, publisher,
                      description, licence, homepage, category, detection rule)
          -Path       a manifest YAML file you wrote (see Get-DepotManifestTemplate)
          -Manifest   a hashtable with the same keys as a manifest file

        The server previews the sources first; the result tells you which installer will be used
        and whether an MSI is available (MSI is always preferred). The manifest is then saved in
        the server's manifests folder and loaded into the database. Use -CheckNow to download the
        application immediately instead of waiting for the next scheduled check.

        Use -WhatIf to see the preview without adding anything. Requires the server API key.

    .PARAMETER WingetId
        winget package id, e.g. Notepad++.Notepad++ (find it with Find-DepotWingetPackage).

    .PARAMETER Path
        Manifest YAML file.

    .PARAMETER Manifest
        Manifest hashtable.

    .PARAMETER Category
        Category for a winget application (default: guessed from its description and tags).

    .PARAMETER Architecture
        Architecture for a winget application (default x64).

    .PARAMETER CheckNow
        Download the application right away.

    .PARAMETER Replace
        Overwrite an application that already exists.

    .EXAMPLE
        New-DepotApp -WingetId Notepad++.Notepad++ -CheckNow

    .EXAMPLE
        Find-DepotWingetPackage putty | Select-Object -First 1 | New-DepotApp -Category Networking

    .EXAMPLE
        New-DepotApp -WingetId Adobe.Acrobat.Reader.64-bit -WhatIf

        Shows the generated manifest and installer preview without adding the application.

    .EXAMPLE
        Get-DepotManifestTemplate web | Set-Content .\Contoso.App.yaml
        notepad .\Contoso.App.yaml
        Test-DepotAppSource -Path .\Contoso.App.yaml
        New-DepotApp -Path .\Contoso.App.yaml -CheckNow

    .EXAMPLE
        New-DepotApp -Manifest @{
            id = 'Contoso.Agent'; name = 'Contoso Agent'; publisher = 'Contoso'; category = 'Security'
            source = @{ type = 'url'; url = 'https://contoso.example/agent/latest.msi'; version_from = 'msi' }
        }

    .OUTPUTS
        AppDepot.SourcePreview

    .LINK
        Find-DepotWingetPackage
    .LINK
        Test-DepotAppSource
    .LINK
        Remove-DepotApp
    #>
    [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Winget')]
    [OutputType('AppDepot.SourcePreview')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Winget', Position = 0, ValueFromPipelineByPropertyName)]
        [Alias('Id')] [string] $WingetId,
        [Parameter(Mandatory, ParameterSetName = 'Path')] [string] $Path,
        [Parameter(Mandatory, ParameterSetName = 'Manifest')] [hashtable] $Manifest,
        [Parameter(ParameterSetName = 'Winget')] [string] $Category,
        [Parameter(ParameterSetName = 'Winget')] [ValidateSet('x64', 'x86', 'arm64')] [string] $Architecture = 'x64',
        [switch] $CheckNow,
        [switch] $Replace
    )
    process {
        $saved = $null
        $query = @{ replace = [bool]$Replace; check = [bool]$CheckNow }
        switch ($PSCmdlet.ParameterSetName) {
            'Winget' {
                try { $preview = Test-DepotAppSource -WingetId $WingetId -Category $Category -Architecture $Architecture -ErrorAction Stop }
                catch { Write-Error -Message "Cannot add ${WingetId}: $($_.Exception.Message)" -TargetObject $WingetId; return }
                if ($preview.InRepository -and -not $Replace) {
                    Write-Warning "$WingetId is already in the repository. Use -Replace to regenerate its manifest."
                    return $preview
                }
                if (-not $preview.Ok) { Write-Warning "No installer was found for $WingetId; it will fail until the source provides one." }
                if ($PSCmdlet.ShouldProcess("$($preview.Name) [$WingetId] - $($preview.Installer) $($preview.LatestVersion)", 'Add to repository')) {
                    $saved = Invoke-DepotApi -Path 'apps' -Method POST -Body $preview.Manifest -Query $query -Admin
                }
            }
            'Path' {
                try { $preview = Test-DepotAppSource -Path $Path -ErrorAction Stop }
                catch { Write-Error -Message "Cannot add ${Path}: $($_.Exception.Message)" -TargetObject $Path; return }
                if ($PSCmdlet.ShouldProcess("$($preview.Id) - $($preview.Installer) $($preview.LatestVersion)", 'Add to repository')) {
                    $saved = Invoke-DepotApi -Path 'apps/yaml' -Method POST -RawBody (Get-Content -LiteralPath $Path -Raw) `
                        -ContentType 'application/yaml' -Query $query -Admin
                }
            }
            'Manifest' {
                try { $preview = Test-DepotAppSource -Manifest $Manifest -ErrorAction Stop }
                catch { Write-Error -Message "Cannot add the manifest: $($_.Exception.Message)" -TargetObject $Manifest; return }
                if ($PSCmdlet.ShouldProcess("$($preview.Id) - $($preview.Installer) $($preview.LatestVersion)", 'Add to repository')) {
                    $saved = Invoke-DepotApi -Path 'apps' -Method POST -Body $Manifest -Query $query -Admin
                }
            }
        }
        if ($saved) {
            $preview.InRepository = $true
            $preview | Add-Member -NotePropertyName ManifestPath -NotePropertyValue $saved.manifest_path
            $preview | Add-Member -NotePropertyName CheckQueued -NotePropertyValue ([bool]$saved.check_queued)
            if (-not $preview.MsiAvailable -and $preview.Ok) {
                Write-Verbose "No MSI is available for $($preview.Id); using $($preview.Installer)."
            }
        }
        $preview
    }
}

function Remove-DepotApp {
    <#
    .SYNOPSIS
        Removes an application from the repository. (Administrative)

    .DESCRIPTION
        Removes the application from the database and stops checking it for updates. Its manifest
        file on the server is renamed to *.removed (so it is not re-added and can be restored).
        Stored installers are kept unless -DeleteFiles is used. Computers that already installed the
        application are not affected. Requires the server API key.

    .PARAMETER Id
        Application id.

    .PARAMETER DeleteFiles
        Also delete every stored version (installers and Intune packages) from the repository.

    .EXAMPLE
        Remove-DepotApp Contoso.OldTool

    .EXAMPLE
        Remove-DepotApp Contoso.OldTool -DeleteFiles -Confirm:$false
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipelineByPropertyName)] [string] $Id,
        [switch] $DeleteFiles
    )
    process {
        $what = if ($DeleteFiles) { 'Remove from repository and delete its files' } else { 'Remove from repository' }
        if ($PSCmdlet.ShouldProcess($Id, $what)) {
            Invoke-DepotApi -Path ("apps/{0}" -f [uri]::EscapeDataString($Id)) -Method DELETE -Query @{ delete_files = [bool]$DeleteFiles } -Admin
        }
    }
}

function Get-DepotManifestTemplate {
    <#
    .SYNOPSIS
        Returns a manifest template for writing an application definition by hand.

    .DESCRIPTION
        Templates exist for every source type: winget, github, web (scrape a download page), json
        (vendor API), url (fixed "latest" link) and multi (several sources; the MSI is preferred).
        Save the template, edit it, check it with Test-DepotAppSource -Path and add it with
        New-DepotApp -Path. See docs/manifest-reference.md for every option.

    .PARAMETER Type
        winget, github, web, json, url or multi.

    .EXAMPLE
        Get-DepotManifestTemplate web | Set-Content .\Contoso.App.yaml
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)] [ValidateSet('winget', 'github', 'web', 'json', 'url', 'multi')] [string] $Type)
    (Invoke-DepotApi -Path "templates/$Type" -Admin).yaml
}
