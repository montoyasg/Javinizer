Add-PodeRoute -Method Get -Path '/api/settings' -ScriptBlock {
    try {
        $whitelist = @(
            'sort.format.outputfolder'
            'sort.format.folder'
            'sort.format.file'
            'sort.format.groupactress'
            'sort.metadata.nfo.unknownactress'
            'sort.metadata.nfo.translate'
            'sort.metadata.nfo.translate.module'
            'sort.metadata.nfo.translate.language'
            'web.sort.recurse'
            'web.sort.update'
            'web.sort.force'
            'web.sort.src'
            'web.sort.dest'
            'javdb.cookie.browser'
            'javdb.cookie.session'
            'javdb.cookie.cf_clearance'
            'javdb.cookie.user_agent'
        )

        $settings = Get-PodeState -Name 'settings'
        $payload = [ordered]@{}
        foreach ($key in $whitelist) {
            if ($settings.PSObject.Properties.Name -contains $key) {
                $payload[$key] = $settings.$key
            } else {
                $payload[$key] = $null
            }
        }
        Write-PodeJsonResponse -Value @{ settings = $payload }
    } catch {
        Write-PodeHost "settings GET error: $PSItem`n$($_.ScriptStackTrace)" -ForegroundColor Red
        Write-PodeJsonResponse -Value @{ error = "$($PSItem.Exception.Message)" } -StatusCode 500
    }
}

Add-PodeRoute -Method Post -Path '/api/settings' -ScriptBlock {
    try {
        $whitelist = @(
            'sort.format.outputfolder'
            'sort.format.folder'
            'sort.format.file'
            'sort.format.groupactress'
            'sort.metadata.nfo.unknownactress'
            'sort.metadata.nfo.translate'
            'sort.metadata.nfo.translate.module'
            'sort.metadata.nfo.translate.language'
            'web.sort.recurse'
            'web.sort.update'
            'web.sort.force'
            'web.sort.src'
            'web.sort.dest'
            'javdb.cookie.browser'
            'javdb.cookie.session'
            'javdb.cookie.cf_clearance'
            'javdb.cookie.user_agent'
        )

        $body = $WebEvent.Data
        $incoming = $body.settings
        if (-not $incoming) {
            Write-PodeJsonResponse -Value @{ error = 'settings object is required' } -StatusCode 400
            return
        }

        # Pode parses JSON bodies as hashtables on PS Core. Normalize both shapes.
        $filtered = @{}
        foreach ($key in $whitelist) {
            $hasKey = $false
            $value = $null
            if ($incoming -is [System.Collections.IDictionary]) {
                if ($incoming.Contains($key)) {
                    $hasKey = $true
                    $value = $incoming[$key]
                }
            } elseif ($incoming.PSObject.Properties.Name -contains $key) {
                $hasKey = $true
                $value = $incoming.$key
            }
            if ($hasKey) { $filtered[$key] = $value }
        }

        if ($filtered.Count -eq 0) {
            Write-PodeJsonResponse -Value @{ error = 'no whitelisted keys in request' } -StatusCode 400
            return
        }

        $merged = Save-JVSettings -Update $filtered
        Set-PodeState -Name 'settings' -Value $merged | Out-Null

        $payload = [ordered]@{}
        foreach ($key in $whitelist) {
            if ($merged.PSObject.Properties.Name -contains $key) {
                $payload[$key] = $merged.$key
            } else {
                $payload[$key] = $null
            }
        }
        Write-PodeJsonResponse -Value @{ settings = $payload }
    } catch {
        Write-PodeHost "settings POST error: $PSItem`n$($_.ScriptStackTrace)" -ForegroundColor Red
        Write-PodeJsonResponse -Value @{ error = "$($PSItem.Exception.Message)" } -StatusCode 500
    }
}

Add-PodeRoute -Method Get -Path '/api/translator/health' -ScriptBlock {
    try {
        $settings = Get-PodeState -Name 'settings'
        $res = Test-JVTranslator -Settings $settings
        Write-PodeJsonResponse -Value $res
    } catch {
        Write-PodeHost "translator health error: $PSItem`n$($_.ScriptStackTrace)" -ForegroundColor Red
        Write-PodeJsonResponse -Value @{ ok = $false; error = "$($PSItem.Exception.Message)" } -StatusCode 500
    }
}
