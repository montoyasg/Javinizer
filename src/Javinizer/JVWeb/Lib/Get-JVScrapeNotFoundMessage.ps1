function Get-JVScrapeNotFoundMessage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Id,

        [Parameter()]
        [object]$Settings
    )

    $javdbFallback = $true
    $javguruFallback = $true
    try {
        $flag = $Settings.'web.scrape.javdb.fallback'
        if ($null -ne $flag) { $javdbFallback = [bool]$flag }
    } catch {}
    try {
        $gflag = $Settings.'web.scrape.javguru.fallback'
        if ($null -ne $gflag) { $javguruFallback = [bool]$gflag }
    } catch {}

    $sources = @('R18.dev')
    if ($javguruFallback) { $sources += 'jav.guru' }
    if ($javdbFallback) { $sources += 'Javdb' }

    $tried = $sources -join ', '
    if ($javguruFallback -and $javdbFallback) {
        return "No $tried match for [$Id]"
    }
    $disabled = @()
    if (-not $javguruFallback) { $disabled += 'jav.guru (web.scrape.javguru.fallback)' }
    if (-not $javdbFallback) { $disabled += 'javdb (web.scrape.javdb.fallback)' }
    return "No $tried match for [$Id]. Enable more fallbacks in settings: $($disabled -join ', ')."
}
