# xcity.jp actress metadata scraper.
#
#   Invoke-XcityRequest      — HTTP GET wrapper with browser-like headers,
#                               jittered delays, and adaptive backoff.
#   Find-XcityActressByName  — search by romaji name, returns search hits.
#   Get-XcityActressDetail   — fetch /idol/detail/{id}/, returns parsed entry.
#
# xcity does not index kanji — only romaji search returns hits. Pass the
# JapaneseName from the upstream scrape separately when persisting.

$script:XcityUserAgents = @(
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/121.0.0.0 Safari/537.36'
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/121.0.0.0 Safari/537.36'
    'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/121.0.0.0 Safari/537.36'
)

# Pin one UA per process. Switching mid-session is itself a bot tell.
if (-not $script:XcityUserAgent) {
    $script:XcityUserAgent = $script:XcityUserAgents | Get-Random
}

$script:XcityBaseUrl = 'https://xxx.xcity.jp'

# ── Disk cache ────────────────────────────────────────────────────────────────
# Stores xcity responses under ~/.javinizer/xcity-cache/<sha256(uri)>.json so
# repeated runs within the TTL serve from disk and avoid hammering the site.
# Search-results TTL is shorter than detail-page TTL because search hits can
# shift (new actresses, alias changes); detail pages are nearly immutable.

function Get-XcityCacheDir {
    $homeDir = if ($env:HOME) { $env:HOME } elseif ($HOME) { $HOME } elseif ($env:USERPROFILE) { $env:USERPROFILE } else { '.' }
    $dir = Join-Path $homeDir '.javinizer/xcity-cache'
    if (-not (Test-Path -LiteralPath $dir)) {
        try { New-Item -ItemType Directory -Path $dir -Force | Out-Null } catch {}
    }
    return $dir
}

function Get-XcityCacheKey {
    param([Parameter(Mandatory)][string]$Uri)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Uri)
    $hash = [System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes)
    return ([System.BitConverter]::ToString($hash) -replace '-', '').ToLowerInvariant()
}

function Get-XcityCacheTtlForUri {
    param([Parameter(Mandatory)][string]$Uri)
    if ($Uri -match '/idol/detail/\d+/') { return 14 * 24 * 60 * 60 }   # 14 days
    if ($Uri -match '/idol/\?q=')        { return 24 * 60 * 60 }        # 24 hours
    return 60 * 60                                                       # 1 hour fallback
}

function Get-XcityCachedResponse {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][int]$MaxAgeSeconds
    )
    $path = Join-Path (Get-XcityCacheDir) "$(Get-XcityCacheKey $Uri).json"
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        $entry = Get-Content -LiteralPath $path -Raw -Encoding utf8 | ConvertFrom-Json
        # ConvertFrom-Json auto-coerces ISO timestamps into DateTime under
        # PS 7+. If we get a string back (older PS or non-ISO format) parse
        # it via invariant culture so we don't trip on locale formatting.
        $fetched = if ($entry.fetchedAt -is [DateTime]) {
            $entry.fetchedAt.ToUniversalTime()
        } else {
            [DateTime]::Parse([string]$entry.fetchedAt, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
        }
        $ageSec = ((Get-Date).ToUniversalTime() - $fetched).TotalSeconds
        if ($ageSec -gt $MaxAgeSeconds) { return $null }
        return $entry
    } catch {
        return $null
    }
}

