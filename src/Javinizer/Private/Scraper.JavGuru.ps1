# Field extractors for the jav.guru scraper. jav.guru is a WordPress site whose
# movie pages render a simple info list (Code, Release Date, Studio, Label,
# Director, Category, Tags, Actress) plus an English machine-translated title
# and a re-hosted DMM cover. Parsed with regex + Convert-HtmlCharacter, the
# same approach as Scraper.Javdb.ps1.

function Get-JavGuruInfoField {
    # Pull a single "<li> Label: </strong> value </li>" value as clean text.
    param (
        [Parameter(Mandatory)][String]$Content,
        [Parameter(Mandatory)][String]$Label
    )
    $m = [regex]::Match($Content, "$([regex]::Escape($Label))\s*:?\s*</(?:strong|span|b)>(.*?)</li>",
        [System.Text.RegularExpressions.RegexOptions]::Singleline -bor [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $m.Success) { return }
    $text = $m.Groups[1].Value -replace '<[^>]+>', ' '
    $text = Convert-HtmlCharacter -String ($text -replace '\s+', ' ')
    if ([string]::IsNullOrWhiteSpace($text)) { return }
    Write-Output $text.Trim()
}

function Get-JavGuruInfoLinks {
    # Pull the <a>…</a> texts from a "<li> Label: </strong> … </li>" segment.
    param (
        [Parameter(Mandatory)][String]$Content,
        [Parameter(Mandatory)][String]$Label
    )
    $m = [regex]::Match($Content, "$([regex]::Escape($Label))\s*:?\s*</(?:strong|span|b)>(.*?)</li>",
        [System.Text.RegularExpressions.RegexOptions]::Singleline -bor [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $m.Success) { return }
    $links = [regex]::Matches($m.Groups[1].Value, '<a[^>]*>([^<]+)</a>')
    $values = foreach ($l in $links) {
        $v = Convert-HtmlCharacter -String $l.Groups[1].Value
        if ($v) { $v.Trim() }
    }
    Write-Output ([array]$values)
}

function Get-JavGuruId {
    param ([Parameter(Mandatory, ValueFromPipeline)][Object]$Webrequest)
    process { Get-JavGuruInfoField -Content $Webrequest.Content -Label 'Code' }
}

function Get-JavGuruTitle {
    param ([Parameter(Mandatory, ValueFromPipeline)][Object]$Webrequest)
    process {
        $m = [regex]::Match($Webrequest.Content, '<h1[^>]*class="titl"[^>]*>(.*?)</h1>',
            [System.Text.RegularExpressions.RegexOptions]::Singleline -bor [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if (-not $m.Success) { return }
        $title = $m.Groups[1].Value -replace '<[^>]+>', ''
        # Strip the leading "[ABF-343-MR] " code prefix jav.guru prepends.
        $title = $title -replace '^\s*\[[^\]]+\]\s*', ''
        $title = Convert-HtmlCharacter -String $title
        if ($title) { Write-Output $title.Trim() }
    }
}

function Get-JavGuruReleaseDate {
    param ([Parameter(Mandatory, ValueFromPipeline)][Object]$Webrequest)
    process {
        $date = Get-JavGuruInfoField -Content $Webrequest.Content -Label 'Release Date'
        if ($date) { Write-Output (($date -split ' ')[0]) }
    }
}

function Get-JavGuruReleaseYear {
    param ([Parameter(Mandatory, ValueFromPipeline)][Object]$Webrequest)
    process {
        $date = Get-JavGuruReleaseDate -Webrequest $Webrequest
        if ($date) { Write-Output (($date -split '-')[0]) }
    }
}

function Get-JavGuruDirector {
    param ([Parameter(Mandatory, ValueFromPipeline)][Object]$Webrequest)
    process { Get-JavGuruInfoField -Content $Webrequest.Content -Label 'Director' }
}

function Get-JavGuruMaker {
    # jav.guru's "Studio" is the production maker in Javinizer terms.
    param ([Parameter(Mandatory, ValueFromPipeline)][Object]$Webrequest)
    process { Get-JavGuruInfoField -Content $Webrequest.Content -Label 'Studio' }
}

function Get-JavGuruLabel {
    param ([Parameter(Mandatory, ValueFromPipeline)][Object]$Webrequest)
    process { Get-JavGuruInfoField -Content $Webrequest.Content -Label 'Label' }
}

function Get-JavGuruGenre {
    # The meaningful genres live in "Tags"; "Category" is mostly quality
    # markers (1080p, HD, Decensored).
    param ([Parameter(Mandatory, ValueFromPipeline)][Object]$Webrequest)
    process {
        $genres = Get-JavGuruInfoLinks -Content $Webrequest.Content -Label 'Tags'
        if ($genres -and $genres.Count -gt 0) { Write-Output ([array]$genres) }
    }
}

function Get-JavGuruActress {
    param ([Parameter(Mandatory, ValueFromPipeline)][Object]$Webrequest)
    process {
        $names = Get-JavGuruInfoLinks -Content $Webrequest.Content -Label 'Actress'
        if (-not $names -or $names.Count -lt 1) { return }
        $actresses = foreach ($name in $names) {
            $parts = $name -split '\s+'
            # jav.guru renders romaji as "Surname Given".
            $last = $parts[0]
            $first = if ($parts.Count -gt 1) { ($parts[1..($parts.Count - 1)] -join ' ') } else { '' }
            [PSCustomObject]@{
                LastName     = $last
                FirstName    = $first
                JapaneseName = $null
                ThumbUrl     = $null
            }
        }
        Write-Output ([array]$actresses)
    }
}

function Get-JavGuruCoverUrl {
    param ([Parameter(Mandatory, ValueFromPipeline)][Object]$Webrequest)
    process {
        # jav.guru re-hosts the DMM poster on its own CDN, e.g.
        # https://cdn.javmiku.com/wp-content/uploads/2026/04/118abf343pl.jpg —
        # but that CDN 403s on hotlink/download, so the poster fails to load.
        # The filename embeds the DMM content_id (118abf343), so rebuild the
        # direct DMM poster URL, which serves reliably (and is the large `pl`
        # variant). The "p[ls]" suffix avoids the site logo / sidebar
        # thumbnails. WordPress appends a "-1", "-2", … dedup suffix when a
        # filename collides (e.g. snos239pl-1.jpg), so allow an optional
        # "-<n>" before the extension — without it those posters were missed.
        $m = [regex]::Match($Webrequest.Content,
            '/wp-content/uploads/\d{4}/\d{2}/([a-z0-9]+)p[ls](?:-\d+)?\.jpg',
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($m.Success) {
            $contentId = $m.Groups[1].Value.ToLower()
            # DMM hosts covers in two separate trees and any given title lives in
            # exactly one: physical/"mono" goods under mono/movie/adult, digital
            # releases under digital/video. Guessing wrong returns a 302 to a tiny
            # "now printing" placeholder (the blank poster users saw). Probe and
            # emit whichever tree serves a real image. Digital-only labels
            # (FALENO/FNS, gravure OAE) live under digital/video; mainstream DVDs
            # (SSIS/STARS/ABF) under mono -- so try digital first, then mono.
            foreach ($url in @(
                    "https://pics.dmm.co.jp/digital/video/$contentId/${contentId}pl.jpg",
                    "https://pics.dmm.co.jp/mono/movie/adult/$contentId/${contentId}pl.jpg")) {
                if (Test-JVDmmImageUrl -Uri $url) {
                    Write-Output $url
                    return
                }
            }
            # Neither tree has the cover yet (genuinely not published); fall
            # through to the Open Graph image below.
        }

        # Fallback: Open Graph image.
        $og = [regex]::Match($Webrequest.Content,
            '<meta[^>]+property="og:image"[^>]+content="([^"]+)"',
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($og.Success -and $og.Groups[1].Value) { Write-Output $og.Groups[1].Value }
    }
}

function Test-JVDmmImageUrl {
    <#
    .SYNOPSIS
        True only when the URL serves a real image (HTTP 200).
    .DESCRIPTION
        DMM answers a wrong-tree or not-yet-published cover with a 302 redirect
        to a tiny "now printing" placeholder. A HEAD with redirects disabled
        returns 200 for a real image and throws/!=200 for the placeholder, so a
        302 (or any error/timeout) is treated as a miss.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][String]$Uri)
    try {
        $resp = Invoke-WebRequest -Uri $Uri -Method Head -MaximumRedirection 0 `
            -TimeoutSec 10 -SkipHttpErrorCheck -ErrorAction Stop -Verbose:$false
        return ($resp.StatusCode -eq 200)
    } catch {
        return $false
    }
}
