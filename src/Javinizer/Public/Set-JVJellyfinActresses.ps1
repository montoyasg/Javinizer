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
    _emit-progress 0 $total 'preparing updates...'

    for ($i = 0; $i -lt $persons.Count; $i++) {
        $p = $persons[$i]
        $stats.attempted++
        _emit-progress ($i + 1) $total "updating $($p.Name)"

        $entry = Find-JVActress -Name $p.Name -Dataset $dataset
        if (-not $entry) {
            $stats.notMatched += $p.Name
            continue
        }

        $touched = $false

        # 4a. Photos
        if ('Photo' -in $Fields -and $entry.primaryUrl) {
            $hasPrimary = [bool]$p.ImageTags.Primary
            $hasThumb   = [bool]$p.ImageTags.Thumb
            $shouldUpload = $ReplaceExisting -or (-not $hasPrimary) -or (-not $hasThumb)
            if ($shouldUpload) {
                if ($DryRun) {
                    $stats.fieldsUpdated.photo++
                    $touched = $true
                } else {
                    try {
                        $bytes = (Invoke-WebRequest -Method Get -Uri $entry.primaryUrl -TimeoutSec 30 -UseBasicParsing -ErrorAction Stop).Content
                        $b64 = [Convert]::ToBase64String($bytes)
                        if (-not $hasPrimary -or $ReplaceExisting) {
                            Invoke-WebRequest -Method Post -Uri "$base/Items/$($p.Id)/Images/Primary$apiSuffix" -Body $b64 -ContentType 'image/jpeg' -TimeoutSec 30 -UseBasicParsing -ErrorAction Stop | Out-Null
                        }
                        if (-not $hasThumb -or $ReplaceExisting) {
                            Invoke-WebRequest -Method Post -Uri "$base/Items/$($p.Id)/Images/Thumb$apiSuffix" -Body $b64 -ContentType 'image/jpeg' -TimeoutSec 30 -UseBasicParsing -ErrorAction Stop | Out-Null
                        }
                        $stats.fieldsUpdated.photo++
                        $touched = $true
                    } catch {
                        $stats.errors += "photo $($p.Name): $_"
                    }
                }
            }
        }

        # 4b. Metadata fields (require full-item round-trip).
        $needMeta = (('Bio' -in $Fields -and $entry.bio) -or
                     ('Birthdate' -in $Fields -and $entry.birthdate) -or
                     ('Aliases' -in $Fields -and $entry.aliases -and $entry.aliases.Count -gt 0))
        if ($needMeta -and $userId) {
            try {
                $full = Invoke-RestMethod -Method Get -Uri "$base/Users/$userId/Items/$($p.Id)$apiSuffix" -TimeoutSec 15 -ErrorAction Stop
                $changed = $false

                if ('Bio' -in $Fields -and $entry.bio -and ($ReplaceExisting -or -not $full.Overview)) {
                    $full.Overview = $entry.bio
                    $changed = $true
                    $stats.fieldsUpdated.bio++
                }

                if ('Birthdate' -in $Fields -and $entry.birthdate) {
                    $bday = ConvertFrom-XcityBirthdate $entry.birthdate
                    if ($bday -and ($ReplaceExisting -or -not $full.PremiereDate)) {
                        if ($full.PSObject.Properties.Name -contains 'PremiereDate') { $full.PremiereDate = $bday }
                        else { Add-Member -InputObject $full -NotePropertyName PremiereDate -NotePropertyValue $bday -Force }
                        $changed = $true
                        $stats.fieldsUpdated.birthdate++
                    }
                }

                if ('Aliases' -in $Fields -and $entry.aliases -and $entry.aliases.Count -gt 0) {
                    $aliasField = $null
                    foreach ($cand in @('AlternateNames','NameAlias','Aliases')) {
                        if ($full.PSObject.Properties.Name -contains $cand) { $aliasField = $cand; break }
                    }
                    if (-not $aliasField) { $aliasField = 'AlternateNames' }
                    $existing = @()
                    try { $existing = @($full.$aliasField) | Where-Object { $_ } } catch {}
                    if ($ReplaceExisting -or $existing.Count -eq 0) {
                        $full.$aliasField = @($entry.aliases | Where-Object { $_ -ne $entry.name })
                        $changed = $true
                        $stats.fieldsUpdated.aliases++
                    }
                }

                if ($changed) {
                    if ($DryRun) {
                        $touched = $true
                    } else {
                        $body = $full | ConvertTo-Json -Depth 32 -Compress
                        Invoke-RestMethod -Method Post -Uri "$base/Items/$($p.Id)$apiSuffix" -Body $body -ContentType 'application/json' -TimeoutSec 30 -ErrorAction Stop | Out-Null
                        $touched = $true
                    }
                }
            } catch {
                $stats.errors += "meta $($p.Name): $_"
            }
        }

        if ($touched) { $stats.updated++ }
    }

    _emit-progress $total $total "done"
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
