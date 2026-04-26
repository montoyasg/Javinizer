Add-PodeRoute -Method Get -Path '/api/jobs/:id' -ScriptBlock {
    try {
        $id = $WebEvent.Parameters['id']
        if (-not $id) {
            Write-PodeJsonResponse -Value @{ error = 'job id required' } -StatusCode 400
            return
        }
        $state = Get-JVJobState -JobId $id
        if (-not $state) {
            Write-PodeJsonResponse -Value @{ error = 'not found' } -StatusCode 404
            return
        }
        # Derive `stalledFor` (seconds since `current` last changed). Lets the
        # UI show "stuck retrying" without auto-failing the job. Only emit
        # while the job is actively running.
        if ($state.status -eq 'running' -and $state.progress.updatedAt) {
            try {
                $u = if ($state.progress.updatedAt -is [DateTime]) {
                    $state.progress.updatedAt.ToUniversalTime()
                } else {
                    [DateTime]::Parse([string]$state.progress.updatedAt, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
                }
                $state.progress.stalledFor = [int]((Get-Date).ToUniversalTime() - $u).TotalSeconds
            } catch { $state.progress.stalledFor = 0 }
        }
        Write-PodeJsonResponse -Value $state
    } catch {
        Write-PodeHost "jobs GET error: $PSItem`n$($_.ScriptStackTrace)" -ForegroundColor Red
        Write-PodeJsonResponse -Value @{ error = "$($PSItem.Exception.Message)" } -StatusCode 500
    }
}

Add-PodeRoute -Method Post -Path '/api/jobs/:id/cancel' -ScriptBlock {
    try {
        $id = $WebEvent.Parameters['id']
        if (-not $id) {
            Write-PodeJsonResponse -Value @{ error = 'job id required' } -StatusCode 400
            return
        }
        $state = Get-JVJobState -JobId $id
        if (-not $state) {
            Write-PodeJsonResponse -Value @{ error = 'not found' } -StatusCode 404
            return
        }
        Request-JVJobCancel -JobId $id
        Write-PodeJsonResponse -Value @{ ok = $true; jobId = $id }
    } catch {
        Write-PodeHost "jobs cancel error: $PSItem`n$($_.ScriptStackTrace)" -ForegroundColor Red
        Write-PodeJsonResponse -Value @{ error = "$($PSItem.Exception.Message)" } -StatusCode 500
    }
}
