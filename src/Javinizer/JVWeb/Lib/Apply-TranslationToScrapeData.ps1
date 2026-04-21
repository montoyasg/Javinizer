function Apply-TranslationToScrapeData {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Data,

        [Parameter(Mandatory = $true)]
        $Settings
    )

    if (-not $Data) { return $Data }
    if (-not $Settings.'sort.metadata.nfo.translate') { return $Data }

    $module = $Settings.'sort.metadata.nfo.translate.module'
    $language = $Settings.'sort.metadata.nfo.translate.language'
    $rawFields = $Settings.'sort.metadata.nfo.translate.field'
    $deeplKey = $Settings.'sort.metadata.nfo.translate.deeplapikey'

    if (-not $module -or -not $language) { return $Data }

    $fields = @()
    if ($rawFields -is [array]) {
        $fields = $rawFields
    } elseif ($rawFields -is [string] -and $rawFields -ne '') {
        $fields = $rawFields -split '[,\s]+' | Where-Object { $_ -ne '' }
    }
    if ($fields.Count -eq 0) { return $Data }

    # Scraper fields are capitalized (Title, Description, Series, Maker, Genre).
    # Settings conventionally store them lowercase. Match case-insensitively by
    # mapping the configured name to the actual property name on $Data.
    $props = @{}
    foreach ($p in $Data.PSObject.Properties.Name) { $props[$p.ToLowerInvariant()] = $p }

    foreach ($f in $fields) {
        $key = $f.ToString().ToLowerInvariant()
        if (-not $props.ContainsKey($key)) { continue }
        $propName = $props[$key]
        $orig = $Data.$propName
        if ($null -eq $orig) { continue }
        if ($orig -is [string] -and $orig.Trim() -eq '') { continue }

        try {
            if ($key -eq 'genre' -and $orig -is [System.Collections.IEnumerable] -and -not ($orig -is [string])) {
                $joined = ($orig -join '|')
                if ([string]::IsNullOrWhiteSpace($joined)) { continue }
                $t = Get-TranslatedString -String $joined -Language $language -Module $module -TranslateDeeplApiKey $deeplKey
                if ($t) {
                    $Data.$propName = @($t -split '\|' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
                }
            } elseif ($key -eq 'actress' -and $orig -is [System.Collections.IEnumerable] -and -not ($orig -is [string])) {
                # Translate each actress's JapaneseName in place (scraper fields retain everything else)
                foreach ($act in $orig) {
                    if ($null -eq $act) { continue }
                    if ($act.PSObject.Properties.Name -notcontains 'JapaneseName') { continue }
                    $jn = $act.JapaneseName
                    if ([string]::IsNullOrWhiteSpace($jn)) { continue }
                    $t = Get-TranslatedString -String $jn -Language $language -Module $module -TranslateDeeplApiKey $deeplKey
                    if ($t -and ($t -is [string]) -and $t.Trim() -ne '' -and $t.Trim() -ne $jn) {
                        $act.JapaneseName = $t.Trim()
                    }
                }
            } elseif ($orig -is [string]) {
                $t = Get-TranslatedString -String $orig -Language $language -Module $module -TranslateDeeplApiKey $deeplKey
                if ($t -and ($t -is [string]) -and $t.Trim() -ne '') {
                    $Data.$propName = $t.Trim()
                }
            }
        } catch {
            Write-PodeHost "translation failed for field '$propName': $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    return $Data
}
