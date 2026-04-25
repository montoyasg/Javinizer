# Worker body for the actress-refresh background job. Lives in Lib/ so it's
# auto-loaded into every Pode runspace (and therefore is callable from route
# handlers via ${function:Invoke-JVActressRefreshWorker}).
#
# Runs inside the ThreadJob spawned by Start-JVJob. Has access to:
#   - Update-JVJobProgress, Add-JVJobLog, Test-JVActiveJobCancelled (defined in Start-JVJob worker)
#   - Get-JVActressDataset, Save-JVActressDataset, Find-JVActress, Set-JVActressEntry (Lib)
#   - Find-XcityActressByName, Get-XcityActressDetail (Private/Scraper.Xcity.ps1)

function Invoke-JVActressRefreshWorker {
    param($ctx)

    $source          = "$($ctx.source)"
    $replaceExisting = [bool]$ctx.replaceExisting
    $names           = @($ctx.names)

    if ($source -eq 'jellyfin') {
        Update-JVJobProgress -Message 'fetching Jellyfin person list...'
        $url = "$($ctx.embyUrl.TrimEnd('/'))/emby/Persons/?api_key=$($ctx.embyApiKey)"
        $resp = Invoke-RestMethod -Method Get -Uri $url -TimeoutSec 30
        $rawNames = @($resp.Items | ForEach-Object { @{ name = $_.Name } })
        Add-JVJobLog "Jellyfin returned $($rawNames.Count) persons"

        # Deduplicate name-swap pairs ("Yuna Ogura" + "Ogura Yuna" → one entry).
        # Group by sorted-tokens; the first member of each group is the canonical
        # search query, the rest become aliases that get persisted alongside it.
        $groups = @{}
        foreach ($r in $rawNames) {
            $tokens = ($r.name -split '\s+' | Where-Object { $_ })
            if ($tokens.Count -eq 2) {
                $key = ($tokens | Sort-Object) -join ' '
            } else {
                $key = $r.name.ToLowerInvariant()
            }
            if (-not $groups.ContainsKey($key)) { $groups[$key] = @() }
            $groups[$key] += $r.name
        }
        $deduped = New-Object System.Collections.Generic.List[Object]
        $dupePairs = 0
        foreach ($kv in $groups.GetEnumerator()) {
            if ($kv.Value.Count -gt 1) { $dupePairs++ }
            $first = $kv.Value[0]
            $aliases = if ($kv.Value.Count -gt 1) { @($kv.Value[1..($kv.Value.Count - 1)]) } else { @() }
            $deduped.Add(@{ name = $first; aliases = $aliases }) | Out-Null
        }
        $names = $deduped.ToArray()
        if ($dupePairs -gt 0) {
            Add-JVJobLog "deduped $dupePairs name-swap pair(s); processing $($names.Count) canonical names"
        }
    }

    $total = $names.Count
    Update-JVJobProgress -Current 0 -Total $total -Message "preparing $total names"
    Add-JVJobLog "starting refresh: source=$source count=$total replace=$replaceExisting"

    Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue
    $dataset = Get-JVActressDataset -Force
    $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession

    $stats = @{ added = 0; updated = 0; skipped = 0; notFound = 0; errors = @() }
    $sinceLastSave = 0

    for ($i = 0; $i -lt $names.Count; $i++) {
        if (Test-JVActiveJobCancelled) {
            Add-JVJobLog 'cancellation requested — stopping'
            break
        }

        $n = $names[$i]
        $romaji = "$($n.name)".Trim()
        if (-not $romaji) {
            $stats.skipped++
            Update-JVJobProgress -Current ($i + 1) -Message "skipped (empty name)"
            continue
        }

        if (-not $replaceExisting) {
            $existing = Find-JVActress -Name $romaji -JapaneseName $n.japaneseName -Aliases @($n.aliases) -Dataset $dataset
            if ($existing -and $existing.primaryUrl -and $existing.bio) {
                $stats.skipped++
                Update-JVJobProgress -Current ($i + 1) -Message "skip $romaji (already populated)"
                continue
            }
        }

        Update-JVJobProgress -Current ($i + 1) -Message "fetching $romaji"
        try {
            $hits = Find-XcityActressByName -Name $romaji -Session $session -MaxResults 3
            if (-not $hits -or $hits.Count -eq 0) {
                # Save a stub so the actress still appears in the Library and
                # can be synced to Jellyfin (without enrichment). Skip if a
                # real entry already exists for the same name.
                $stub = Find-JVActress -Name $romaji -JapaneseName $n.japaneseName -Aliases @($n.aliases) -Dataset $dataset
                if (-not $stub) {
                    $stubEntry = [ordered]@{
                        name         = $romaji
                        japaneseName = $n.japaneseName
                        aliases      = @($n.aliases)
                        birthdate    = $null
                        bloodType    = $null
                        birthCity    = $null
                        height       = $null
                        measurements = $null
                        hobby        = $null
                        specialSkill = $null
                        bio          = $null
                        primaryUrl   = $null
                        xcityId      = $null
                        xcityUrl     = $null
                        lastFetched  = (Get-Date).ToString('o')
                    }
                    Set-JVActressEntry -Dataset $dataset -Entry $stubEntry
                    $sinceLastSave++
                    $stats.added++
                }
                $stats.notFound++
                Add-JVJobLog "no xcity match (stub saved): $romaji"
                continue
            }
            $top = $hits[0]
            $referer = "https://xxx.xcity.jp/idol/?q=$([System.Web.HttpUtility]::UrlEncode($romaji))"
            $detail = Get-XcityActressDetail -Id $top.Id -Session $session -Referer $referer

            $aliasUnion = (@($top.Aliases) + @($detail.Aliases) + @($n.aliases) | Where-Object { $_ } | Sort-Object -Unique)

            $entry = [ordered]@{
                name         = $detail.Name
                japaneseName = $n.japaneseName
                aliases      = @($aliasUnion)
                birthdate    = $detail.Birthdate
                bloodType    = $detail.BloodType
                birthCity    = $detail.BirthCity
                height       = $detail.Height
                measurements = $detail.Measurements
                hobby        = $detail.Hobby
                specialSkill = $detail.SpecialSkill
                bio          = $detail.Bio
                primaryUrl   = $detail.PrimaryUrl
                xcityId      = $detail.Id
                xcityUrl     = $detail.Url
                lastFetched  = (Get-Date).ToString('o')
            }

            $existed = Find-JVActress -Name $detail.Name -JapaneseName $n.japaneseName -Aliases $aliasUnion -Dataset $dataset
            Set-JVActressEntry -Dataset $dataset -Entry $entry
            if ($existed) { $stats.updated++ } else { $stats.added++ }
            $sinceLastSave++

            if ($sinceLastSave -ge 10) {
                Save-JVActressDataset -Dataset $dataset | Out-Null
                $sinceLastSave = 0
            }
        } catch {
            $stats.errors += "$romaji : $_"
            Add-JVJobLog "ERROR $romaji : $_"
        }
    }

    if ($sinceLastSave -gt 0) {
        Save-JVActressDataset -Dataset $dataset | Out-Null
    }

    Add-JVJobLog "done: added=$($stats.added) updated=$($stats.updated) skipped=$($stats.skipped) notFound=$($stats.notFound) errors=$($stats.errors.Count)"
    return $stats
}
