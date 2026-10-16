function Compare-DepotVersion {
    <#
    .SYNOPSIS
        Compares two version strings the same way the AppDepot server does.

    .DESCRIPTION
        Returns -1 if ReferenceVersion is older, 0 if equal and 1 if newer than DifferenceVersion.

        The comparison tolerates real-world version formats that [version] cannot parse:
          * numbers compare numerically       24.08  -eq 24.8
          * trailing zeros are ignored        1.0    -eq 1.0.0
          * pre-release tags sort earlier     1.0-rc1 -lt 1.0
          * a leading 'v' is ignored          v3.1   -eq 3.1

    .PARAMETER ReferenceVersion
        The version to compare.

    .PARAMETER DifferenceVersion
        The version to compare against.

    .EXAMPLE
        Compare-DepotVersion '1.10' '1.9'
        1

    .EXAMPLE
        Compare-DepotVersion '24.08' '24.8.0'
        0

    .OUTPUTS
        System.Int32
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory, Position = 0)] [AllowEmptyString()] [AllowNull()] [string] $ReferenceVersion,
        [Parameter(Mandatory, Position = 1)] [AllowEmptyString()] [AllowNull()] [string] $DifferenceVersion
    )
    $a = Get-DepotVersionKey $ReferenceVersion
    $b = Get-DepotVersionKey $DifferenceVersion
    $n = [Math]::Min($a.Count, $b.Count)
    for ($i = 0; $i -lt $n; $i++) {
        for ($j = 0; $j -lt 3; $j++) {
            $x = $a[$i][$j]; $y = $b[$i][$j]
            if ($j -eq 2) { $c = [string]::CompareOrdinal([string]$x, [string]$y) } else { $c = ([decimal]$x).CompareTo([decimal]$y) }
            if ($c -ne 0) { return [Math]::Sign($c) }
        }
    }
    return [Math]::Sign($a.Count.CompareTo($b.Count))
}
