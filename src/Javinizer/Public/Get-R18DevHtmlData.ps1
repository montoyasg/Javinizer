# Cloudflare's posture on r18.dev's JSON API flips periodically over which
# User-Agents it serves vs. challenges. As of this writing it 403s
# browser-impersonating UAs (a Chrome string from a non-browser TLS stack reads
# as a bot) and known library UAs (python-requests, PowerShell), but lets
# simple command-line tool UAs through. We try these in order and fall through
# to the next on a Cloudflare block; the first that returns real JSON wins.
$script:R18DevUserAgents = @(
    'curl/8.7.1'
    'Wget/1.21.4'
    'Javinizer'
)

function Get-R18DevJsonRecord {
    <#
    .SYNOPSIS
        Live fallback for r18.dev titles newer than the local dump, via the
        plain JSON API.
    .DESCRIPTION
        r18.dev's JSON detail API is reachable over ordinary HTTPS as long as
        the request uses a User-Agent Cloudflare currently allows (see
        $script:R18DevUserAgents). This does the same
        two-step lookup the old scraper did -- dvd_id -> content_id, then
        combined=<content_id> for the full record -- with Invoke-WebRequest, so
        no headless browser is needed. It is the primary live path because it
        is an order of magnitude faster and more reliable than driving
        Chromium; Get-R18DevHtmlRecord (Playwright) remains as a last resort
        for when Cloudflare hardens again.

        The returned object is the original r18.dev API shape that
        Get-R18DevData / Scraper.R18dev.ps1 already consume unchanged. The
        combined endpoint omits dvd_id, so we inject the looked-up id back in
        (Get-R18DevId reads .dvd_id, and Get-R18DevUrl validates against it).

        Returns $null on any miss/failure so the caller degrades gracefully.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, Position = 0)]
        [String]$Id,

        [Parameter()]
        [int]$TimeoutSec = 20
    )

    $base = 'https://r18.dev/videos/vod/movies/detail/-'

    # Step 1: dvd_id -> content_id.
    $lookup = Get-R18DevJsonViaHttp -Uri "$base/dvd_id=$Id/json" -TimeoutSec $TimeoutSec
    if (-not $lookup -or -not $lookup.content_id) {
        return
    }

    # Step 2: full detail by content_id.
    $detail = Get-R18DevJsonViaHttp -Uri "$base/combined=$($lookup.content_id)/json" -TimeoutSec $TimeoutSec
    if (-not $detail) {
        return
    }

    # The combined endpoint returns dvd_id: null; restore it from the input so
    # downstream Id extraction and validation work.
    if (-not $detail.dvd_id) {
        $detail | Add-Member -NotePropertyName 'dvd_id' -NotePropertyValue $Id -Force
    }

    Write-Output $detail
}

function Get-R18DevJsonViaHttp {
    <#
    .SYNOPSIS
        Fetch and parse an r18.dev JSON endpoint over plain HTTPS.
    .DESCRIPTION
        Tries each UA in $script:R18DevUserAgents until one is served the real
        JSON, so a Cloudflare 403 against one UA falls through to the next
        instead of failing the whole lookup. A genuine "not in r18.dev's
        catalog" surfaces as a 404 -- no UA changes that, so we stop early.
        Returns $null on any miss/empty body/parse failure.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [String]$Uri,

        [Parameter()]
        [int]$TimeoutSec = 20
    )

    $resp = $null
    foreach ($ua in $script:R18DevUserAgents) {
        try {
            $resp = Invoke-WebRequest -Uri $Uri -UserAgent $ua -Method Get -TimeoutSec $TimeoutSec -Verbose:$false -ErrorAction Stop
            break
        } catch {
            $status = $null
            try { $status = [int]$PSItem.Exception.Response.StatusCode } catch {}

            if ($status -eq 404) {
                # Genuine miss: the title is not in r18.dev's catalog.
                Write-JVLog -Write:$script:JVLogWrite -LogPath $script:JVLogPath -WriteLevel $script:JVLogWriteLevel -Level Debug -Message "[$($MyInvocation.MyCommand.Name)] [$Uri] not in r18.dev catalog (404)"
                return
            }

            # 403 = Cloudflare challenge for this UA; try the next one.
            Write-JVLog -Write:$script:JVLogWrite -LogPath $script:JVLogPath -WriteLevel $script:JVLogWriteLevel -Level Debug -Message "[$($MyInvocation.MyCommand.Name)] UA [$ua] blocked (status [$status]) for [$Uri]; trying next UA"
        }
    }

    if (-not $resp -or -not $resp.Content) { return }

    try {
        return $resp.Content | ConvertFrom-Json
    } catch {
        Write-JVLog -Write:$script:JVLogWrite -LogPath $script:JVLogPath -WriteLevel $script:JVLogWriteLevel -Level Debug -Message "[$($MyInvocation.MyCommand.Name)] could not parse JSON from [$Uri]: $PSItem"
        return
    }
}

function Get-R18DevHtmlRecord {
    <#
    .SYNOPSIS
        Best-effort Playwright fallback for r18.dev titles newer than the local
        dump, for when the plain-HTTP JSON path (Get-R18DevJsonRecord) is
        Cloudflare-blocked.
    .DESCRIPTION
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

    # The combined endpoint returns dvd_id: null; restore it from the input so
    # downstream Id extraction and validation work.
    if (-not $detail.dvd_id) {
        $detail | Add-Member -NotePropertyName 'dvd_id' -NotePropertyValue $Id -Force
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
