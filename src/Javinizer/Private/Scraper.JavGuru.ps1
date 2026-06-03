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
        # The DMM poster re-hosted on jav.guru's CDN, e.g.
        # https://cdn.javmiku.com/wp-content/uploads/2026/04/118abf343pl.jpg
        # Require the DMM poster suffix (pl/ps.jpg) so we don't grab the site
        # logo or sidebar thumbnails.
        $m = [regex]::Match($Webrequest.Content,
            '(?:src|data-src|data-lazy-src)="(https://[^"]+/wp-content/uploads/\d{4}/\d{2}/[^"]*p[ls]\.jpg)"',
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($m.Success) {
            # Prefer the large poster.
            Write-Output ($m.Groups[1].Value -replace 'ps\.jpg$', 'pl.jpg')
            return
        }

        # Fallback: Open Graph image.
        $og = [regex]::Match($Webrequest.Content,
            '<meta[^>]+property="og:image"[^>]+content="([^"]+)"',
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($og.Success -and $og.Groups[1].Value) { Write-Output $og.Groups[1].Value }
    }
}
