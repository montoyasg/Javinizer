function Get-R18DevHtmlRecord {
    <#
    .SYNOPSIS
        Best-effort live fallback for r18.dev titles newer than the local dump.
    .DESCRIPTION
        r18.dev retired its plain JSON API and put the whole site behind
        Cloudflare. The weekly dump (queried via Get-R18DevDbRecord) covers
        everything up to the last dump date; this fills the gap for titles
        released since then.

        It fetches r18.dev's detail JSON *through the shared Playwright
        Chromium* (the same infrastructure JavDB uses to pass Cloudflare), so
        the TLS/HTTP2 fingerprint and cf_clearance cookie line up. The JSON it
        returns is the original r18.dev API shape, which Get-R18DevData /
        Scraper.R18dev.ps1 already consume unchanged.

        This path is best-effort: it requires the Playwright assembly +
        Chromium (present in the Javinizer Docker image, used for JavDB). On
        any failure -- no browser, Cloudflare block, JSON no longer served,
        parse error -- it returns $null so the caller degrades to other
        scrapers. The bulk dump and the jav.guru scraper are the primary
        sources for fresh titles.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, Position = 0)]
        [String]$Id,

        [Parameter()]
        [int]$NavigationTimeoutMs = 30000
    )

    if (-not (Get-Command Invoke-JavdbBrowserFetch -ErrorAction SilentlyContinue)) {
        return
    }

    $base = 'https://r18.dev/videos/vod/movies/detail/-'

    # Step 1: dvd_id -> content_id.
    $lookup = Get-R18DevJsonViaBrowser -Uri "$base/dvd_id=$Id/json" -NavigationTimeoutMs $NavigationTimeoutMs
    if (-not $lookup -or -not $lookup.content_id) {
        return
    }

    # Step 2: full detail by content_id.
    $detail = Get-R18DevJsonViaBrowser -Uri "$base/combined=$($lookup.content_id)/json" -NavigationTimeoutMs $NavigationTimeoutMs
    if (-not $detail) {
        return
    }

    Write-Output $detail
}

function Get-R18DevJsonViaBrowser {
    <#
    .SYNOPSIS
        Fetch a URL that returns JSON through Playwright and parse the body.
    .DESCRIPTION
        Headless Chromium renders a raw JSON response inside the page (commonly
        wrapped in a <pre> element). We pull the outermost JSON object out of
        the page content and parse it. Returns $null on any failure.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [String]$Uri,

        [Parameter()]
        [int]$NavigationTimeoutMs = 30000
    )

    try {
        $resp = Invoke-JavdbBrowserFetch -Uri $Uri -NavigationTimeoutMs $NavigationTimeoutMs
    } catch {
        Write-JVLog -Write:$script:JVLogWrite -LogPath $script:JVLogPath -WriteLevel $script:JVLogWriteLevel -Level Debug -Message "[$($MyInvocation.MyCommand.Name)] browser fetch failed for [$Uri]: $PSItem"
        return
    }

    $content = $resp.Content
    if (-not $content) { return }

    # Strip the <pre> wrapper Chromium adds around a raw JSON response.
    $candidate = $content
    if ($content -match '(?s)<pre[^>]*>(.*?)</pre>') {
        $candidate = $Matches[1]
    }

    # Reduce to the outermost {...} and HTML-decode the handful of entities
    # the JSON viewer escapes (<, >, &) before parsing.
    $first = $candidate.IndexOf('{')
    $last = $candidate.LastIndexOf('}')
    if ($first -lt 0 -or $last -le $first) { return }
    $jsonText = $candidate.Substring($first, $last - $first + 1)
    $jsonText = $jsonText -replace '&lt;', '<' -replace '&gt;', '>' -replace '&amp;', '&'

    try {
        return $jsonText | ConvertFrom-Json
    } catch {
        Write-JVLog -Write:$script:JVLogWrite -LogPath $script:JVLogPath -WriteLevel $script:JVLogWriteLevel -Level Debug -Message "[$($MyInvocation.MyCommand.Name)] could not parse JSON from [$Uri]: $PSItem"
        return
    }
}
