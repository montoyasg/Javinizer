# POST /api/actresses/lookup — synchronous bulk hydrate.
# Body: { names: [{ name, japaneseName?, aliases? }], autoEnrich?: bool }
# Returns: { hits: [{ matched, data? }], misses: [name, ...] }
Add-PodeRoute -Method Post -Path '/api/actresses/lookup' -ScriptBlock {
    try {
        $body = $WebEvent.Data
        $names = @($body.names)
        if (-not $names) {
            Write-PodeJsonResponse -Value @{ error = 'names required' } -StatusCode 400
            return
        }

        $dataset = Get-JVActressDataset
        $hits = New-Object System.Collections.Generic.List[Object]
        $misses = New-Object System.Collections.Generic.List[Object]

        foreach ($n in $names) {
            $entry = Find-JVActress -Name $n.name -JapaneseName $n.japaneseName -Aliases @($n.aliases) -Dataset $dataset
            if ($entry) {
                $hits.Add([ordered]@{ query = $n; matched = $true; data = $entry }) | Out-Null
            } else {
                $hits.Add([ordered]@{ query = $n; matched = $false }) | Out-Null
                $misses.Add($n) | Out-Null
            }
        }

        $jobId = $null
        $autoEnrich = if ($body.PSObject.Properties.Name -contains 'autoEnrich' -or ($body -is [System.Collections.IDictionary] -and $body.Contains('autoEnrich'))) {
            [bool]$body.autoEnrich
        } else { $true }

        if ($autoEnrich -and $misses.Count -gt 0) {
            # Drop empty-name misses before queueing — the worker would skip
            # them anyway, but we don't want a refresh job to run for nothing.
            $missList = New-Object System.Collections.Generic.List[Object]
            foreach ($m in $misses) {
                if ("$($m.name)".Trim()) { $missList.Add($m) | Out-Null }
            }
            if ($missList.Count -gt 0) {
                $libDir = $env:JVWEB_LIB
                $manifestPath = $env:JVWEB_MANIFEST
                $job = Start-JVJob -Kind 'actress-refresh' -ModulePath $manifestPath -LibDir $libDir `
                    -Arguments @{ source = 'names'; names = $missList.ToArray(); replaceExisting = $false } `
                    -WorkerFunction 'Invoke-JVActressRefreshWorker'
                $jobId = $job.jobId
            }
        }

        Write-PodeJsonResponse -Value @{
            hits     = $hits.ToArray()
            misses   = $misses.ToArray()
            jobId    = $jobId
        }
    } catch {
        Write-PodeHost "actresses lookup error: $PSItem`n$($_.ScriptStackTrace)" -ForegroundColor Red
        Write-PodeJsonResponse -Value @{ error = "$($PSItem.Exception.Message)" } -StatusCode 500
    }
}

