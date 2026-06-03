function Get-R18DevDumpStatus {
    <#
    .SYNOPSIS
        Report freshness of the local r18.dev cache from its sidecar marker.
    .DESCRIPTION
        Returns an object: { exists, dbPath, dumpDate, ageDays, stale,
        maxAgeDays, builtAt }. 'stale' is true when the cache is missing or its
        dump date is older than 'database.r18dump.maxagedays'. Backs the
        /api/r18dump/status route and the startup auto-refresh check.
    #>
    [CmdletBinding()]
    param (
        [Parameter()]
        [String]$DbPath,

        [Parameter()]
        [int]$MaxAgeDays
    )

    if (-not $DbPath) { $DbPath = Get-R18DevDbPath }
    if (-not $PSBoundParameters.ContainsKey('MaxAgeDays')) {
        $MaxAgeDays = 7
        try {
            $settings = Get-JVSettings -ErrorAction SilentlyContinue
            if ($null -ne $settings.'database.r18dump.maxagedays') {
                $MaxAgeDays = [int]$settings.'database.r18dump.maxagedays'
            }
        } catch {}
    }

    $exists = Test-Path -LiteralPath $DbPath
    $markerPath = "$DbPath.meta.json"
    $dumpDate = $null
    $builtAt = $null
    $ageDays = $null

    if (Test-Path -LiteralPath $markerPath) {
        try {
            $marker = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json
            $dumpDate = $marker.dumpDate
            $builtAt = $marker.builtAt
            if ($dumpDate) {
                $parsed = [datetime]::MinValue
                if ([datetime]::TryParse($dumpDate, [ref]$parsed)) {
                    $ageDays = [int][math]::Floor(((Get-Date).ToUniversalTime() - $parsed.ToUniversalTime()).TotalDays)
                }
            }
        } catch {}
    }

    $stale = (-not $exists) -or ($null -eq $ageDays) -or ($ageDays -gt $MaxAgeDays)

    [PSCustomObject]@{
        exists     = [bool]$exists
        dbPath     = $DbPath
        dumpDate   = $dumpDate
        ageDays    = $ageDays
        stale      = [bool]$stale
        maxAgeDays = $MaxAgeDays
        builtAt    = $builtAt
    }
}
