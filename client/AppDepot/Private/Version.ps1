function Get-DepotVersionKey {
    # Mirrors appdepot_server.versioning.version_key so client and server agree.
    param([string] $Version)
    $tokens = New-Object System.Collections.Generic.List[object]
    if ([string]::IsNullOrWhiteSpace($Version)) { return , @(, @(1, 0, '')) }
    $v = $Version.Trim()
    if ($v -match '^[vV]\d') { $v = $v.Substring(1) }
    $runStart = 0
    $trim = {
        while (($tokens.Count - $runStart) -gt 1 -and $tokens[$tokens.Count - 1][0] -eq 2 -and $tokens[$tokens.Count - 1][1] -eq 0) {
            $tokens.RemoveAt($tokens.Count - 1)
        }
    }
    foreach ($m in [regex]::Matches($v, '\d+|[A-Za-z]+')) {
        $t = $m.Value
        if ($t -match '^\d+$') {
            $tokens.Add(@(2, [decimal]$t, ''))
        }
        else {
            & $trim
            $tokens.Add(@(0, [decimal]0, $t.ToLowerInvariant()))
            $runStart = $tokens.Count
        }
    }
    & $trim
    $tokens.Add(@(1, [decimal]0, ''))
    return , $tokens.ToArray()
}
