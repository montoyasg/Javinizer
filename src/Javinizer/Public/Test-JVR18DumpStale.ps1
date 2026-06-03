function Test-JVR18DumpStale {
    <#
    .SYNOPSIS
        $true when the local r18.dev cache is missing or older than allowed.
    .DESCRIPTION
        Thin wrapper over Get-R18DevDumpStatus used by the JVWeb startup
        auto-refresh to decide whether to rebuild the cache.
    #>
    [CmdletBinding()]
    param (
        [Parameter()]
        [String]$DbPath,

        [Parameter()]
        [int]$MaxAgeDays
    )

    $params = @{}
    if ($DbPath) { $params['DbPath'] = $DbPath }
    if ($PSBoundParameters.ContainsKey('MaxAgeDays')) { $params['MaxAgeDays'] = $MaxAgeDays }

    (Get-R18DevDumpStatus @params).stale
}
