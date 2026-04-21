Add-PodeRoute -Method Post -Path '/api/scrape' -ScriptBlock {
    try {
        $body = $WebEvent.Data
        $path = $body.path

        if ([string]::IsNullOrWhiteSpace($path)) {
            Write-PodeJsonResponse -Value @{ error = 'path is required' } -StatusCode 400
            return
        }

        $file = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
        if (-not $file) {
            Write-PodeJsonResponse -Value @{ error = "File not found: $path" } -StatusCode 404
            return
        }

        $settings = Get-PodeState -Name 'settings'
        $cache = Get-PodeState -Name 'scrapeCache'

        $id = Resolve-JVContentId -File $file -Settings $settings
        if (-not $id) {
            Write-PodeJsonResponse -Value @{ error = "Could not extract content ID from filename [$($file.Name)]" } -StatusCode 404
            return
        }

        $data = Invoke-JVScrapeCached -Id $id -Cache $cache -Settings $settings
        if (-not $data) {
            $msg = Get-JVScrapeNotFoundMessage -Id $id -Settings $settings
            Write-PodeJsonResponse -Value @{ error = $msg } -StatusCode 404
            return
        }

        Write-PodeJsonResponse -Value @{
            source      = $file.FullName
            extractedId = $id
            data        = $data
        }
    } catch {
        Write-PodeHost "scrape error: $PSItem`n$($_.ScriptStackTrace)" -ForegroundColor Red
        Write-PodeJsonResponse -Value @{ error = "$($PSItem.Exception.Message)" } -StatusCode 500
    }
}

Add-PodeRoute -Method Post -Path '/api/manual-search' -ScriptBlock {
    try {
        $body = $WebEvent.Data
        $query = $body.query

        if ([string]::IsNullOrWhiteSpace($query)) {
            Write-PodeJsonResponse -Value @{ error = 'query is required (ID or URL)' } -StatusCode 400
            return
        }

        $settings = Get-PodeState -Name 'settings'
        $cache = Get-PodeState -Name 'scrapeCache'

        if ($query -match '^https?://') {
            $data = Invoke-JVScrapeCached -Id '' -Url $query -Cache $cache -Settings $settings
        } else {
            $data = Invoke-JVScrapeCached -Id $query -Cache $cache -Settings $settings
        }

        if (-not $data) {
            $msg = Get-JVScrapeNotFoundMessage -Id $query -Settings $settings
            Write-PodeJsonResponse -Value @{ error = $msg } -StatusCode 404
            return
        }

        Write-PodeJsonResponse -Value @{ data = $data }
    } catch {
        Write-PodeHost "manual-search error: $PSItem`n$($_.ScriptStackTrace)" -ForegroundColor Red
        Write-PodeJsonResponse -Value @{ error = "$($PSItem.Exception.Message)" } -StatusCode 500
    }
}

Add-PodeRoute -Method Post -Path '/api/screens' -ScriptBlock {
    try {
        $body = $WebEvent.Data
        $path = $body.path

        if ([string]::IsNullOrWhiteSpace($path)) {
            Write-PodeJsonResponse -Value @{ error = 'path is required' } -StatusCode 400
            return
        }

        $file = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
        if (-not $file) {
            Write-PodeJsonResponse -Value @{ error = "File not found: $path" } -StatusCode 404
            return
        }

        $settings = Get-PodeState -Name 'settings'
        $cache = Get-PodeState -Name 'scrapeCache'

        $id = Resolve-JVContentId -File $file -Settings $settings
        if (-not $id) {
            Write-PodeJsonResponse -Value @{ error = "Could not extract content ID" } -StatusCode 404
            return
        }

        $data = Invoke-JVScrapeCached -Id $id -Cache $cache -Settings $settings
        if (-not $data) {
            $msg = Get-JVScrapeNotFoundMessage -Id $id -Settings $settings
            Write-PodeJsonResponse -Value @{ error = $msg } -StatusCode 404
            return
        }

        Write-PodeJsonResponse -Value @{ screenshots = @($data.ScreenshotUrl) }
    } catch {
        Write-PodeHost "screens error: $PSItem`n$($_.ScriptStackTrace)" -ForegroundColor Red
        Write-PodeJsonResponse -Value @{ error = "$($PSItem.Exception.Message)" } -StatusCode 500
    }
}

Add-PodeRoute -Method Post -Path '/api/javdb/session/refresh' -ScriptBlock {
    try {
        $settings = Get-PodeState -Name 'settings'
        $body = $WebEvent.Data
        $mode = 'Anonymous'
        if ($body -and $body.mode) {
            $m = "$($body.mode)".Trim()
            if ($m -ieq 'login')     { $mode = 'Login' }
            elseif ($m -ieq 'anonymous') { $mode = 'Anonymous' }
        }

        $info = Get-JavdbSession -Force -Settings $settings -PassThru -Mode $mode
        $hasAny = $info -and ($info.Session -or $info.CfClearance)
        if (-not $hasAny) {
            Write-PodeJsonResponse -Value @{ error = 'Session capture returned no cookies.' } -StatusCode 500
            return
        }
        $src = $null
        try { $src = $info.Source } catch {}
        Write-PodeJsonResponse -Value @{
            status     = 'ok'
            source     = $src
            mode       = $mode.ToLower()
            capturedAt = $info.CapturedAt
            expiresAt  = $info.ExpiresAt
        }
    } catch {
        Write-PodeHost "javdb session refresh error: $PSItem`n$($_.ScriptStackTrace)" -ForegroundColor Red
        Write-PodeJsonResponse -Value @{ error = "$($PSItem.Exception.Message)" } -StatusCode 500
    }
}

Add-PodeRoute -Method Get -Path '/api/javdb/session/status' -ScriptBlock {
    try {
        $cachePath = Get-JavdbSessionCachePath
        $present = $false
        $source = $null
        $capturedAt = $null
        $expiresAt = $null
        if (Test-Path -LiteralPath $cachePath) {
            try {
                $cached = Get-Content -LiteralPath $cachePath -Raw | ConvertFrom-Json
                if ($cached -is [Array]) {
                    $cached = @($cached | Where-Object { $_ -and $_.PSObject.Properties['Session'] -and $_.Session })[-1]
                }
                if ($cached -and $cached.Session) {
                    $present = $true
                    try { $source = $cached.Source } catch {}
                    try { $capturedAt = $cached.CapturedAt } catch {}
                    try { $expiresAt = $cached.ExpiresAt } catch {}
                }
            } catch {}
        }
        Write-PodeJsonResponse -Value @{
            present    = $present
            source     = $source
            capturedAt = $capturedAt
            expiresAt  = $expiresAt
        }
    } catch {
        Write-PodeHost "javdb session status error: $PSItem`n$($_.ScriptStackTrace)" -ForegroundColor Red
        Write-PodeJsonResponse -Value @{ error = "$($PSItem.Exception.Message)" } -StatusCode 500
    }
}