function Set-XcityCachedResponse {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][int]$StatusCode,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content
    )
    $path = Join-Path (Get-XcityCacheDir) "$(Get-XcityCacheKey $Uri).json"
    $entry = [ordered]@{
        url        = $Uri
        fetchedAt  = (Get-Date).ToUniversalTime().ToString('o')
        statusCode = $StatusCode
        content    = $Content
    }
    try {
        $tmp = "$path.tmp"
        [System.IO.File]::WriteAllText($tmp, ($entry | ConvertTo-Json -Depth 4 -Compress), [System.Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $tmp -Destination $path -Force
    } catch {
        # Cache writes are best-effort; never let them fail the request.
    }
}

function Invoke-XcityRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Uri,

        [Parameter(Mandatory)]
        [Microsoft.PowerShell.Commands.WebRequestSession]$Session,

        [string]$Referer,

        [int[]]$DelayRangeMs = @(600, 1500),

        [int]$MaxRetries = 4,

        # Bypass the disk cache for this request (still writes back on success).
        [switch]$NoCache
    )

    # Cache check (default-on). If a fresh cached response exists for this
    # URL, return it without touching the network.
    if (-not $NoCache) {
        $ttl = Get-XcityCacheTtlForUri -Uri $Uri
        $cached = Get-XcityCachedResponse -Uri $Uri -MaxAgeSeconds $ttl
        if ($cached) {
            return [PSCustomObject]@{
                Content    = $cached.content
                StatusCode = $cached.statusCode
                FromCache  = $true
            }
        }
    }

    # Polite jittered delay between requests within a session.
    if ($Session.Cookies.Count -gt 0) {
        $delay = Get-Random -Minimum $DelayRangeMs[0] -Maximum $DelayRangeMs[1]
        Start-Sleep -Milliseconds $delay
    }

    $headers = @{
        'Accept'                    = 'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8'
        'Accept-Language'           = 'en-US,en;q=0.9'
        'Accept-Encoding'           = 'gzip, deflate, br'
        'Cache-Control'             = 'max-age=0'
        'Connection'                = 'keep-alive'
        'Sec-Fetch-Dest'            = 'document'
        'Sec-Fetch-Mode'            = 'navigate'
        'Sec-Fetch-Site'            = $(if ($Referer) { 'same-origin' } else { 'none' })
        'Sec-Fetch-User'            = '?1'
        'Upgrade-Insecure-Requests' = '1'
        'sec-ch-ua'                 = '"Chromium";v="121", "Not(A:Brand";v="24", "Google Chrome";v="121"'
        'sec-ch-ua-mobile'          = '?0'
        'sec-ch-ua-platform'        = '"macOS"'
    }
    if ($Referer) { $headers['Referer'] = $Referer }

    $reqParams = @{
        Uri                = $Uri
        Method             = 'Get'
        Headers            = $headers
        UserAgent          = $script:XcityUserAgent
        WebSession         = $Session
        UseBasicParsing    = $true
        MaximumRedirection = 5
        ErrorAction        = 'Stop'
        TimeoutSec         = 30
    }

    $backoffSeconds = @(5, 15, 60, 180)
    for ($attempt = 0; $attempt -le $MaxRetries; $attempt++) {
        try {
            $response = Invoke-WebRequest @reqParams

            if ($response.Content -match '(?i)access denied|cloudflare|captcha|challenge-platform') {
                throw "[Xcity] response body suggests a block/captcha at [$Uri]"
            }

            # Persist to disk cache on success so future runs short-circuit
            # the network. Best-effort — failures here don't fail the request.
            try { Set-XcityCachedResponse -Uri $Uri -StatusCode ([int]$response.StatusCode) -Content $response.Content } catch {}

            return $response
        } catch {
            $statusCode = $null
            try { $statusCode = [int]$_.Exception.Response.StatusCode } catch {}

            # Honor Retry-After if the server told us how long to wait. Value
            # may be either delta-seconds (RFC 9110 §10.2.3) or an HTTP-date.
            $retryAfterSec = $null
            try {
                $ra = $null
                try { $ra = $_.Exception.Response.Headers['Retry-After'] } catch {}
                if (-not $ra) {
                    try { $ra = ($_.Exception.Response.Headers.GetValues('Retry-After') | Select-Object -First 1) } catch {}
                }
                if ($ra) {
                    $intVal = 0
                    if ([int]::TryParse("$ra", [ref]$intVal) -and $intVal -gt 0) {
                        $retryAfterSec = $intVal
                    } else {
                        try {
                            $dt = [DateTime]::Parse("$ra")
                            $retryAfterSec = [Math]::Max(1, [int]($dt.ToUniversalTime() - (Get-Date).ToUniversalTime()).TotalSeconds)
                        } catch {}
                    }
                }
            } catch {}

            $isRetryable = ($statusCode -in 429, 500, 502, 503, 504) -or
                           ($_.Exception.GetType().Name -match 'TimeoutException|HttpRequestException')

            if ($attempt -eq $MaxRetries -or -not $isRetryable -or $statusCode -eq 403) {
                if ($statusCode) {
                    throw "[Xcity] HTTP $statusCode for [$Uri]: $($_.Exception.Message)"
                }
                throw "[Xcity] request failed for [$Uri]: $($_.Exception.Message)"
            }

            # Use Retry-After when present (capped to 120s; 10-minute server-
            # directed sleeps are unreasonable in an interactive batch and
            # the per-name 90s ceiling above already bounds total damage).
            # Else fall back to the exponential schedule.
            $sleep = if ($retryAfterSec) { [Math]::Min($retryAfterSec, 120) }
                     else { $backoffSeconds[[Math]::Min($attempt, $backoffSeconds.Count - 1)] }
            $reason = if ($retryAfterSec) {
                if ($retryAfterSec -gt 120) { "Retry-After=$retryAfterSec capped" } else { "Retry-After=$retryAfterSec" }
            } else { "schedule" }
            Write-Verbose "[Xcity] HTTP $statusCode for [$Uri], backing off ${sleep}s ($reason, attempt $($attempt + 1)/$MaxRetries)"
            # Surface backoff to whatever runspace is driving this call so the
            # job log can show why progress paused. The buffer is per-runspace
            # ($script: scope), set by the caller before invoking the scraper.
            if ($null -ne $script:XcityBackoffLog) {
                $ts = Get-Date -Format 'HH:mm:ss'
                $script:XcityBackoffLog.Add("[$ts] xcity backoff ${sleep}s for [$Uri] (attempt $($attempt + 1)/$MaxRetries, $reason, status=$statusCode)") | Out-Null
            }
            Start-Sleep -Seconds $sleep
        }
    }
}

