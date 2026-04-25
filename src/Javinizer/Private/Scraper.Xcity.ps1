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

function Invoke-XcityRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Uri,

        [Parameter(Mandatory)]
        [Microsoft.PowerShell.Commands.WebRequestSession]$Session,

        [string]$Referer,

        [int[]]$DelayRangeMs = @(600, 1500),

        [int]$MaxRetries = 4
    )

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
            return $response
        } catch {
            $statusCode = $null
            try { $statusCode = [int]$_.Exception.Response.StatusCode } catch {}

            $isRetryable = ($statusCode -in 429, 500, 502, 503, 504) -or
                           ($_.Exception.GetType().Name -match 'TimeoutException|HttpRequestException')

            if ($attempt -eq $MaxRetries -or -not $isRetryable -or $statusCode -eq 403) {
                if ($statusCode) {
                    throw "[Xcity] HTTP $statusCode for [$Uri]: $($_.Exception.Message)"
                }
                throw "[Xcity] request failed for [$Uri]: $($_.Exception.Message)"
            }

            $sleep = $backoffSeconds[[Math]::Min($attempt, $backoffSeconds.Count - 1)]
            Write-Verbose "[Xcity] HTTP $statusCode for [$Uri], backing off ${sleep}s (attempt $($attempt + 1)/$MaxRetries)"
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

function Find-XcityActressByName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Name,

        [Parameter(Mandatory)]
        [Microsoft.PowerShell.Commands.WebRequestSession]$Session,

        [int]$MaxResults = 10
    )

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