# POST /api/actresses/refresh — start a background xcity scrape.
# Body: { source: 'jellyfin' | 'names', names?: [...], replaceExisting?: bool }
Add-PodeRoute -Method Post -Path '/api/actresses/refresh' -ScriptBlock {
    try {
        $body = $WebEvent.Data
        $source = "$($body.source)".Trim().ToLowerInvariant()
        if ($source -ne 'jellyfin' -and $source -ne 'names') {
            Write-PodeJsonResponse -Value @{ error = "source must be 'jellyfin' or 'names'" } -StatusCode 400
            return
        }
        if ($source -eq 'names' -and -not $body.names) {
            Write-PodeJsonResponse -Value @{ error = "names required when source='names'" } -StatusCode 400
            return
        }

        # Cull entries with empty/whitespace names. The worker's pre-skip would
        # filter them out anyway, but rejecting at the boundary gives the
        # caller a clear 400 instead of a job that silently does nothing.
        $cleanedNames = @()
        $emptyDropped = 0
        if ($source -eq 'names') {
            $rawNames = @($body.names)
            $kept = New-Object System.Collections.Generic.List[Object]
            foreach ($n in $rawNames) {
                $candidate = "$($n.name)".Trim()
                if (-not $candidate) { $emptyDropped++; continue }
                $kept.Add($n) | Out-Null
            }
            $cleanedNames = $kept.ToArray()
            if ($cleanedNames.Count -eq 0) {
                Write-PodeJsonResponse -Value @{
                    error = "names list is empty after dropping $emptyDropped blank entr$(if ($emptyDropped -eq 1) {'y'} else {'ies'}); nothing to refresh"
                } -StatusCode 400
                return
            }
        }

        $libDir = $env:JVWEB_LIB
        $manifestPath = $env:JVWEB_MANIFEST
        $settings = Get-PodeState -Name 'settings'

        # xcity-side parallelism (Phase C). New key wins; falls back to legacy.
        $xcityParallelism = if ($body.xcityParallelism) { [int]$body.xcityParallelism }
                            elseif ($body.parallelism)  { [int]$body.parallelism }
                            elseif ($settings.'actresses.refresh.xcity.parallelism') { [int]$settings.'actresses.refresh.xcity.parallelism' }
                            elseif ($settings.'actresses.refresh.parallelism')       { [int]$settings.'actresses.refresh.parallelism' }
                            else { 3 }
        if ($xcityParallelism -lt 1)  { $xcityParallelism = 1 }
        if ($xcityParallelism -gt 16) { $xcityParallelism = 16 }

        # Jellyfin-side parallelism (Phase B).
        $jellyfinParallelism = if ($body.jellyfinParallelism) { [int]$body.jellyfinParallelism }
                               elseif ($settings.'actresses.refresh.jellyfin.parallelism') { [int]$settings.'actresses.refresh.jellyfin.parallelism' }
                               else { 8 }
        if ($jellyfinParallelism -lt 1)  { $jellyfinParallelism = 1 }
        if ($jellyfinParallelism -gt 32) { $jellyfinParallelism = 32 }

        # Phase B opt-in. Default ON. Body wins; else read setting; else true.
        $useJellyfin = $true
        if ($body.PSObject.Properties.Name -contains 'useJellyfin' -or
            ($body -is [System.Collections.IDictionary] -and $body.Contains('useJellyfin'))) {
            $useJellyfin = [bool]$body.useJellyfin
        } elseif ($settings.PSObject.Properties.Name -contains 'actresses.refresh.usejellyfin') {
            $useJellyfin = [bool]$settings.'actresses.refresh.usejellyfin'
        }

        # Skip-xcity-sourced toggle. Default OFF. Body wins; else read setting.
        $skipXcitySourced = $false
        if ($body.PSObject.Properties.Name -contains 'skipXcitySourced' -or
            ($body -is [System.Collections.IDictionary] -and $body.Contains('skipXcitySourced'))) {
            $skipXcitySourced = [bool]$body.skipXcitySourced
        } elseif ($settings.PSObject.Properties.Name -contains 'actresses.refresh.skipxcitysourced') {
            $skipXcitySourced = [bool]$settings.'actresses.refresh.skipxcitysourced'
        }

        $arguments = @{
            source              = $source
            names               = $cleanedNames
            replaceExisting     = [bool]$body.replaceExisting
            xcityParallelism    = $xcityParallelism
            jellyfinParallelism = $jellyfinParallelism
            useJellyfin         = $useJellyfin
            skipXcitySourced    = $skipXcitySourced
            parallelism         = $xcityParallelism  # legacy alias for worker
        }
        if ($source -eq 'jellyfin') {
            $arguments['embyUrl']    = $settings.'emby.url'
            $arguments['embyApiKey'] = $settings.'emby.apikey'
            if (-not $arguments.embyUrl -or -not $arguments.embyApiKey) {
                Write-PodeJsonResponse -Value @{ error = 'emby.url and emby.apikey must be configured' } -StatusCode 400
                return
            }
        }

        $job = Start-JVJob -Kind 'actress-refresh' -ModulePath $manifestPath -LibDir $libDir `
            -Arguments $arguments `
            -WorkerFunction 'Invoke-JVActressRefreshWorker'

        Write-PodeJsonResponse -Value @{ jobId = $job.jobId }
    } catch {
        Write-PodeHost "actresses refresh error: $PSItem`n$($_.ScriptStackTrace)" -ForegroundColor Red
        Write-PodeJsonResponse -Value @{ error = "$($PSItem.Exception.Message)" } -StatusCode 500
    }
}

