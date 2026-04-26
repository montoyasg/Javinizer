function Set-JVJellyfinActresses {
    <#
    .SYNOPSIS
    Push enriched actress metadata from jvActresses.json to a Jellyfin / Emby
    server. Supersedes Set-JVEmbyThumbs (which only did photos and only read
    from jvThumbs.csv).

    .DESCRIPTION
    Fields synced are caller-controlled via -Fields:
      Photo      Primary + Thumb image (base64 POST to /Images/Primary, /Images/Thumb)
      Bio        Overview text
      Birthdate  PremiereDate (Jellyfin's chosen field for person DOBs)
      Aliases    Name aliases — tries 'AlternateNames' then 'NameAlias' depending
                 on what the server's full-item payload contains.

    -ReplaceExisting overwrites already-set fields. -MergeDuplicates does a
    pre-pass that detects name-swapped duplicates ("Yuna Ogura" + "Ogura Yuna")
    and consolidates them: items linked to the duplicate are reassigned to the
    canonical, then the duplicate person is deleted.

    Returns a hashtable summary:
      { attempted, updated, fieldsUpdated, merged, errors, notMatched }
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$ApiKey,

        [ValidateSet('Photo','Bio','Birthdate','Aliases')]
        [string[]]$Fields = @('Photo','Bio','Birthdate','Aliases'),

        [switch]$ReplaceExisting,
        [switch]$MergeDuplicates,
        [switch]$DryRun,

        [ValidateRange(1, 32)]
        [int]$Parallelism = 6,

        [scriptblock]$ProgressCallback,  # invoked as { current, total, message }
        [scriptblock]$LogCallback        # invoked as { line }
    )

    $Url = $Url.TrimEnd('/')
    $base = "$Url/emby"
    $apiSuffix = "?api_key=$ApiKey"

    function _emit-log([string]$msg) {
        if ($LogCallback) { & $LogCallback $msg } else { Write-Host $msg }
    }
    function _emit-progress($cur, $tot, $msg) {
        if ($ProgressCallback) { & $ProgressCallback $cur $tot $msg }
    }

    $stats = @{
        attempted     = 0
        updated       = 0
        skipped       = 0
        notMatched    = @()
        fieldsUpdated = @{ photo=0; bio=0; birthdate=0; aliases=0; photoRefetched=0 }
        merged        = @()
        errors        = @()
    }

    # 1. Fetch person list
    _emit-progress 0 0 'fetching Jellyfin persons...'
    try {
        $persons = (Invoke-RestMethod -Method Get -Uri "$base/Persons/$apiSuffix" -TimeoutSec 30 -ErrorAction Stop).Items
    } catch {
        throw "Failed to list Jellyfin persons: $_"
    }
    _emit-log "Jellyfin returned $($persons.Count) persons"

    # 2. Discover userId for /Users/{userId}/Items endpoints (needed for full-item GET).
    $userId = $null
    if (('Bio' -in $Fields) -or ('Birthdate' -in $Fields) -or ('Aliases' -in $Fields) -or $MergeDuplicates) {
        # Resolve-JVJellyfinUserId lives in JVWeb/Lib/Get-JVJellyfinClient.ps1
        # and is dot-sourced in every Pode + ThreadJob runspace via the Lib glob.
        $userId = if (Get-Command Resolve-JVJellyfinUserId -ErrorAction SilentlyContinue) {
            Resolve-JVJellyfinUserId -Url $Url -ApiKey $ApiKey
        } else {
            # Fallback for callers outside the JVWeb stack (raw CLI use of the
            # public function). Inline the older pattern.
            try {
                $users = Invoke-RestMethod -Method Get -Uri "$base/Users$apiSuffix" -TimeoutSec 15 -ErrorAction Stop
                $admin = ($users | Where-Object { $_.Policy.IsAdministrator -eq $true } | Select-Object -First 1).Id
                if ($admin) { $admin } elseif ($users.Count -gt 0) { $users[0].Id } else { $null }
            } catch { $null }
        }
        if ($userId) { _emit-log "using Jellyfin user $userId for item updates" }
        else         { _emit-log "WARN: couldn't resolve userId — bio/birthdate/aliases/merge will be skipped" }
    }

    # 3. Optional merge pass for name-swap duplicates.
    if ($MergeDuplicates -and $userId) {
        _emit-progress 0 0 'scanning for name-swap duplicates...'
        $byKey = @{}
        foreach ($p in $persons) {
            $tokens = ($p.Name -split '\s+' | Where-Object { $_ })
            if ($tokens.Count -ne 2) { continue }
            $sortedKey = ($tokens | Sort-Object) -join ' '
            if (-not $byKey.ContainsKey($sortedKey)) { $byKey[$sortedKey] = @() }
            $byKey[$sortedKey] += $p
        }
        foreach ($kv in $byKey.GetEnumerator()) {
            if ($kv.Value.Count -lt 2) { continue }
            # 2 entries with the same sorted-token key → name-swap duplicates.
            $pair = @($kv.Value | Select-Object -First 2)

            # Pick canonical: the one with more linked items wins.
            $counts = @()
            foreach ($p in $pair) {
                try {
                    $r = Invoke-RestMethod -Method Get -Uri "$base/Items?PersonIds=$($p.Id)&Limit=0&Recursive=true$($apiSuffix.Replace('?', '&'))" -TimeoutSec 15 -ErrorAction Stop
                    $counts += $r.TotalRecordCount
                } catch {
                    $counts += 0
                }
            }
            $canonical = $pair[0]
            $duplicate = $pair[1]
            if ($counts[1] -gt $counts[0]) {
                $canonical = $pair[1]
                $duplicate = $pair[0]
            }
            _emit-log "merge-candidate: '$($duplicate.Name)' [$($duplicate.Id)] → '$($canonical.Name)' [$($canonical.Id)]"

            if ($DryRun) {
                $stats.merged += @{ kept = $canonical.Name; removed = $duplicate.Name; itemsReassigned = $counts[[Array]::IndexOf($pair, $duplicate)]; dryRun = $true }
                continue
            }
            if ($PSCmdlet.ShouldProcess("merge $($duplicate.Name) → $($canonical.Name)")) {
                try {
                    # Reassign every item linked to the duplicate.
                    $linked = (Invoke-RestMethod -Method Get -Uri "$base/Items?PersonIds=$($duplicate.Id)&Recursive=true&Fields=People&Limit=10000$($apiSuffix.Replace('?','&'))" -TimeoutSec 60 -ErrorAction Stop).Items
                    $reassigned = 0
                    foreach ($item in $linked) {
                        try {
                            $full = Invoke-RestMethod -Method Get -Uri "$base/Users/$userId/Items/$($item.Id)$apiSuffix" -TimeoutSec 15 -ErrorAction Stop
                            $newPeople = @()
                            foreach ($per in $full.People) {
                                if ($per.Id -eq $duplicate.Id) {
                                    $newPeople += [PSCustomObject]@{ Name = $canonical.Name; Id = $canonical.Id; Role = $per.Role; Type = $per.Type }
                                } else {
                                    $newPeople += $per
                                }
                            }
                            $full.People = $newPeople
                            $body = $full | ConvertTo-Json -Depth 32 -Compress
                            Invoke-RestMethod -Method Post -Uri "$base/Items/$($item.Id)$apiSuffix" -Body $body -ContentType 'application/json' -TimeoutSec 30 | Out-Null
                            $reassigned++
                        } catch {
                            $stats.errors += "reassign $($item.Id) -> $($canonical.Name): $_"
                        }
                    }
                    Invoke-RestMethod -Method Delete -Uri "$base/Items/$($duplicate.Id)$apiSuffix" -TimeoutSec 15 -ErrorAction Stop | Out-Null
                    $stats.merged += @{ kept = $canonical.Name; removed = $duplicate.Name; itemsReassigned = $reassigned }
                    _emit-log "merged: $reassigned items reassigned, '$($duplicate.Name)' deleted"
                } catch {
                    $stats.errors += "merge $($duplicate.Name) -> $($canonical.Name): $_"
                    _emit-log "merge FAIL: $_"
                }
            }
        }
        # Refresh person list after merges.
        try {
            $persons = (Invoke-RestMethod -Method Get -Uri "$base/Persons/$apiSuffix" -TimeoutSec 30 -ErrorAction Stop).Items
        } catch {}
    }

    # 4. Per-person field updates.
    $dataset = Get-JVActressDataset
    $total = $persons.Count
    $stats.attempted = $total
    _emit-progress 0 $total 'pre-matching against dataset...'

    # Pre-match phase (sequential, in-memory) so the parallel HTTP loop only
    # runs work for matched persons and doesn't need access to Find-JVActress.
    $tasks = New-Object System.Collections.Generic.List[Object]
    foreach ($p in $persons) {
        $entry = Find-JVActress -Name $p.Name -Dataset $dataset
        if (-not $entry) {
            $stats.notMatched += $p.Name
            continue
        }
        $tasks.Add(@{ Person = $p; Entry = $entry }) | Out-Null
    }

    if ($tasks.Count -eq 0) {
        _emit-progress $total $total 'no matched persons'
        return $stats
    }

    # Shared accumulators. Mutations inside ForEach-Object -Parallel are
    # serialized by [Monitor]::Enter on the synchronized hashtable.
    $shared = [hashtable]::Synchronized(@{
        counter         = 0
        updated         = 0
        skipped         = 0
        photo           = 0
        bio             = 0
        birthdate       = 0
        aliases         = 0
        photoRefetched  = 0   # photo upload that succeeded only after xcity fallback
    })
    $errBag = [System.Collections.Concurrent.ConcurrentBag[string]]::new()

    # Resolve the xcity scraper path once, before the parallel block. Each
    # runspace dot-sources it on first fallback so Get-XcityActressDetail
    # is callable even though parallel runspaces don't auto-import the
    # parent module. Falls back gracefully when the scraper isn't reachable
    # (e.g. callers running this function outside the JVWeb stack) — in
    # that case the fallback path silently no-ops.
    $scraperPath = $null
    foreach ($cand in @(
        $(if ($PSScriptRoot) { Join-Path (Split-Path -Parent $PSScriptRoot) 'Private/Scraper.Xcity.ps1' }),
        $(if ($env:JVWEB_LIB) { Join-Path ((Get-Item $env:JVWEB_LIB).Parent.FullName) 'Private/Scraper.Xcity.ps1' })
    )) {
        if ($cand -and (Test-Path -LiteralPath $cand)) { $scraperPath = $cand; break }
    }

    $jobStatePath = $global:JVActiveJobStatePath
    $matchedTotal = $tasks.Count
    _emit-progress 0 $matchedTotal "updating $matchedTotal matched persons (parallelism=$Parallelism)..."

    $tasks | ForEach-Object -ThrottleLimit $Parallelism -Parallel {
        $task        = $_
        $p           = $task.Person
        $entry       = $task.Entry
        $sh          = $using:shared
        $errs        = $using:errBag
        $base        = $using:base
        $apiSuffix   = $using:apiSuffix
        $userId      = $using:userId
        $fields      = $using:Fields
        $replace     = $using:ReplaceExisting
        $dry         = $using:DryRun
        $statePath   = $using:jobStatePath
        $totalCount  = $using:matchedTotal
        $scrPath     = $using:scraperPath

        function _bumpField {
            param($Sh, $Name)
            [System.Threading.Monitor]::Enter($Sh)
            try { $Sh[$Name] = $Sh[$Name] + 1 } finally { [System.Threading.Monitor]::Exit($Sh) }
        }
        function _xcityBday {
            param($Value)
            if (-not $Value) { return $null }
            $months = @{'Jan'=1;'Feb'=2;'Mar'=3;'Apr'=4;'May'=5;'Jun'=6;'Jul'=7;'Aug'=8;'Sep'=9;'Oct'=10;'Nov'=11;'Dec'=12}
            $parts = $Value.Trim() -split '\s+'
            if ($parts.Count -ne 3 -or -not $months.ContainsKey($parts[1])) { return $null }
            try { (Get-Date -Year ([int]$parts[0]) -Month $months[$parts[1]] -Day ([int]$parts[2]) -Hour 0 -Minute 0 -Second 0).ToString('yyyy-MM-ddTHH:mm:ss.0000000Z') } catch { $null }
        }

        $touched = $false

        # Early skip: when not replacing and Jellyfin already has Primary +
        # Thumb images, AND no metadata fields are requested, there's nothing
        # to do. Avoids the full-item GET round-trip entirely.
        if (-not $replace) {
            $hasImages = ([bool]$p.ImageTags.Primary -and [bool]$p.ImageTags.Thumb)
            $needsMetaCheck = (('Bio' -in $fields -and $entry.bio) -or
                               ('Birthdate' -in $fields -and $entry.birthdate) -or
                               ('Aliases' -in $fields -and $entry.aliases -and $entry.aliases.Count -gt 0))
            $needsPhotoUpload = ('Photo' -in $fields -and $entry.primaryUrl -and -not $hasImages)
            if (-not $needsPhotoUpload -and -not $needsMetaCheck) {
                _bumpField $sh 'skipped'
                # Still bump counter + write progress so the bar advances.
                [System.Threading.Monitor]::Enter($sh)
                try { $sh.counter = $sh.counter + 1; $cur = $sh.counter } finally { [System.Threading.Monitor]::Exit($sh) }
                if ($statePath -and (Test-Path -LiteralPath $statePath)) {
                    try {
                        $s = Get-Content -LiteralPath $statePath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
                        if ($s) {
                            if ($s.progress.current -ne $cur) {
                                $s.progress.updatedAt = (Get-Date).ToUniversalTime().ToString('o')
                            }
                            $s.progress.current = $cur
                            $s.progress.total   = $totalCount
                            $s.progress.message = "skip $($p.Name) (already populated)"
                            # Unique tmp filename — parallel runspaces racing
                            # on a shared "$statePath.tmp" produced torn JSON
                            # via interleaved fds on the same inode, which
                            # surfaced as transient 404 on /api/jobs/:id.
                            $tmp = "$statePath.$([Guid]::NewGuid().ToString('N')).tmp"
                            try {
                                [System.IO.File]::WriteAllText($tmp, ($s | ConvertTo-Json -Depth 12 -Compress), [System.Text.UTF8Encoding]::new($false))
                                Move-Item -LiteralPath $tmp -Destination $statePath -Force
                            } finally {
                                if (Test-Path -LiteralPath $tmp) {
                                    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
                                }
                            }
                        }
                    } catch {}
                }
                return
            }
        }

        try {
            # Photos
            if ('Photo' -in $fields -and $entry.primaryUrl) {
                $hasPrimary = [bool]$p.ImageTags.Primary
                $hasThumb   = [bool]$p.ImageTags.Thumb
                $shouldUpload = $replace -or (-not $hasPrimary) -or (-not $hasThumb)
                if ($shouldUpload) {
                    if ($dry) {
                        _bumpField $sh 'photo'
                        $touched = $true
                    } else {
                        # Try the stored URL first. If it 500s / 404s / times
                        # out, fall through to xcity by xcityId — useful when
                        # primaryUrl points at a stale Jellyfin URL or an
                        # xcity URL whose underlying image has been removed.
                        # Net effect: actresses with broken stored photos get
                        # automatically re-photographed from the xcity detail
                        # page. Bounded by Invoke-XcityRequest's existing 60s
                        # per-call wall-time budget so one slow request
                        # doesn't stall the whole sync.
                        $bytes        = $null
                        $usedFallback = $false
                        try {
                            $bytes = (Invoke-WebRequest -Method Get -Uri $entry.primaryUrl -TimeoutSec 30 -UseBasicParsing -ErrorAction Stop).Content
                        } catch {
                            $primaryErr = "$_"
                            if ($entry.xcityId -and $scrPath -and (Test-Path -LiteralPath $scrPath)) {
                                # Retry the xcity fallback up to 2× for transient
                                # "Network is unreachable" / connection-refused
                                # blips that affect a single TCP establishment
                                # but recover within a second. Once we get a URL
                                # different from the stored one and a download
                                # succeeds, break out. If xcity returns the same
                                # URL, retrying won't help — bail immediately.
                                $fallbackErr = $null
                                . $scrPath
                                for ($attempt = 1; $attempt -le 2; $attempt++) {
                                    try {
                                        $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
                                        $detail = Get-XcityActressDetail -Id "$($entry.xcityId)" -Session $session
                                        $altUrl = $detail.PrimaryUrl
                                        if ($altUrl -and $altUrl -ne $entry.primaryUrl) {
                                            $bytes = (Invoke-WebRequest -Method Get -Uri $altUrl -TimeoutSec 30 -UseBasicParsing -ErrorAction Stop).Content
                                            $usedFallback = $true
                                            $fallbackErr = $null
                                            break
                                        } else {
                                            $fallbackErr = "xcity returned same/empty URL [$($entry.xcityId)]"
                                            break  # not transient; retry won't help
                                        }
                                    } catch {
                                        $fallbackErr = "$_"
                                        if ($attempt -lt 2) { Start-Sleep -Milliseconds 500 }
                                    }
                                }
                                if (-not $bytes -and $fallbackErr) {
                                    $errs.Add("photo $($p.Name): $primaryErr; xcity fallback also failed: $fallbackErr")
                                }
                            } else {
                                $errs.Add("photo $($p.Name): $primaryErr")
                            }
                        }

                        if ($bytes) {
                            try {
                                $b64 = [Convert]::ToBase64String($bytes)
                                if (-not $hasPrimary -or $replace) {
                                    Invoke-WebRequest -Method Post -Uri "$base/Items/$($p.Id)/Images/Primary$apiSuffix" -Body $b64 -ContentType 'image/jpeg' -TimeoutSec 30 -UseBasicParsing -ErrorAction Stop | Out-Null
                                }
                                if (-not $hasThumb -or $replace) {
                                    Invoke-WebRequest -Method Post -Uri "$base/Items/$($p.Id)/Images/Thumb$apiSuffix" -Body $b64 -ContentType 'image/jpeg' -TimeoutSec 30 -UseBasicParsing -ErrorAction Stop | Out-Null
                                }
                                _bumpField $sh 'photo'
                                if ($usedFallback) { _bumpField $sh 'photoRefetched' }
                                $touched = $true
                            } catch {
                                $errs.Add("photo upload $($p.Name): $_")
                            }
                        }
                    }
                }
            }

            # Metadata round-trip
            #
            # Pre-v1.11.3 this whole block was wrapped in one try/catch. If
            # ANY field assignment threw (e.g. "$full.Overview = ..." on a
            # Jellyfin response that doesn't have the Overview property —
            # PowerShell can't set non-existent properties on a sealed
            # PSCustomObject), the catch fired, $changed stayed false, and
            # the POST never ran — rolling back any earlier successful
            # field updates that lived only in the in-memory $full.
            #
            # v1.11.3 splits this into per-field try/catch blocks, each
            # using the Add-Member fallback when the property doesn't
            # exist. One field's failure no longer poisons the others, and
            # the POST fires with whatever fields succeeded.
            $needMeta = (('Bio' -in $fields -and $entry.bio) -or
                         ('Birthdate' -in $fields -and $entry.birthdate) -or
                         ('Aliases' -in $fields -and $entry.aliases -and $entry.aliases.Count -gt 0))
            if ($needMeta -and $userId) {
                $full = $null
                try {
                    $full = Invoke-RestMethod -Method Get -Uri "$base/Users/$userId/Items/$($p.Id)$apiSuffix" -TimeoutSec 15 -ErrorAction Stop
                } catch {
                    $errs.Add("meta GET $($p.Name): $_")
                }

                if ($full) {
                    $changed = $false

                    # Helper: assign a property by name, using Add-Member when
                    # the target object doesn't already expose it. Avoids the
                    # "property X cannot be found on this object" error.
                    $setProp = {
                        param($Obj, $Name, $Value)
                        if ($Obj.PSObject.Properties.Name -contains $Name) {
                            $Obj.$Name = $Value
                        } else {
                            Add-Member -InputObject $Obj -NotePropertyName $Name -NotePropertyValue $Value -Force
                        }
                    }

                    if ('Bio' -in $fields -and $entry.bio -and ($replace -or -not $full.Overview)) {
                        try {
                            & $setProp $full 'Overview' $entry.bio
                            $changed = $true
                            _bumpField $sh 'bio'
                        } catch {
                            $errs.Add("meta bio $($p.Name): $_")
                        }
                    }

                    if ('Birthdate' -in $fields -and $entry.birthdate) {
                        $bday = _xcityBday $entry.birthdate
                        if ($bday -and ($replace -or -not $full.PremiereDate)) {
                            try {
                                & $setProp $full 'PremiereDate' $bday
                                $changed = $true
                                _bumpField $sh 'birthdate'
                            } catch {
                                $errs.Add("meta birthdate $($p.Name): $_")
                            }
                        }
                    }

                    if ('Aliases' -in $fields -and $entry.aliases -and $entry.aliases.Count -gt 0) {
                        $aliasField = $null
                        foreach ($cand in @('AlternateNames','NameAlias','Aliases')) {
                            if ($full.PSObject.Properties.Name -contains $cand) { $aliasField = $cand; break }
                        }
                        if (-not $aliasField) { $aliasField = 'AlternateNames' }
                        $existing = @()
                        try { $existing = @($full.$aliasField) | Where-Object { $_ } } catch {}
                        if ($replace -or $existing.Count -eq 0) {
                            try {
                                $cleanAliases = @($entry.aliases | Where-Object { $_ -ne $entry.name })
                                & $setProp $full $aliasField $cleanAliases
                                $changed = $true
                                _bumpField $sh 'aliases'
                            } catch {
                                $errs.Add("meta aliases $($p.Name): $_")
                            }
                        }
                    }

                    if ($changed) {
                        if ($dry) {
                            $touched = $true
                        } else {
                            try {
                                $body = $full | ConvertTo-Json -Depth 32 -Compress
                                Invoke-RestMethod -Method Post -Uri "$base/Items/$($p.Id)$apiSuffix" -Body $body -ContentType 'application/json' -TimeoutSec 30 -ErrorAction Stop | Out-Null
                                $touched = $true
                            } catch {
                                $errs.Add("meta POST $($p.Name): $_")
                            }
                        }
                    }
                }
            }
        } catch {
            $errs.Add("$($p.Name): $_")
        }

        if ($touched) { _bumpField $sh 'updated' }
        else          { _bumpField $sh 'skipped' }

        # Bump counter + write progress to state file. Concurrent writes are
        # tolerated — atomic Move-Item ensures the file isn't corrupted; the
        # worst case is a stale-by-one displayed counter.
        [System.Threading.Monitor]::Enter($sh)
        try { $sh.counter = $sh.counter + 1; $cur = $sh.counter } finally { [System.Threading.Monitor]::Exit($sh) }
        if ($statePath -and (Test-Path -LiteralPath $statePath)) {
            try {
                $s = Get-Content -LiteralPath $statePath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
                if ($s) {
                    if ($s.progress.current -ne $cur) {
                        $s.progress.updatedAt = (Get-Date).ToUniversalTime().ToString('o')
                    }
                    $s.progress.current = $cur
                    $s.progress.total   = $totalCount
                    $s.progress.message = "updating $($p.Name)"
                    # Unique tmp filename — see early-skip path above for the
                    # race-condition rationale.
                    $tmp = "$statePath.$([Guid]::NewGuid().ToString('N')).tmp"
                    try {
                        [System.IO.File]::WriteAllText($tmp, ($s | ConvertTo-Json -Depth 12 -Compress), [System.Text.UTF8Encoding]::new($false))
                        Move-Item -LiteralPath $tmp -Destination $statePath -Force
                    } finally {
                        if (Test-Path -LiteralPath $tmp) {
                            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
                        }
                    }
                }
            } catch {}
        }
    }

    # Sync stats back from shared counters.
    $stats.updated = $shared.updated
    $stats.skipped = $shared.skipped
    $stats.fieldsUpdated.photo          = $shared.photo
    $stats.fieldsUpdated.bio            = $shared.bio
    $stats.fieldsUpdated.birthdate      = $shared.birthdate
    $stats.fieldsUpdated.aliases        = $shared.aliases
    $stats.fieldsUpdated.photoRefetched = $shared.photoRefetched
    if ($shared.photoRefetched -gt 0) {
        _emit-log "photo refetched from xcity for $($shared.photoRefetched) actress$(if ($shared.photoRefetched -eq 1) {''} else {'es'}) (stored URL was unreachable)"
    }
    foreach ($e in $errBag) { $stats.errors += $e }

    _emit-progress $matchedTotal $matchedTotal "done"
    return $stats
}

function ConvertFrom-XcityBirthdate {
    <#
    .SYNOPSIS
    Convert xcity-style "1998 Nov 05" → ISO "1998-11-05T00:00:00.0000000Z".
    Returns $null on parse failure.
    #>
    param([string]$Value)
    if (-not $Value) { return $null }
    $months = @{
        'Jan'=1;'Feb'=2;'Mar'=3;'Apr'=4;'May'=5;'Jun'=6;
        'Jul'=7;'Aug'=8;'Sep'=9;'Oct'=10;'Nov'=11;'Dec'=12
    }
    $parts = $Value.Trim() -split '\s+'
    if ($parts.Count -ne 3) { return $null }
    if (-not $months.ContainsKey($parts[1])) { return $null }
    try {
        $dt = Get-Date -Year ([int]$parts[0]) -Month $months[$parts[1]] -Day ([int]$parts[2]) -Hour 0 -Minute 0 -Second 0
        return $dt.ToString('yyyy-MM-ddTHH:mm:ss.0000000Z')
    } catch {
        return $null
    }
}
