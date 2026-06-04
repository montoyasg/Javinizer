function Get-R18DevUrl {
    <#
    .SYNOPSIS
        Resolve an r18.dev record for a movie ID.
    .DESCRIPTION
        r18.dev retired its public JSON API and now ships data as a weekly
        SQLite-importable dump. This looks the ID up in the local cache
        (Get-R18DevDbRecord) and, for titles newer than the last dump, can
        fall back to scraping the live r18.dev detail page through the shared
        Chromium fetch (Get-R18DevHtmlRecord). It returns the same
        { Id, Title, Url, Response } shape callers already expect, where
        Response is the reconstructed API-shaped object that Get-R18DevData
        consumes via -PreFetched.

        The -Source switch (or the 'scraper.movie.r18dev.source' setting)
        selects 'dump', 'dump+html' (default) or 'html'.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true)]
        [String]$Id,

        [Parameter()]
        [Switch]$Strict,

        [Parameter()]
        [ValidateSet('dump', 'dump+html', 'html')]
        [String]$Source,

        [Parameter()]
        [String]$DbPath
    )

    process {
        if (-not $Source) {
            $Source = Get-R18DevSource
        }

        # If a content Id is given, convert it back to standard movie Id form.
        if (!($Strict)) {
            if ($Id -match '(?:\d{1,5})?([a-zA-Z]{1,10}|[tT]28|[rR]18)(\d{5})') {
                Write-JVLog -Write:$script:JVLogWrite -LogPath $script:JVLogPath -WriteLevel $script:JVLogWriteLevel -Level Debug -Message "[$Id] [$($MyInvocation.MyCommand.Name)] Content ID [$Id] detected"
                $splitId = $Id | Select-String -Pattern '([a-zA-Z|tT28|rR18]{1,10})(\d{1,5})'
                $studioName = $splitId.Matches.Groups[1].Value
                $rawStudioId = $splitId.Matches.Groups[2].Value
                $studioIdIndex = ($rawStudioId | Select-String -Pattern '[1-9]').Matches.Index
                $studioId = ($rawStudioId[$studioIdIndex..($rawStudioId.Length - 1)] -join '').PadLeft(3, '0')

                $Id = "$($studioName.ToUpper())-$studioId"
            }
        }

        # The dump stores dvd_id without zero-padding (e.g. "ABF-309"), so
        # strip padding from the numeric suffix for the lookup. Callers may
        # pass "ABF-00343" or "ABF-343"; both normalize to "ABF-343".
        $lookupId = ($Id -replace '-0*(\d)', '-$1').ToUpper().Trim()

        $webRequest = $null

        if ($Source -ne 'html') {
            $webRequest = Get-R18DevDbRecord -DvdId $lookupId -DbPath $DbPath
        }

        if ($null -eq $webRequest -and $Source -ne 'dump') {
            # Primary live path: the plain-HTTP JSON API (fast, reliable with a
            # browser UA). This is what restores fresh titles the weekly dump
            # has not caught up to yet.
            Write-JVLog -Write:$script:JVLogWrite -LogPath $script:JVLogPath -WriteLevel $script:JVLogWriteLevel -Level Debug -Message "[$lookupId] [$($MyInvocation.MyCommand.Name)] not in cache; querying live r18.dev JSON API"
            try {
                $webRequest = Get-R18DevJsonRecord -Id $lookupId
            } catch {
                Write-JVLog -Write:$script:JVLogWrite -LogPath $script:JVLogPath -WriteLevel $script:JVLogWriteLevel -Level Warning -Message "[$lookupId] [$($MyInvocation.MyCommand.Name)] live r18.dev JSON fetch failed: $PSItem"
            }

            # Last resort: drive Chromium/Playwright if the direct request was
            # Cloudflare-blocked.
            if ($null -eq $webRequest -and (Get-Command Get-R18DevHtmlRecord -ErrorAction SilentlyContinue)) {
                Write-JVLog -Write:$script:JVLogWrite -LogPath $script:JVLogPath -WriteLevel $script:JVLogWriteLevel -Level Debug -Message "[$lookupId] [$($MyInvocation.MyCommand.Name)] direct JSON missed; trying Playwright fallback"
                try {
                    $webRequest = Get-R18DevHtmlRecord -Id $lookupId
                } catch {
                    Write-JVLog -Write:$script:JVLogWrite -LogPath $script:JVLogPath -WriteLevel $script:JVLogWriteLevel -Level Warning -Message "[$lookupId] [$($MyInvocation.MyCommand.Name)] live r18.dev fetch failed: $PSItem"
                }
            }
        }

        if ($null -eq $webRequest) {
            Write-JVLog -Write:$script:JVLogWrite -LogPath $script:JVLogPath -WriteLevel $script:JVLogWriteLevel -Level Warning -Message "[$Id] [$($MyInvocation.MyCommand.Name)] not matched on R18Dev"
            return
        }

        $resultId = Get-R18DevId -WebRequest $webRequest
        Write-JVLog -Write:$script:JVLogWrite -LogPath $script:JVLogPath -WriteLevel $script:JVLogWriteLevel -Level Debug -Message "[$Id] [$($MyInvocation.MyCommand.Name)] Result is [$resultId]"

        # Loose comparison: strip leading zeros from the numeric suffix and
        # uppercase. The dump/site sometimes returns dvd_id as "ABF-00343"
        # while callers pass "ABF-343" (or vice-versa); a strict -eq here
        # would silently drop legitimate hits.
        $normResult = ($resultId -replace '-0*(\d)', '-$1').ToUpper().Trim()
        if ($normResult -ne $lookupId) {
            Write-JVLog -Write:$script:JVLogWrite -LogPath $script:JVLogPath -WriteLevel $script:JVLogWriteLevel -Level Debug -Message "[$Id] [$($MyInvocation.MyCommand.Name)] R18Dev dvd_id [$resultId] (norm [$normResult]) does not match input (norm [$lookupId]); falling through"
            return
        }

        $contentId = Get-R18DevContentId -WebRequest $webRequest

        # Backstop: the content_id carries the true studio+number. Reject any
        # record whose number does not match the request -- catches r18.dev's
        # fuzzy dvd_id matches (MIDA-660 -> mida00066) on any path (dump, json,
        # html) even if the live repair in Get-R18DevJsonRecord did not apply.
        $reqNum = [regex]::Match($lookupId, '^[A-Za-z]+-0*(\d+)$')
        $cidNum = [regex]::Match([string]$contentId, '(\d+)$')
        if ($reqNum.Success -and $cidNum.Success -and [int]$reqNum.Groups[1].Value -ne [int]$cidNum.Groups[1].Value) {
            Write-JVLog -Write:$script:JVLogWrite -LogPath $script:JVLogPath -WriteLevel $script:JVLogWriteLevel -Level Debug -Message "[$Id] [$($MyInvocation.MyCommand.Name)] R18Dev content_id [$contentId] number does not match requested [$lookupId]; discarding"
            return
        }

        # Normalize the result id to Javinizer's standard 3-digit zero-padding
        # (matching Convert-JVTitle / Scraper.Dmm). r18.dev's dvd_id -- and the
        # zero-stripped lookup we inject on the live path -- drop the padding, so
        # without this NPJH-003 would sort as NPJH-3. Pad the numeric run up to 3
        # digits; never truncate longer numbers, and keep any trailing letter
        # suffix (e.g. -123R).
        if ($resultId -match '^(.+?)-0*(\d+)([A-Za-z]*)$') {
            $resultId = "$($Matches[1])-$($Matches[2].PadLeft(3, '0'))$($Matches[3])"
        }

        $resultObject = [PSCustomObject]@{
            Id       = $resultId
            Title    = Get-R18DevTitle -Webrequest $webRequest
            Url      = "https://r18.dev/videos/vod/movies/detail/-/combined=$contentId/json"
            Response = $webRequest
        }

        Write-Output $resultObject
    }
}

function Get-R18DevSource {
    <#
    .SYNOPSIS
        Read the configured r18.dev resolution mode.
    .DESCRIPTION
        Returns 'dump', 'dump+html' or 'html' from the
        'scraper.movie.r18dev.source' setting; defaults to 'dump+html'.
    #>
    [CmdletBinding()]
    param ()

    try {
        $settings = Get-JVSettings -ErrorAction SilentlyContinue
        $value = $settings.'scraper.movie.r18dev.source'
        if ($value -in @('dump', 'dump+html', 'html')) { return $value }
    } catch {}

    return 'dump+html'
}
