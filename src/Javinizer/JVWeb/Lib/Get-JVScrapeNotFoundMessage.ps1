function Get-JVScrapeNotFoundMessage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Id,

        [Parameter()]
        [object]$Settings
    )

    $fallback = $true
    try {
        $flag = $Settings.'web.scrape.javdb.fallback'
        if ($null -ne $flag) { $fallback = [bool]$flag }
    } catch {}

    if ($fallback) {
        return "No R18.dev or Javdb match for [$Id]"
    }
    return "No R18.dev match for [$Id]. Enable javdb fallback in settings (web.scrape.javdb.fallback=true)."
}
