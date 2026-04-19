Add-PodeRoute -Method Post -Path '/api/preview' -ScriptBlock {
    try {
        $body = $WebEvent.Data
        $path = $body.path
        $dest = $body.destinationPath
        $overrides = $body.settingsOverride

        if ([string]::IsNullOrWhiteSpace($path) -or [string]::IsNullOrWhiteSpace($dest)) {
            Write-PodeJsonResponse -Value @{ error = 'path and destinationPath are required' } -StatusCode 400
            return
        }

        $baseSettings = Get-PodeState -Name 'settings'
        $cache = Get-PodeState -Name 'scrapeCache'

        $overrideHash = ConvertTo-JVOverrideHash -Overrides $overrides
        $effective = Get-JVEffectiveSettings -Base $baseSettings -Override $overrideHash

        $result = Resolve-JVPreviewOne -Path $path -DestinationPath $dest -Settings $effective -Cache $cache

        if (-not $result.ok) {
            Write-PodeJsonResponse -Value @{ error = $result.reason } -StatusCode 404
            return
        }

        Write-PodeJsonResponse -Value @{
            folderPath = $result.folderPath
            filePath   = $result.filePath
            leaves     = $result.leaves
            id         = $result.id
        }
    } catch {
        Write-PodeHost "preview error: $PSItem`n$($_.ScriptStackTrace)" -ForegroundColor Red
        Write-PodeJsonResponse -Value @{ error = "$($PSItem.Exception.Message)" } -StatusCode 500
    }
}

Add-PodeRoute -Method Post -Path '/api/preview-tree' -ScriptBlock {
    try {
        $body = $WebEvent.Data
        $paths = @($body.paths)
        $dest = $body.destinationPath
        $overrides = $body.settingsOverride

        if ($paths.Count -eq 0 -or [string]::IsNullOrWhiteSpace($dest)) {
            Write-PodeJsonResponse -Value @{ error = 'paths (array) and destinationPath are required' } -StatusCode 400
            return
        }

        $baseSettings = Get-PodeState -Name 'settings'
        $cache = Get-PodeState -Name 'scrapeCache'

        $overrideHash = ConvertTo-JVOverrideHash -Overrides $overrides
        $effective = Get-JVEffectiveSettings -Base $baseSettings -Override $overrideHash

        $result = Resolve-JVPreviewTree -Paths $paths -DestinationPath $dest -Settings $effective -Cache $cache

        Write-PodeJsonResponse -Value $result -Depth 32
    } catch {
        Write-PodeHost "preview-tree error: $PSItem`n$($_.ScriptStackTrace)" -ForegroundColor Red
        Write-PodeJsonResponse -Value @{ error = "$($PSItem.Exception.Message)" } -StatusCode 500
    }
}