# GET /api/actresses?q=&page=&pageSize=&filter=
Add-PodeRoute -Method Get -Path '/api/actresses' -ScriptBlock {
    try {
        $q        = "$($WebEvent.Query['q'])".Trim()
        $page     = [Math]::Max(1, [int]("$($WebEvent.Query['page'])" -as [int]))
        $pageSize = [int]("$($WebEvent.Query['pageSize'])" -as [int])
        if ($pageSize -le 0) { $pageSize = 100 }
        $filter   = "$($WebEvent.Query['filter'])".Trim().ToLowerInvariant()

        $dataset = Get-JVActressDataset

        # Dedupe entries by name+xcityId (multiple keys point at the same payload).
        $seen = New-Object System.Collections.Generic.HashSet[string]
        $entries = New-Object System.Collections.Generic.List[Object]
        foreach ($k in $dataset.Keys) {
            $e = $dataset[$k]
            if (-not $e) { continue }
            $sig = "$($e.name)|$($e.xcityId)"
            if (-not $seen.Add($sig)) { continue }

            if ($q) {
                $haystack = (@($e.name, $e.japaneseName) + @($e.aliases) | Where-Object { $_ }) -join '|'
                if ($haystack -inotmatch [regex]::Escape($q)) { continue }
            }
            switch ($filter) {
                'missing-photo' { if ($e.primaryUrl) { continue } }
                'missing-bio'   { if ($e.bio) { continue } }
            }
            $entries.Add($e) | Out-Null
        }

        $total = $entries.Count
        $sorted = New-Object System.Collections.Generic.List[Object]
        foreach ($e in ($entries | Sort-Object { "$($_.name)" })) { $sorted.Add($e) | Out-Null }
        $sliceList = New-Object System.Collections.Generic.List[Object]
        if ($total -gt 0) {
            $start = ($page - 1) * $pageSize
            $end = [Math]::Min($start + $pageSize - 1, $total - 1)
            for ($idx = $start; $idx -le $end -and $idx -lt $total; $idx++) {
                $sliceList.Add($sorted[$idx]) | Out-Null
            }
        }

        # Build JSON manually to preserve single-element-array shape (PS's
        # ConvertTo-Json unwraps 1-element arrays inside hashtables).
        $entriesJson = switch ($sliceList.Count) {
            0       { '[]' }
            1       { '[' + (ConvertTo-Json -InputObject $sliceList[0] -Depth 12 -Compress) + ']' }
            default { ConvertTo-Json -InputObject ([Object[]]$sliceList) -Depth 12 -Compress }
        }
        $body = @"
{
  "entries": $entriesJson,
  "total": $total,
  "page": $page,
  "pageSize": $pageSize
}
"@
        Write-PodeTextResponse -Value $body -ContentType 'application/json'
    } catch {
        Write-PodeHost "actresses list error: $PSItem`n$($_.ScriptStackTrace)" -ForegroundColor Red
        Write-PodeJsonResponse -Value @{ error = "$($PSItem.Exception.Message)" } -StatusCode 500
    }
}

# GET /api/actresses/:key
Add-PodeRoute -Method Get -Path '/api/actresses/:key' -ScriptBlock {
    try {
        $key = $WebEvent.Parameters['key']
        if (-not $key) {
            Write-PodeJsonResponse -Value @{ error = 'key required' } -StatusCode 400
            return
        }
        $entry = Find-JVActress -Name $key -Dataset (Get-JVActressDataset)
        if (-not $entry) {
            Write-PodeJsonResponse -Value @{ error = 'not found' } -StatusCode 404
            return
        }
        Write-PodeJsonResponse -Value $entry
    } catch {
        Write-PodeHost "actresses get error: $PSItem`n$($_.ScriptStackTrace)" -ForegroundColor Red
        Write-PodeJsonResponse -Value @{ error = "$($PSItem.Exception.Message)" } -StatusCode 500
    }
}

