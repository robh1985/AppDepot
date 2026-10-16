<#
.SYNOPSIS
    Regenerates docs/powershell-reference.md from the module's comment-based help.
.EXAMPLE
    ./client/build/New-ReferenceDocs.ps1
#>
param(
    [string] $ModulePath = [IO.Path]::Combine($PSScriptRoot, '..', 'AppDepot', 'AppDepot.psd1'),
    [string] $OutFile = [IO.Path]::Combine($PSScriptRoot, '..', '..', 'docs', 'powershell-reference.md')
)
$ErrorActionPreference = 'Stop'
Import-Module (Resolve-Path -LiteralPath $ModulePath).Path -Force
$order = 'Get-DepotApp','Find-DepotApp','Get-DepotAppVersion','Get-DepotInstalledApp','Get-DepotUpdate',
         'Install-DepotApp','Update-DepotApp','Uninstall-DepotApp','Save-DepotInstaller',
         'Get-DepotServerStatus','Get-DepotEvent','Invoke-DepotServerCheck','Set-DepotSchedule',
         'Find-DepotWingetPackage','Test-DepotAppSource','New-DepotApp','Remove-DepotApp','Get-DepotManifestTemplate',
         'Get-DepotConfig','Set-DepotConfig','Test-DepotConnection','Compare-DepotVersion','Show-DepotGui'
$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine('# PowerShell cmdlet reference')
[void]$sb.AppendLine()
[void]$sb.AppendLine('_Generated from the module''s comment-based help. The same text is available with_ `Get-Help <cmdlet> -Full`.')
[void]$sb.AppendLine()
[void]$sb.AppendLine('| Cmdlet | Synopsis |'); [void]$sb.AppendLine('|---|---|')
foreach ($n in $order) { $h = Get-Help $n; [void]$sb.AppendLine("| [$n](#$($n.ToLower())) | $($h.Synopsis.Trim()) |") }
[void]$sb.AppendLine()
foreach ($n in $order) {
    $h = Get-Help $n -Full
    [void]$sb.AppendLine("## $n"); [void]$sb.AppendLine()
    [void]$sb.AppendLine($h.Synopsis.Trim()); [void]$sb.AppendLine()
    [void]$sb.AppendLine('```powershell')
    $syntax = (Get-Command $n).ParameterSets | ForEach-Object {
        $parts = foreach ($p in $_.Parameters) {
            if ($p.Name -in [System.Management.Automation.PSCmdlet]::CommonParameters -or $p.Name -in 'WhatIf','Confirm') { continue }
            $t = if ($p.ParameterType -eq [switch]) { "-$($p.Name)" } else { "-$($p.Name) <$($p.ParameterType.Name)>" }
            if ($p.IsMandatory) { $t } else { "[$t]" }
        }
        $extra = if ((Get-Command $n).Parameters.ContainsKey('WhatIf')) { ' [-WhatIf] [-Confirm]' } else { '' }
        "$n $($parts -join ' ')$extra"
    }
    [void]$sb.AppendLine(($syntax -join "`n")); [void]$sb.AppendLine('```'); [void]$sb.AppendLine()
    $desc = ($h.description | ForEach-Object { $_.Text }) -join "`n"
    if ($desc) { [void]$sb.AppendLine('### Description'); [void]$sb.AppendLine(); [void]$sb.AppendLine('```text'); [void]$sb.AppendLine($desc.Trim()); [void]$sb.AppendLine('```'); [void]$sb.AppendLine() }
    $params = @($h.parameters.parameter | Where-Object { $_.Name -notin 'WhatIf','Confirm' })
    if ($params) {
        [void]$sb.AppendLine('### Parameters'); [void]$sb.AppendLine()
        [void]$sb.AppendLine('| Parameter | Type | Required | Pipeline | Description |'); [void]$sb.AppendLine('|---|---|---|---|---|')
        foreach ($p in $params) {
            $d = (($p.description | ForEach-Object { $_.Text }) -join ' ') -replace '\s+', ' ' -replace '\|', '\|'
            [void]$sb.AppendLine("| ``-$($p.name)`` | $($p.type.name) | $($p.required) | $($p.pipelineInput) | $($d.Trim()) |")
        }
        [void]$sb.AppendLine()
    }
    $ex = @($h.examples.example)
    if ($ex) {
        [void]$sb.AppendLine('### Examples'); [void]$sb.AppendLine()
        foreach ($e in $ex) {
            $code = ($e.code -replace '^PS C:\\>\s*', '').Trim()
            $remarks = (($e.remarks | ForEach-Object { $_.Text }) -join "`n").Trim()
            [void]$sb.AppendLine('```powershell'); [void]$sb.AppendLine($code)
            if ($remarks) { [void]$sb.AppendLine(); [void]$sb.AppendLine($remarks) }
            [void]$sb.AppendLine('```'); [void]$sb.AppendLine()
        }
    }
    $out = @($h.returnValues.returnValue | ForEach-Object { $_.type.name } | Where-Object { $_ })
    if ($out) { [void]$sb.AppendLine("**Output:** ``$($out -join ', ')``"); [void]$sb.AppendLine() }
}
Set-Content -LiteralPath ([IO.Path]::GetFullPath($OutFile)) -Value $sb.ToString() -Encoding UTF8
