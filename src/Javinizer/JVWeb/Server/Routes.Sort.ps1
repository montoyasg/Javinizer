Add-PodeRoute -Method Post -Path '/api/sort' -ScriptBlock {
    try {
        $body = $WebEvent.Data
        $path = $body.path
        $dest = $body.destinationPath
        $overrides = $body.settingsOverride
        $flags = $body.flags
        $dataOverride = $body.data

        if ([string]::IsNullOrWhiteSpace($path) -or [string]::IsNullOrWhiteSpace($dest)) {
            Write-PodeJsonResponse -Value @{ error = 'path and destinationPath are required' } -StatusCode 400
            return
        }

        $baseSettings = Get-PodeState -Name 'settings'
        $cache = Get-PodeState -Name 'scrapeCache'

        $overrideHash = ConvertTo-JVOverrideHash -Overrides $overrides
        $effective = Get-JVEffectiveSettings -Base $baseSettings -Override $overrideHash

        $force = $false; $update = $false
        if ($flags) {
            if ($flags -is [hashtable] -or $flags -is [System.Collections.IDictionary]) {
                $force = [bool]$flags['force']
                $update = [bool]$flags['update']
            } else {
                $force = [bool]$flags.force
                $update = [bool]$flags.update
            }
        }

        $result = Invoke-JVSortOne -Path $path -DestinationPath $dest -Settings $effective -Data $dataOverride -Cache $cache -Force:$force -Update:$update

        if (-not $result.ok) {
            Write-PodeJsonResponse -Value @{ error = $result.error; folderPath = $result.folderPath; filePath = $result.filePath } -StatusCode 500
            return
        }

        Write-PodeJsonResponse -Value @{
            moved      = $true
            folderPath = $result.folderPath
            filePath   = $result.filePath
            id         = $result.id
            warnings   = @($result.warnings)
        }
    } catch {
        Write-PodeHost "sort error: $PSItem`n$($_.ScriptStackTrace)" -ForegroundColor Red
        Write-PodeJsonResponse -Value @{ error = "$($PSItem.Exception.Message)" } -StatusCode 500
    }
}