function ConvertTo-XcityAbsoluteUrl {
    param([string]$Url)
    if (-not $Url) { return $null }
    if ($Url -match '^https?://') { return $Url }
    if ($Url.StartsWith('//')) { return 'https:' + $Url }
    if ($Url.StartsWith('/')) { return $script:XcityBaseUrl + $Url }
    return $script:XcityBaseUrl + '/idol/' + $Url
}

function ConvertTo-XcityNormalizedName {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    # Strip macrons + collapse common long-vowel transliterations to a
    # single canonical form so "Yūna Ogura" / "Yuuna Ogura" / "Yuna Ogura"
    # all hash to the same string. Casefolded + whitespace-collapsed.
    $n = $Name.ToLowerInvariant()
    $n = $n -replace '[ūűû]', 'u' -replace '[ōőô]', 'o' -replace '[āăâ]', 'a' -replace '[īĭî]', 'i' -replace '[ēĕê]', 'e'
    $n = $n -replace 'uu', 'u' -replace 'oo', 'o' -replace 'ou', 'o' -replace 'ei', 'e'
    return ($n -replace '\s+', ' ').Trim()
}

function Get-XcityRomajiVariants {
    <#
    .SYNOPSIS
    Generate plausible romaji spelling variants of a name. Used as fallback
    queries when the exact-spelling xcity search returns nothing.

    Variants emitted (in priority order, capped at 8):
      1. The original name
      2. Long-vowel forms: ū↔uu, ō↔oo, ā↔aa, ī↔ii, ē↔ee
      3. Stripped-macron form: Yūna → Yuna
      4. Double-vowel collapsed: Yuuna → Yuna
      5. Token-swapped versions of (1)–(4)
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)

    $primary = New-Object System.Collections.Generic.List[string]
    $primary.Add($Name) | Out-Null

    $stripped  = $Name -replace 'ū', 'u' -replace 'ō', 'o' -replace 'ā', 'a' -replace 'ī', 'i' -replace 'ē', 'e'
    $expanded  = $Name -replace 'ū', 'uu' -replace 'ō', 'oo' -replace 'ā', 'aa' -replace 'ī', 'ii' -replace 'ē', 'ee'
    $collapsed = $Name -replace 'uu', 'u' -replace 'oo', 'o' -replace 'ou', 'o'
    foreach ($v in @($stripped, $expanded, $collapsed)) {
        if ($v -and $v -ne $Name -and -not $primary.Contains($v)) { $primary.Add($v) | Out-Null }
    }

    # Token-swap each primary variant.
    $all = New-Object System.Collections.Generic.List[string]
    foreach ($v in $primary) {
        if (-not $all.Contains($v)) { $all.Add($v) | Out-Null }
        $tokens = $v -split '\s+' | Where-Object { $_ }
        if ($tokens.Count -eq 2) {
            $swap = "$($tokens[1]) $($tokens[0])"
            if (-not $all.Contains($swap)) { $all.Add($swap) | Out-Null }
        }
    }

    if ($all.Count -gt 8) { return @($all | Select-Object -First 8) }
    return $all.ToArray()
}

