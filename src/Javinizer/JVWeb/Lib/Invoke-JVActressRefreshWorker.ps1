# Worker body for the actress-refresh background job. Lives in Lib/ so it's
# auto-loaded into every Pode runspace (and therefore is callable from route
# handlers via ${function:Invoke-JVActressRefreshWorker}).
#
# Runs inside the ThreadJob spawned by Start-JVJob. Has access to:
#   - Update-JVJobProgress, Add-JVJobLog, Test-JVActiveJobCancelled (Lib/Start-JVJob.ps1)
#   - Get-JVActressDataset, Save-JVActressDataset, Find-JVActress, Set-JVActressEntry (Lib)
#   - Find-XcityActressByName, Get-XcityActressDetail (Private/Scraper.Xcity.ps1)
#
# The xcity HTTP fetch loop runs via ForEach-Object -Parallel; each parallel
# runspace dot-sources Scraper.Xcity.ps1 once on entry (small cost per worker),
# uses its own WebRequestSession, and emits a result tuple that the parent
# merges into the dataset under a single Monitor lock.

function Invoke-JVActressRefreshWorker {
    param($ctx)

    $source          = "$($ctx.source)"
    $replaceExisting = [bool]$ctx.replaceExisting
    $names           = @($ctx.names)
    $parallelism     = if ($ctx.parallelism) { [int]$ctx.parallelism } else { 3 }
    if ($parallelism -lt 1)  { $parallelism = 1 }
    if ($parallelism -gt 16) { $parallelism = 16 }

    if ($source -eq 'jellyfin') {
        Update-JVJobProgress -Message 'fetching Jellyfin person list...'
        $url = "$($ctx.embyUrl.TrimEnd('/'))/emby/Persons/?api_key=$($ctx.embyApiKey)"
        $resp = Invoke-RestMethod -Method Get -Uri $url -TimeoutSec 30
        $rawNames = @($resp.Items | ForEach-Object { @{ name = $_.Name } })
        Add-JVJobLog "Jellyfin returned $($rawNames.Count) persons"

        # Deduplicate name-swap pairs ("Yuna Ogura" + "Ogura Yuna" → one entry).
        # Group by sorted-tokens; first member is the canonical search query,
        # the rest become aliases on the persisted entry.
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

    Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue
    $dataset = Get-JVActressDataset -Force

    # Pre-skip phase (sequential, in-memory). Filters out empty names and
    # already-populated entries before we hit the network in parallel.
    $stats = @{ added = 0; updated = 0; skipped = 0; notFound = 0; errors = @() }
    $needFetch = New-Object System.Collections.Generic.List[Object]
    foreach ($n in $names) {
        $romaji = "$($n.name)".Trim()
        if (-not $romaji) { $stats.skipped++; continue }
        if (-not $replaceExisting) {
            $existing = Find-JVActress -Name $romaji -JapaneseName $n.japaneseName -Aliases @($n.aliases) -Dataset $dataset
            if ($existing -and $existing.primaryUrl -and $existing.bio) {
                $stats.skipped++
                continue
            }
        }
        $needFetch.Add($n) | Out-Null
    }

    $tot = $needFetch.Count
    Update-JVJobProgress -Current 0 -Total $tot -Message "preparing $tot names (parallelism=$parallelism)"
    Add-JVJobLog "starting refresh: source=$source needFetch=$tot replace=$replaceExisting parallelism=$parallelism"

    if ($tot -eq 0) {
        Add-JVJobLog "nothing to fetch (all skipped or empty)"
        return $stats
    }

    # Resolve scraper path so each parallel runspace can dot-source it.
    $scraperPath = $null
    if ($env:JVWEB_LIB) {
        $candidate = Join-Path ((Get-Item $env:JVWEB_LIB).Parent.Parent.FullName) 'Private/Scraper.Xcity.ps1'
        if (Test-Path -LiteralPath $candidate) { $scraperPath = $candidate }
    }
    if (-not $scraperPath) {
        # Fallback: walk up from this file.
        $here = $PSScriptRoot
        if ($here) {
            $candidate = Join-Path ((Get-Item $here).Parent.Parent.FullName) 'Private/Scraper.Xcity.ps1'
            if (Test-Path -LiteralPath $candidate) { $scraperPath = $candidate }
        }
    }
    if (-not $scraperPath) {
        throw "Cannot locate Scraper.Xcity.ps1 — refresh cannot start."
    }

    # Shared accumulators for parallel work.
    $shared    = [hashtable]::Synchronized(@{ counter = 0 })
    $resultBag = [System.Collections.Concurrent.ConcurrentBag[Object]]::new()
    $errBag    = [System.Collections.Concurrent.ConcurrentBag[string]]::new()
    $statePath = $global:JVActiveJobStatePath
    $cancelPath = $global:JVActiveJobCancelPath

    $needFetch | ForEach-Object -ThrottleLimit $parallelism -Parallel {
        $n          = $_
        $sh         = $using:shared
        $rBag       = $using:resultBag
        $eBag       = $using:errBag
        $sp         = $using:statePath
        $cp         = $using:cancelPath
        $totCount   = $using:tot
        $scrPath    = $using:scraperPath

        if ($cp -and (Test-Path -LiteralPath $cp)) { return }

        # Each runspace dot-sources the scraper exactly once.
        . $scrPath
        Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue

        $romaji = "$($n.name)".Trim()
        $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
        $outcome = $null

        try {
            $hits = Find-XcityActressByName -Name $romaji -Session $session -MaxResults 3
            if (-not $hits -or $hits.Count -eq 0) {
                $outcome = @{
                    status       = 'notFound'
                    name         = $romaji
                    japaneseName = $n.japaneseName
                    aliases      = @($n.aliases)
                }
            } else {
                $top = $hits[0]
                $referer = "https://xxx.xcity.jp/idol/?q=$([System.Web.HttpUtility]::UrlEncode($romaji))"
                $detail = Get-XcityActressDetail -Id $top.Id -Session $session -Referer $referer

                $aliasUnion = (@($top.Aliases) + @($detail.Aliases) + @($n.aliases) | Where-Object { $_ } | Sort-Object -Unique)
                $outcome = @{
                    status       = 'matched'
                    queryName    = $romaji
                    japaneseName = $n.japaneseName
                    aliases      = @($aliasUnion)
                    detail       = $detail
                }
            }
        } catch {
            $eBag.Add("$romaji : $_")
            $outcome = $null
        }

        if ($outcome) { $rBag.Add($outcome) | Out-Null }

        # Bump counter + write progress to the job state file.
        [System.Threading.Monitor]::Enter($sh)
        try { $sh.counter = $sh.counter + 1; $cur = $sh.counter } finally { [System.Threading.Monitor]::Exit($sh) }
        if ($sp -and (Test-Path -LiteralPath $sp)) {
            try {
                $s = Get-Content -LiteralPath $sp -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
                if ($s) {
                    $s.progress.current = $cur
                    $s.progress.total   = $totCount
                    $s.progress.message = "fetching $romaji"
                    $tmp = "$sp.tmp"
                    [System.IO.File]::WriteAllText($tmp, ($s | ConvertTo-Json -Depth 12 -Compress), [System.Text.UTF8Encoding]::new($false))
                    Move-Item -LiteralPath $tmp -Destination $sp -Force
                }
            } catch {}
        }
    }

    # Sequential merge phase.
    Update-JVJobProgress -Message "merging $($resultBag.Count) results into dataset..."
    foreach ($r in $resultBag) {
        try {
            if ($r.status -eq 'matched') {
                $entry = [ordered]@{
                    name         = $r.detail.Name
                    japaneseName = $r.japaneseName
                    aliases      = @($r.aliases)
                    birthdate    = $r.detail.Birthdate
                    bloodType    = $r.detail.BloodType
                    birthCity    = $r.detail.BirthCity
                    height       = $r.detail.Height
                    measurements = $r.detail.Measurements
                    hobby        = $r.detail.Hobby
                    specialSkill = $r.detail.SpecialSkill
                    bio          = $r.detail.Bio
                    primaryUrl   = $r.detail.PrimaryUrl
                    xcityId      = $r.detail.Id
                    xcityUrl     = $r.detail.Url
                    lastFetched  = (Get-Date).ToString('o')
                }
                $existed = Find-JVActress -Name $r.detail.Name -JapaneseName $r.japaneseName -Aliases $r.aliases -Dataset $dataset
                Set-JVActressEntry -Dataset $dataset -Entry $entry
                if ($existed) { $stats.updated++ } else { $stats.added++ }
            } elseif ($r.status -eq 'notFound') {
                $stub = Find-JVActress -Name $r.name -JapaneseName $r.japaneseName -Aliases $r.aliases -Dataset $dataset
                if (-not $stub) {
                    $stubEntry = [ordered]@{
                        name         = $r.name
                        japaneseName = $r.japaneseName
                        aliases      = @($r.aliases)
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
                    $stats.added++
                }
                $stats.notFound++
            }
        } catch {
            $stats.errors += "merge: $_"
        }
    }

    foreach ($e in $errBag) { $stats.errors += $e }
    Save-JVActressDataset -Dataset $dataset | Out-Null

    Add-JVJobLog "done: added=$($stats.added) updated=$($stats.updated) skipped=$($stats.skipped) notFound=$($stats.notFound) errors=$($stats.errors.Count)"
    return $stats
}
