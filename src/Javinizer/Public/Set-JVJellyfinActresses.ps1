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
        notMatched    = @()
        fieldsUpdated = @{ photo=0; bio=0; birthdate=0; aliases=0 }
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
        try {
            $users = Invoke-RestMethod -Method Get -Uri "$base/Users$apiSuffix" -TimeoutSec 15 -ErrorAction Stop
            $userId = ($users | Where-Object { $_.Policy.IsAdministrator -eq $true } | Select-Object -First 1).Id
            if (-not $userId) { $userId = $users[0].Id }
            _emit-log "using Jellyfin user $userId for item updates"
        } catch {
            _emit-log "WARN: couldn't list users ($_) — bio/birthdate/aliases/merge will be skipped"
            $userId = $null
        }
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
        counter   = 0
        updated   = 0
        photo     = 0
        bio       = 0
        birthdate = 0
        aliases   = 0
    })
    $errBag = [System.Collections.Concurrent.ConcurrentBag[string]]::new()

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
                        try {
                            $bytes = (Invoke-WebRequest -Method Get -Uri $entry.primaryUrl -TimeoutSec 30 -UseBasicParsing -ErrorAction Stop).Content
                            $b64 = [Convert]::ToBase64String($bytes)
                            if (-not $hasPrimary -or $replace) {
                                Invoke-WebRequest -Method Post -Uri "$base/Items/$($p.Id)/Images/Primary$apiSuffix" -Body $b64 -ContentType 'image/jpeg' -TimeoutSec 30 -UseBasicParsing -ErrorAction Stop | Out-Null
                            }
                            if (-not $hasThumb -or $replace) {
                                Invoke-WebRequest -Method Post -Uri "$base/Items/$($p.Id)/Images/Thumb$apiSuffix" -Body $b64 -ContentType 'image/jpeg' -TimeoutSec 30 -UseBasicParsing -ErrorAction Stop | Out-Null
                            }
                            _bumpField $sh 'photo'
                            $touched = $true
                        } catch {
                            $errs.Add("photo $($p.Name): $_")
                        }
                    }
                }
            }

            # Metadata round-trip
            $needMeta = (('Bio' -in $fields -and $entry.bio) -or
                         ('Birthdate' -in $fields -and $entry.birthdate) -or
                         ('Aliases' -in $fields -and $entry.aliases -and $entry.aliases.Count -gt 0))
            if ($needMeta -and $userId) {
                try {
                    $full = Invoke-RestMethod -Method Get -Uri "$base/Users/$userId/Items/$($p.Id)$apiSuffix" -TimeoutSec 15 -ErrorAction Stop
                    $changed = $false

                    if ('Bio' -in $fields -and $entry.bio -and ($replace -or -not $full.Overview)) {
                        $full.Overview = $entry.bio
                        $changed = $true
                        _bumpField $sh 'bio'
                    }

                    if ('Birthdate' -in $fields -and $entry.birthdate) {
                        $bday = _xcityBday $entry.birthdate
                        if ($bday -and ($replace -or -not $full.PremiereDate)) {
                            if ($full.PSObject.Properties.Name -contains 'PremiereDate') { $full.PremiereDate = $bday }
                            else { Add-Member -InputObject $full -NotePropertyName PremiereDate -NotePropertyValue $bday -Force }
                            $changed = $true
                            _bumpField $sh 'birthdate'
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
                            $full.$aliasField = @($entry.aliases | Where-Object { $_ -ne $entry.name })
                            $changed = $true
                            _bumpField $sh 'aliases'
                        }
                    }

                    if ($changed) {
                        if ($dry) {
                            $touched = $true
                        } else {
                            $body = $full | ConvertTo-Json -Depth 32 -Compress
                            Invoke-RestMethod -Method Post -Uri "$base/Items/$($p.Id)$apiSuffix" -Body $body -ContentType 'application/json' -TimeoutSec 30 -ErrorAction Stop | Out-Null
                            $touched = $true
                        }
                    }
                } catch {
                    $errs.Add("meta $($p.Name): $_")
                }
            }
        } catch {
            $errs.Add("$($p.Name): $_")
        }

        if ($touched) { _bumpField $sh 'updated' }

        # Bump counter + write progress to state file. Concurrent writes are
        # tolerated — atomic Move-Item ensures the file isn't corrupted; the
        # worst case is a stale-by-one displayed counter.
        [System.Threading.Monitor]::Enter($sh)
        try { $sh.counter = $sh.counter + 1; $cur = $sh.counter } finally { [System.Threading.Monitor]::Exit($sh) }
        if ($statePath -and (Test-Path -LiteralPath $statePath)) {
            try {
                $s = Get-Content -LiteralPath $statePath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
                if ($s) {
                    $s.progress.current = $cur
                    $s.progress.total   = $totalCount
                    $s.progress.message = "updating $($p.Name)"
                    $tmp = "$statePath.tmp"
                    [System.IO.File]::WriteAllText($tmp, ($s | ConvertTo-Json -Depth 12 -Compress), [System.Text.UTF8Encoding]::new($false))
                    Move-Item -LiteralPath $tmp -Destination $statePath -Force
                }
            } catch {}
        }
    }

    # Sync stats back from shared counters.
    $stats.updated = $shared.updated
    $stats.fieldsUpdated.photo     = $shared.photo
    $stats.fieldsUpdated.bio       = $shared.bio
    $stats.fieldsUpdated.birthdate = $shared.birthdate
    $stats.fieldsUpdated.aliases   = $shared.aliases
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