function Test-XcityNameMatch {
    <#
    .SYNOPSIS
    Returns $true if two names look like the same person after
    normalization. Used to filter fuzzy-search results so a query for
    "Yuna" doesn't return "Yuna Tanaka" as a false positive.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$A,
        [Parameter(Mandatory)][string]$B
    )
    $na = ConvertTo-XcityNormalizedName $A
    $nb = ConvertTo-XcityNormalizedName $B
    if ($na -eq $nb) { return $true }

    $ta = @($na -split '\s+' | Where-Object { $_ })
    $tb = @($nb -split '\s+' | Where-Object { $_ })
    # Both names have the same 2 tokens (possibly in different order).
    if ($ta.Count -eq 2 -and $tb.Count -eq 2) {
        $sortedA = ($ta | Sort-Object) -join ' '
        $sortedB = ($tb | Sort-Object) -join ' '
        if ($sortedA -eq $sortedB) { return $true }
    }
    return $false
}

function Find-XcityActressByName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Name,

        [Parameter(Mandatory)]
        [Microsoft.PowerShell.Commands.WebRequestSession]$Session,

        [int]$MaxResults = 10,

        # When set, retry with romaji variants (macron/double-vowel/swap) if
        # the exact-spelling search returns no hits, and filter results by
        # Test-XcityNameMatch so we don't accept loosely-related names.
        [switch]$Fuzzy
    )

    if ($Fuzzy) {
        # Per-name absolute wall-time ceiling. With up to 8 romaji variants
        # and worst-case ~120s Retry-After per attempt, fuzzy could otherwise
        # eat ~16 min per name. Bail at 90s and let the caller move on.
        $maxFuzzyMs = 90 * 1000
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $variants = Get-XcityRomajiVariants -Name $Name
        $tried = 0
        foreach ($cand in $variants) {
            if ($sw.ElapsedMilliseconds -gt $maxFuzzyMs) {
                if ($null -ne $script:XcityBackoffLog) {
                    $ts = Get-Date -Format 'HH:mm:ss'
                    $script:XcityBackoffLog.Add("[$ts] xcity per-name timeout ($([int]($sw.ElapsedMilliseconds/1000))s) for [$Name]; tried $tried/$($variants.Count) variants, giving up") | Out-Null
                }
                break
            }
            $tried++
            $hits = Find-XcityActressByName -Name $cand -Session $Session -MaxResults $MaxResults
            if (-not $hits -or $hits.Count -eq 0) { continue }
            $accepted = New-Object System.Collections.Generic.List[Object]
            foreach ($h in $hits) {
                if (Test-XcityNameMatch -A $Name -B $h.Name) { $accepted.Add($h) | Out-Null }
                if ($accepted.Count -ge $MaxResults) { break }
            }
            if ($accepted.Count -gt 0) { return ,$accepted.ToArray() }
        }
        return ,@()
    }

    Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue
    $query = [System.Web.HttpUtility]::UrlEncode($Name)
    $uri = "$($script:XcityBaseUrl)/idol/?q=$query"

    $resp = Invoke-XcityRequest -Uri $uri -Session $Session -Referer "$($script:XcityBaseUrl)/idol/"
    $html = $resp.Content

    # Search rows: <div class="itemBox"><div class="mid">...
    #   <p class="tn"><a href="detail/{id}/" title="{name}"><img src="//.../thumb_X.jpg"/></a></p>
    #   <p class="name"><a ...>{name}<br>(opt aliases)</a></p>
    # </div></div>
    $rowPattern = '(?s)<div class="itemBox">\s*<div class="mid">.*?<p class="tn">\s*<a href="detail/(\d+)/"[^>]*title="([^"]+)">\s*<img src="([^"]+)"[^>]*class="actressThumb"[^>]*>.*?<p class="name">\s*<a[^>]*>\s*([^<]+?)<br>\s*(.*?)</a>\s*</p>\s*</div>\s*</div>'
    $rowMatches = [regex]::Matches($html, $rowPattern)
    $aliasLineRegex = [regex]'^\(([^)]+)\)$'

    $results = New-Object System.Collections.Generic.List[Object]
    foreach ($m in $rowMatches) {
        if ($results.Count -ge $MaxResults) { break }

        $id = $m.Groups[1].Value
        $title = $m.Groups[2].Value.Trim()
        $thumb = ConvertTo-XcityAbsoluteUrl $m.Groups[3].Value.Trim()
        $nameText = $m.Groups[4].Value.Trim()
        $aliasBlob = $m.Groups[5].Value.Trim() -replace '<br>', "`n" -replace '<[^>]+>', ''

        # Use [regex].Match to avoid clobbering the automatic $matches variable.
        $aliases = New-Object System.Collections.Generic.List[string]
        foreach ($line in ($aliasBlob -split "`n")) {
            $t = $line.Trim()
            if ($t) {
                $am = $aliasLineRegex.Match($t)
                if ($am.Success) { $aliases.Add($am.Groups[1].Value.Trim()) }
            }
        }

        $results.Add([PSCustomObject]@{
            Id        = $id
            Name      = if ($nameText) { $nameText } else { $title }
            Aliases   = $aliases.ToArray()
            ThumbUrl  = $thumb
            DetailUrl = "$($script:XcityBaseUrl)/idol/detail/$id/"
        })
    }

    return ,$results.ToArray()
}

