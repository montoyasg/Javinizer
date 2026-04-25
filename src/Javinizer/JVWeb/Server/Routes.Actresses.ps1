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
            $libDir = $env:JVWEB_LIB
            $manifestPath = $env:JVWEB_MANIFEST
            $missList = $misses.ToArray()

            $job = Start-JVJob -Kind 'actress-refresh' -ModulePath $manifestPath -LibDir $libDir `
                -Arguments @{ source = 'names'; names = $missList; replaceExisting = $false } `
                -WorkerFunction 'Invoke-JVActressRefreshWorker'
            $jobId = $job.jobId
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

        $libDir = $env:JVWEB_LIB
        $manifestPath = $env:JVWEB_MANIFEST

        $arguments = @{
            source          = $source
            names           = @($body.names)
            replaceExisting = [bool]$body.replaceExisting
        }
        if ($source -eq 'jellyfin') {
            $settings = Get-PodeState -Name 'settings'
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
        $sorted = $entries | Sort-Object { "$($_.name)" }
        $start = ($page - 1) * $pageSize
        $slice = if ($start -ge $total) { @() } else { @($sorted)[$start..[Math]::Min($start + $pageSize - 1, $total - 1)] }

        Write-PodeJsonResponse -Value @{
            entries  = $slice
            total    = $total
            page     = $page
            pageSize = $pageSize
        }
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

# Worker function lives in Lib/Invoke-JVActressRefreshWorker.ps1 so it's
# available in every Pode runspace via Use-PodeScript at startup.
