# GET /api/jellyfin/health — quick connectivity ping.
Add-PodeRoute -Method Get -Path '/api/jellyfin/health' -ScriptBlock {
    try {
        $settings = Get-PodeState -Name 'settings'
        $url = $settings.'emby.url'
        $key = $settings.'emby.apikey'
        if (-not $url -or -not $key) {
            Write-PodeJsonResponse -Value @{ ok = $false; reason = 'not configured' }
            return
        }
        $url = $url.TrimEnd('/')
        $start = [DateTime]::UtcNow
        try {
            $info = Invoke-RestMethod -Method Get -Uri "$url/emby/System/Info?api_key=$key" -TimeoutSec 6 -ErrorAction Stop
            $latency = [int]([DateTime]::UtcNow - $start).TotalMilliseconds
            Write-PodeJsonResponse -Value @{
                ok          = $true
                serverName  = $info.ServerName
                version     = $info.Version
                latency_ms  = $latency
            }
        } catch {
            Write-PodeJsonResponse -Value @{ ok = $false; reason = "$($_.Exception.Message)" }
        }
    } catch {
        Write-PodeHost "jellyfin health error: $PSItem`n$($_.ScriptStackTrace)" -ForegroundColor Red
        Write-PodeJsonResponse -Value @{ ok = $false; error = "$($PSItem.Exception.Message)" } -StatusCode 500
    }
}

# POST /api/jellyfin/cleanup-mojibake — start a background job that scans
# every movie's People array for mojibake-named entries (control chars,
# Latin-1 Supplement, U+FFFD), patches them out via the Jellyfin REST API,
# then deletes the resulting orphan person records. Same regex as v1.9.2's
# actress cleanup so the two flows agree on what counts as broken data.
# Body: { dryRun?: bool }
Add-PodeRoute -Method Post -Path '/api/jellyfin/cleanup-mojibake' -ScriptBlock {
    try {
        $settings = Get-PodeState -Name 'settings'
        $url = $settings.'emby.url'
        $key = $settings.'emby.apikey'
        if (-not $url -or -not $key) {
            Write-PodeJsonResponse -Value @{ error = 'emby.url and emby.apikey must be configured' } -StatusCode 400
            return
        }

        $body = $WebEvent.Data
        $jobArgs = @{
            embyUrl    = $url
            embyApiKey = $key
            dryRun     = [bool]$body.dryRun
        }

        $libDir = $env:JVWEB_LIB
        $manifestPath = $env:JVWEB_MANIFEST
        $job = Start-JVJob -Kind 'jellyfin-mojibake-cleanup' -ModulePath $manifestPath -LibDir $libDir `
            -Arguments $jobArgs -WorkerFunction 'Invoke-JVJellyfinMojibakeCleanupWorker'

        Write-PodeJsonResponse -Value @{ jobId = $job.jobId }
    } catch {
        Write-PodeHost "jellyfin cleanup-mojibake error: $PSItem`n$($_.ScriptStackTrace)" -ForegroundColor Red
        Write-PodeJsonResponse -Value @{ error = "$($PSItem.Exception.Message)" } -StatusCode 500
    }
}

# POST /api/jellyfin/sync-actresses — start a background sync job.
# Body: { fields?: ['Photo','Bio','Birthdate','Aliases'], replaceExisting?, mergeDuplicates?, dryRun? }
Add-PodeRoute -Method Post -Path '/api/jellyfin/sync-actresses' -ScriptBlock {
    try {
        $settings = Get-PodeState -Name 'settings'
        $url = $settings.'emby.url'
        $key = $settings.'emby.apikey'
        if (-not $url -or -not $key) {
            Write-PodeJsonResponse -Value @{ error = 'emby.url and emby.apikey must be configured' } -StatusCode 400
            return
        }

        $body = $WebEvent.Data
        $fields = if ($body.fields) { @($body.fields) } else { @('Photo','Bio','Birthdate','Aliases') }
        $parallelism = if ($body.parallelism) { [int]$body.parallelism }
                       elseif ($settings.'actresses.sync.parallelism') { [int]$settings.'actresses.sync.parallelism' }
                       else { 6 }
        if ($parallelism -lt 1) { $parallelism = 1 }
        if ($parallelism -gt 32) { $parallelism = 32 }

        $jobArgs = @{
            embyUrl          = $url
            embyApiKey       = $key
            fields           = $fields
            replaceExisting  = [bool]$body.replaceExisting
            mergeDuplicates  = [bool]$body.mergeDuplicates
            dryRun           = [bool]$body.dryRun
            parallelism      = $parallelism
        }

        $libDir = $env:JVWEB_LIB
        $manifestPath = $env:JVWEB_MANIFEST
        $job = Start-JVJob -Kind 'jellyfin-sync' -ModulePath $manifestPath -LibDir $libDir `
            -Arguments $jobArgs -WorkerFunction 'Invoke-JVJellyfinSyncWorker'

        Write-PodeJsonResponse -Value @{ jobId = $job.jobId }
    } catch {
        Write-PodeHost "jellyfin sync error: $PSItem`n$($_.ScriptStackTrace)" -ForegroundColor Red
        Write-PodeJsonResponse -Value @{ error = "$($PSItem.Exception.Message)" } -StatusCode 500
    }
}
