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

    # xcity-side parallelism (Phase C). Aliases: new key, falls back to legacy.
    $xcityParallelism = if ($ctx.xcityParallelism) { [int]$ctx.xcityParallelism }
                        elseif ($ctx.parallelism)  { [int]$ctx.parallelism }
                        else { 3 }
    if ($xcityParallelism -lt 1)  { $xcityParallelism = 1 }
    if ($xcityParallelism -gt 16) { $xcityParallelism = 16 }
    $parallelism = $xcityParallelism  # legacy alias used in log lines below

    # Jellyfin-side parallelism (Phase B). Higher because it's local network.
    $jellyfinParallelism = if ($ctx.jellyfinParallelism) { [int]$ctx.jellyfinParallelism } else { 8 }
    if ($jellyfinParallelism -lt 1)  { $jellyfinParallelism = 1 }
    if ($jellyfinParallelism -gt 32) { $jellyfinParallelism = 32 }

    # Promote-from-Jellyfin toggle. Default ON when source='jellyfin' and the
    # caller didn't say otherwise. The route's $arguments hashtable always
    # includes the key, so falsy = explicitly disabled.
    $useJellyfin = if ($ctx.PSObject.Properties.Name -contains 'useJellyfin') {
        [bool]$ctx.useJellyfin
    } elseif ($ctx -is [System.Collections.IDictionary] -and $ctx.Contains('useJellyfin')) {
        [bool]$ctx.useJellyfin
    } else {
        $true
    }

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

    $stats = @{ added = 0; updated = 0; skipped = 0; promoted = 0; notFound = 0; errors = @() }

    # ── Phase B: promote whatever Jellyfin already has ────────────────────────
    # Per-actress GET to /Users/{userId}/Items/{personId}, project to a local
    # entry, save when bio + birthdate are both present. Captured names skip
    # Phase C's xcity round-trip entirely. Off = today's pure-xcity behavior.
    $preCaptured = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

    if ($source -eq 'jellyfin' -and $useJellyfin) {
        Update-JVJobProgress -Message "phase B: fetching Jellyfin metadata (parallelism=$jellyfinParallelism)..."
        Add-JVJobLog "phase B start: useJellyfin=true jellyfinParallelism=$jellyfinParallelism"

        $userId = Resolve-JVJellyfinUserId -Url $ctx.embyUrl -ApiKey $ctx.embyApiKey
        if (-not $userId) {
            Add-JVJobLog "WARN: couldn't resolve Jellyfin userId; skipping Phase B"
        } else {
            # Bulk fetch of /Persons/ (basic fields), then per-person GETs for
            # the rich payload (Overview, PremiereDate, AlternateNames). Bulk
            # gives us the Jellyfin person IDs to drive the per-person calls.
            $personsBasic = Get-JVJellyfinPersons -Url $ctx.embyUrl -ApiKey $ctx.embyApiKey
            $byName = @{}
            foreach ($p in $personsBasic) { if ($p.Name) { $byName[$p.Name] = $p } }

            # Match canonical names from the dedup phase to Jellyfin person IDs.
            # When name-swap dedup picked "Yuna Ogura" as canonical but the
            # Jellyfin person is recorded as "Ogura Yuna", look up by alias too.
            $tasks = New-Object System.Collections.Generic.List[Object]
            foreach ($n in $names) {
                $jp = $byName[$n.name]
                if (-not $jp) {
                    foreach ($a in @($n.aliases)) {
                        if ($byName.ContainsKey($a)) { $jp = $byName[$a]; break }
                    }
                }
                if ($jp) {
                    $tasks.Add(@{ Canonical = $n; PersonId = $jp.Id; ImageTags = $jp.ImageTags }) | Out-Null
                }
            }

            $jobStatePath = $global:JVActiveJobStatePath
            $promotedBag  = [System.Collections.Concurrent.ConcurrentBag[Object]]::new()
            $shared       = [hashtable]::Synchronized(@{ counter = 0 })
            $ttl          = $tasks.Count

            $libDir = $env:JVWEB_LIB
            if (-not $libDir -and $PSScriptRoot) { $libDir = $PSScriptRoot }

            Update-JVJobProgress -Current 0 -Total $ttl -Message "phase B: fetching $ttl person items"

            $tasks | ForEach-Object -ThrottleLimit $jellyfinParallelism -Parallel {
                $task   = $_
                $sh     = $using:shared
                $bag    = $using:promotedBag
                $sp     = $using:jobStatePath
                $totC   = $using:ttl
                $libD   = $using:libDir
                $url    = $using:ctx.embyUrl
                $key    = $using:ctx.embyApiKey
                $uid    = $using:userId

                # Dot-source helpers needed in this fresh runspace.
                if ($libD) {
                    foreach ($f in @('Get-JVJellyfinClient.ps1')) {
                        $p = Join-Path $libD $f
                        if (Test-Path -LiteralPath $p) { . $p }
                    }
                }

                $full = Get-JVJellyfinPersonFull -Url $url -ApiKey $key -UserId $uid -PersonId $task.PersonId
                if ($full) {
                    $aliasesAll = @($task.Canonical.aliases) | Where-Object { $_ }
                    $entry = ConvertFrom-JVJellyfinPersonItem -Person $full -AdditionalAliases $aliasesAll
                    # Inline a Jellyfin image URL when the server has one AND
                    # the image is actually fetchable. ImageTags.Primary lies
                    # sometimes — the metadata says an image exists but the
                    # underlying byte stream is missing/corrupt and Jellyfin
                    # returns 500 on GET. A cheap HEAD catches this; on
                    # failure we leave primaryUrl null so Phase C will pull
                    # a fresh photo from xcity.
                    $hasImg = $false
                    try { $hasImg = ([bool]$task.ImageTags.Primary -or [bool]$task.ImageTags.Thumb) } catch {}

                    $imgOk  = $false
                    $imgUrl = $null
                    if ($hasImg) {
                        $imgUrl = "$($url.TrimEnd('/'))/emby/Items/$($task.PersonId)/Images/Primary?api_key=$key"
                        try {
                            $r = Invoke-WebRequest -Uri $imgUrl -Method Head -TimeoutSec 5 -UseBasicParsing -ErrorAction Stop
                            $imgOk = ($r.StatusCode -ge 200 -and $r.StatusCode -lt 300)
                        } catch {
                            # 500 / connection refused / timeout → leave $imgOk = $false
                        }
                    }
                    if ($imgOk) {
                        $entry.primaryUrl = $imgUrl
                    }
                    # JapaneseName isn't a Jellyfin concept; carry the caller's
                    # value forward if they passed one.
                    if ($task.Canonical.japaneseName -and -not $entry.japaneseName) {
                        $entry.japaneseName = $task.Canonical.japaneseName
                    }
                    $bag.Add(@{
                        Name         = "$($task.Canonical.name)"
                        Entry        = $entry
                        HasBio       = [bool]$entry.bio
                        HasBday      = [bool]$entry.birthdate
                        HasGoodImage = $imgOk
                        ClaimedImage = $hasImg
                    }) | Out-Null
                }

                # Progress
                [System.Threading.Monitor]::Enter($sh)
                try { $sh.counter = $sh.counter + 1; $cur = $sh.counter } finally { [System.Threading.Monitor]::Exit($sh) }
                if ($sp -and (Test-Path -LiteralPath $sp)) {
                    try {
                        $s = Get-Content -LiteralPath $sp -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
                        if ($s) {
                            if ($s.progress.current -ne $cur) {
                                $s.progress.updatedAt = (Get-Date).ToUniversalTime().ToString('o')
                            }
                            $s.progress.current = $cur
                            $s.progress.total   = $totC
                            $s.progress.message = "phase B: promoting $($task.Canonical.name)"
                            $tmp = "$sp.tmp"
                            [System.IO.File]::WriteAllText($tmp, ($s | ConvertTo-Json -Depth 12 -Compress), [System.Text.UTF8Encoding]::new($false))
                            Move-Item -LiteralPath $tmp -Destination $sp -Force
                        }
                    } catch {}
                }
            }

            # Sequential merge: save entries with bio + birthdate. An entry
            # only "captures" (skips Phase C) when its Jellyfin image was
            # also confirmed fetchable — otherwise we keep Jellyfin's bio/
            # birthdate but route it to Phase C so xcity can supply a real
            # photo (and any richer fields it has).
            $brokenImage = 0
            foreach ($r in $promotedBag) {
                if (-not ($r.HasBio -and $r.HasBday)) { continue }
                $entry = $r.Entry
                $entry.lastFetched = (Get-Date).ToString('o')
                # Strip internal markers before persisting.
                if ($entry.Contains('jellyfinPersonId')) { $entry.Remove('jellyfinPersonId') | Out-Null }
                if ($entry.Contains('jellyfinHasImage')) { $entry.Remove('jellyfinHasImage') | Out-Null }

                $existed = Find-JVActress -Name $entry.name -Dataset $dataset
                Set-JVActressEntry -Dataset $dataset -Entry $entry
                if ($existed) { $stats.updated++ } else { $stats.added++ }
                $stats.promoted++

                if ($r.HasGoodImage) {
                    [void]$preCaptured.Add($r.Name)
                } else {
                    # Only count as "broken" when Jellyfin claimed the image
                    # existed but HEAD failed; entries with no image at all
                    # were always going to need xcity, that's not new.
                    if ($r.ClaimedImage) { $brokenImage++ }
                }
            }
            Save-JVActressDataset -Dataset $dataset | Out-Null
            $partialMeta = $promotedBag.Count - $stats.promoted
            Add-JVJobLog "phase B done: promoted=$($stats.promoted) (will skip xcity for these); $partialMeta had partial Jellyfin metadata and need xcity; $brokenImage had broken Jellyfin images → routed to xcity"
        }
    }

    # Pre-skip phase (sequential, in-memory). Filters out empty names,
    # already-populated entries, and Phase-B-captured names.
    $needFetch = New-Object System.Collections.Generic.List[Object]
    $emptyDropped = 0
    foreach ($n in $names) {
        $romaji = "$($n.name)".Trim()
        if (-not $romaji) { $stats.skipped++; $emptyDropped++; continue }
        if ($preCaptured.Contains($romaji)) { continue }
        if (-not $replaceExisting) {
            $existing = Find-JVActress -Name $romaji -JapaneseName $n.japaneseName -Aliases @($n.aliases) -Dataset $dataset
            if ($existing -and $existing.primaryUrl -and $existing.bio) {
                $stats.skipped++
                continue
            }
        }
        $needFetch.Add($n) | Out-Null
    }

    if ($emptyDropped -gt 0) {
        Add-JVJobLog "dropped $emptyDropped empty/whitespace name$(if ($emptyDropped -eq 1) {''} else {'s'}) at pre-skip"
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

    # Streaming Phase C: each runspace returns its result via the pipeline; a
    # serial trailing ForEach-Object owns the canonical dataset, merges each
    # match, calls Update-JVJobProgress, and saves on a debounced cadence
    # (every 10 saves OR every 30s). Survives kill/cancel mid-run because
    # work commits to disk continuously instead of only at the end.
    $cancelPath = $global:JVActiveJobCancelPath
    $errBag     = [System.Collections.Concurrent.ConcurrentBag[string]]::new()

    $batchSize    = 10
    $batchSeconds = 30
    $savedSince   = 0
    $lastSaveAt   = [DateTime]::UtcNow
    $done         = 0

    $needFetch | ForEach-Object -ThrottleLimit $parallelism -Parallel {
        $n       = $_
        $cp      = $using:cancelPath
        $scrPath = $using:scraperPath

        $romaji = "$($n.name)".Trim()
        if ($cp -and (Test-Path -LiteralPath $cp)) {
            return [pscustomobject]@{ status='cancelled'; name=$romaji; logLines=@() }
        }

        # Each runspace dot-sources the scraper exactly once.
        . $scrPath
        Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue

        # Per-runspace backoff log buffer; Invoke-XcityRequest appends to this
        # when honoring Retry-After / falling back to the schedule. Drained
        # below into the result so the serial consumer can write to job log.
        $script:XcityBackoffLog = New-Object System.Collections.Generic.List[string]

        $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession

        try {
            # Fuzzy = try romaji variants (macron/double-vowel/token-swap) and
            # filter candidate hits by Test-XcityNameMatch. If still no match,
            # also try each known alias before giving up.
            $hits = Find-XcityActressByName -Name $romaji -Session $session -MaxResults 3 -Fuzzy
            if ((-not $hits -or $hits.Count -eq 0) -and $n.aliases) {
                foreach ($alt in @($n.aliases)) {
                    if (-not $alt) { continue }
                    $hits = Find-XcityActressByName -Name $alt -Session $session -MaxResults 3 -Fuzzy
                    if ($hits -and $hits.Count -gt 0) { break }
                }
            }
            if (-not $hits -or $hits.Count -eq 0) {
                [pscustomobject]@{
                    status   = 'notFound'
                    name     = $romaji
                    logLines = @($script:XcityBackoffLog)
                }
            } else {
                $top = $hits[0]
                $referer = "https://xxx.xcity.jp/idol/?q=$([System.Web.HttpUtility]::UrlEncode($romaji))"
                $detail = Get-XcityActressDetail -Id $top.Id -Session $session -Referer $referer

                $aliasUnion = (@($top.Aliases) + @($detail.Aliases) + @($n.aliases) | Where-Object { $_ } | Sort-Object -Unique)
                [pscustomobject]@{
                    status       = 'matched'
                    name         = $romaji
                    japaneseName = $n.japaneseName
                    aliases      = @($aliasUnion)
                    detail       = $detail
                    logLines     = @($script:XcityBackoffLog)
                }
            }
        } catch {
            [pscustomobject]@{
                status   = 'error'
                name     = $romaji
                error    = "$_"
                logLines = @($script:XcityBackoffLog)
            }
        }
    } | ForEach-Object {
        $r = $_
        $done++

        try {
            switch ($r.status) {
                'matched' {
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
                    $savedSince++
                }
                'notFound' {
                    $stats.notFound++
                    Add-JVJobLog "no xcity match: $($r.name)"
                }
                'error' {
                    $errBag.Add("$($r.name) : $($r.error)") | Out-Null
                }
                'cancelled' { }
            }
        } catch {
            $stats.errors += "merge $($r.name): $_"
        }

        # Surface backoff/Retry-After messages from the runspace into the job log.
        foreach ($line in @($r.logLines)) {
            if ($line) { Add-JVJobLog $line }
        }

        Update-JVJobProgress -Current $done -Total $tot -Message "fetching $($r.name)"

        $now = [DateTime]::UtcNow
        if ($savedSince -ge $batchSize -or ($now - $lastSaveAt).TotalSeconds -ge $batchSeconds) {
            try {
                Save-JVActressDataset -Dataset $dataset | Out-Null
                Add-JVJobLog "checkpoint saved (added=$($stats.added) updated=$($stats.updated))"
            } catch {
                Add-JVJobLog "WARN: checkpoint save failed: $_"
            }
            $savedSince = 0
            $lastSaveAt = $now
        }
    }

    foreach ($e in $errBag) { $stats.errors += $e }
    # Final flush so any pending entries since the last checkpoint reach disk.
    Save-JVActressDataset -Dataset $dataset | Out-Null

    Add-JVJobLog "done: added=$($stats.added) updated=$($stats.updated) skipped=$($stats.skipped) notFound=$($stats.notFound) errors=$($stats.errors.Count)"
    return $stats
}
