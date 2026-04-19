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

        $data = Invoke-JVScrapeCached -Id $id -Cache $cache
        if (-not $data) {
            Write-PodeJsonResponse -Value @{ error = "No R18.dev match for ID [$id]" } -StatusCode 404
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
            Write-PodeJsonResponse -Value @{ error = 'query is required (ID or r18.dev URL)' } -StatusCode 400
            return
        }

        $cache = Get-PodeState -Name 'scrapeCache'

        if ($query -match '^https?://') {
            $data = Invoke-JVScrapeCached -Id '' -Url $query -Cache $cache
        } else {
            $data = Invoke-JVScrapeCached -Id $query -Cache $cache
        }

        if (-not $data) {
            Write-PodeJsonResponse -Value @{ error = "No R18.dev match for [$query]" } -StatusCode 404
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

        $data = Invoke-JVScrapeCached -Id $id -Cache $cache
        if (-not $data) {
            Write-PodeJsonResponse -Value @{ error = "No R18.dev match" } -StatusCode 404
            return
        }

        Write-PodeJsonResponse -Value @{ screenshots = @($data.ScreenshotUrl) }
    } catch {
        Write-PodeHost "screens error: $PSItem`n$($_.ScriptStackTrace)" -ForegroundColor Red
        Write-PodeJsonResponse -Value @{ error = "$($PSItem.Exception.Message)" } -StatusCode 500
    }
}
