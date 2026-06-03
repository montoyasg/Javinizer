# Routes for the local r18.dev SQLite cache: report freshness and trigger a
# background rebuild from the weekly dump.

# GET /api/r18dump/status — freshness of the local cache.
Add-PodeRoute -Method Get -Path '/api/r18dump/status' -ScriptBlock {
    try {
        $status = Get-R18DevDumpStatus

        # Best-effort: is a rebuild job currently running?
        $building = $false
        try {
            $jobsDir = Get-JVJobsDir
            if ($jobsDir -and (Test-Path -LiteralPath $jobsDir)) {
                foreach ($f in Get-ChildItem -Path $jobsDir -Filter '*.json' -ErrorAction SilentlyContinue) {
                    $j = Get-Content -LiteralPath $f.FullName -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json -ErrorAction SilentlyContinue
                    if ($j.kind -eq 'r18dump-refresh' -and $j.status -eq 'running') { $building = $true; break }
                }
            }
        } catch {}

        Write-PodeJsonResponse -Value @{
            exists     = $status.exists
            dumpDate   = $status.dumpDate
            ageDays    = $status.ageDays
            stale      = $status.stale
            maxAgeDays = $status.maxAgeDays
            builtAt    = $status.builtAt
            building   = $building
        }
    } catch {
        Write-PodeHost "r18dump status error: $PSItem" -ForegroundColor Red
        Write-PodeJsonResponse -Value @{ error = "$($PSItem.Exception.Message)" } -StatusCode 500
    }
}

# POST /api/r18dump/refresh — rebuild the cache from the latest dump.
Add-PodeRoute -Method Post -Path '/api/r18dump/refresh' -ScriptBlock {
    try {
        $libDir = $env:JVWEB_LIB
        $manifestPath = $env:JVWEB_MANIFEST
        $job = Start-JVJob -Kind 'r18dump-refresh' -ModulePath $manifestPath -LibDir $libDir `
            -WorkerFunction 'Invoke-JVR18DumpWorker'
        Write-PodeJsonResponse -Value @{ jobId = $job.jobId }
    } catch {
        Write-PodeHost "r18dump refresh error: $PSItem" -ForegroundColor Red
        Write-PodeJsonResponse -Value @{ error = "$($PSItem.Exception.Message)" } -StatusCode 500
    }
}