function Get-XcityActressDetail {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Id,

        [Parameter(Mandatory)]
        [Microsoft.PowerShell.Commands.WebRequestSession]$Session,

        [string]$Referer
    )

    $uri = "$($script:XcityBaseUrl)/idol/detail/$Id/"
    $resp = Invoke-XcityRequest -Uri $uri -Session $Session -Referer $Referer
    $html = $resp.Content

    $entry = [ordered]@{
        Id           = $Id
        Url          = $uri
        Name         = $null
        Aliases      = @()
        Birthdate    = $null
        BloodType    = $null
        BirthCity    = $null
        Height       = $null
        Measurements = $null
        Hobby        = $null
        SpecialSkill = $null
        Bio          = $null
        PrimaryUrl   = $null
        Raw          = [ordered]@{}
    }

    # For actresses with stage-name history, xcity stuffs aliases into the H1:
    #   <h1>Mio Kimijima[Yoko Ogura,Kaede Kyomoto,...,Mio Kimijima]</h1>
    $nameMatch = [regex]::Match($html, '(?s)<div id="avidolDetails">.*?<h1>([^<]+)</h1>')
    if ($nameMatch.Success) {
        $raw = [System.Net.WebUtility]::HtmlDecode($nameMatch.Groups[1].Value).Trim()
        $bracketMatch = [regex]::Match($raw, '^(.+?)\[(.+)\]\s*$')
        if ($bracketMatch.Success) {
            $entry.Name = $bracketMatch.Groups[1].Value.Trim()
            $aliasList = New-Object System.Collections.Generic.List[string]
            foreach ($a in ($bracketMatch.Groups[2].Value -split ',')) {
                $a = $a.Trim()
                if ($a -and $a -ne $entry.Name) { $aliasList.Add($a) | Out-Null }
            }
            $entry.Aliases = $aliasList.ToArray()
        } else {
            $entry.Name = $raw
        }
    }

    $thumbMatch = [regex]::Match($html, '<img src="([^"]+)"[^>]*alt="[^"]*"[^>]*class="actressThumb"')
    if ($thumbMatch.Success) {
        $entry.PrimaryUrl = ConvertTo-XcityAbsoluteUrl $thumbMatch.Groups[1].Value.Trim()
    }

    # Profile rows: <dd><span class="koumoku">{Field}</span>{Value}</dd>
    $ddPattern = '<dd[^>]*><span class="koumoku">([^<]+)</span>\s*([^<]*)</dd>'
    foreach ($dd in [regex]::Matches($html, $ddPattern)) {
        $field = $dd.Groups[1].Value.Trim()
        $value = [System.Net.WebUtility]::HtmlDecode($dd.Groups[2].Value).Trim()
        # "- Type" / "-" placeholders mean blank.
        $clean = $value -replace '^\s*[-–]\s*Type\s*$', '' -replace '^\s*[-–]\s*$', ''
        $entry.Raw[$field] = $value
        switch -Regex ($field) {
            '^Date of birth$'        { if ($clean) { $entry.Birthdate = $clean } }
            '^Blood Type$'           { if ($clean) { $entry.BloodType = $clean } }
            '^City of (Born|Birth)$' { if ($clean) { $entry.BirthCity = $clean } }
            '^Height$'               { if ($clean) { $entry.Height = $clean } }
            '^(Size|Measurements)$'  { if ($clean) { $entry.Measurements = $clean } }
            '^Hobby$'                { if ($clean) { $entry.Hobby = $clean } }
            '^Special Skill$'        { if ($clean) { $entry.SpecialSkill = $clean } }
            '^Other$'                { if ($clean) { $entry.Bio = $clean } }
        }
    }

    return [PSCustomObject]$entry
}