# POST /api/actresses/cleanup — prune dataset entries that match maintenance
# rules. Body: { rules?: ['empty-name','stub'], dryRun?: bool }.
#   - empty-name: entry's name field is null/empty/whitespace
#   - stub      : no bio AND no primaryUrl AND no xcityId (a placeholder
#                 stub from the v1.2.0–v1.3.0 era when no-match cases got
#                 saved as skeleton entries)
# Returns { removedCount, keptCount, removed: [{ key, name, reason }], dryRun, rules }.
Add-PodeRoute -Method Post -Path '/api/actresses/cleanup' -ScriptBlock {
    try {
        $body = $WebEvent.Data
        $rules = if ($body.rules) { @($body.rules | ForEach-Object { "$_".Trim().ToLowerInvariant() } | Where-Object { $_ }) }
                 else { @('empty-name', 'stub') }
        $dryRun = [bool]$body.dryRun

        $valid = @('empty-name', 'stub')
        foreach ($r in $rules) {
            if ($valid -notcontains $r) {
                Write-PodeJsonResponse -Value @{ error = "unknown rule '$r'; valid: $($valid -join ', ')" } -StatusCode 400
                return
            }
        }

        $dataset = Get-JVActressDataset -Force
        $removed = New-Object System.Collections.Generic.List[Object]
        $kept    = [ordered]@{}

        foreach ($k in @($dataset.Keys)) {
            $entry = $dataset[$k]

            $hasName  = ($null -ne $entry.name)       -and ("$($entry.name)".Trim().Length       -gt 0)
            $hasBio   = ($null -ne $entry.bio)        -and ("$($entry.bio)".Trim().Length        -gt 0)
            $hasPhoto = ($null -ne $entry.primaryUrl) -and ("$($entry.primaryUrl)".Trim().Length -gt 0)
            $hasXcity = ($null -ne $entry.xcityId)    -and ("$($entry.xcityId)".Trim().Length    -gt 0)

            $reason = $null
            if (('empty-name' -in $rules) -and -not $hasName) {
                $reason = 'empty-name'
            } elseif (('stub' -in $rules) -and -not $hasBio -and -not $hasPhoto -and -not $hasXcity) {
                $reason = 'stub'
            }

            if ($reason) {
                $removed.Add([ordered]@{ key = "$k"; name = "$($entry.name)"; reason = $reason }) | Out-Null
            } else {
                $kept[$k] = $entry
            }
        }

        if (-not $dryRun -and $removed.Count -gt 0) {
            Save-JVActressDataset -Dataset $kept | Out-Null
        }

        # Hand-build JSON so the `removed` array survives single-element coercion
        # (PS ConvertTo-Json unwraps 1-elem arrays inside hashtables).
        $removedJson = switch ($removed.Count) {
            0       { '[]' }
            1       { '[' + (ConvertTo-Json -InputObject $removed[0] -Depth 6 -Compress) + ']' }
            default { ConvertTo-Json -InputObject ([Object[]]$removed) -Depth 6 -Compress }
        }
        $rulesJson = if ($rules.Count -le 1) {
            '[' + (($rules | ForEach-Object { "`"$_`"" }) -join ',') + ']'
        } else {
            ConvertTo-Json -InputObject ([Object[]]$rules) -Compress
        }
        $body = @"
{
  "removedCount": $($removed.Count),
  "keptCount": $($kept.Count),
  "removed": $removedJson,
  "rules": $rulesJson,
  "dryRun": $($dryRun.ToString().ToLowerInvariant())
}
"@
        Write-PodeTextResponse -Value $body -ContentType 'application/json'
    } catch {
        Write-PodeHost "actresses cleanup error: $PSItem`n$($_.ScriptStackTrace)" -ForegroundColor Red
        Write-PodeJsonResponse -Value @{ error = "$($PSItem.Exception.Message)" } -StatusCode 500
    }
}

# Worker function lives in Lib/Invoke-JVActressRefreshWorker.ps1 so it's
# available in every Pode runspace via Use-PodeScript at startup.
