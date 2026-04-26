# GET /api/version — returns the Javinizer module's ModuleVersion. The UI
# renders this in a bottom-left badge so it's obvious which release is
# actually running (matters when debugging "did my update apply?" or when
# diagnosing browser cache staleness).
Add-PodeRoute -Method Get -Path '/api/version' -ScriptBlock {
    try {
        $mod = Get-Module -Name 'Javinizer' | Sort-Object Version -Descending | Select-Object -First 1
        $v = if ($mod) { "$($mod.Version)" } else { 'unknown' }
        Write-PodeJsonResponse -Value @{ version = $v }
    } catch {
        Write-PodeJsonResponse -Value @{ version = 'unknown'; error = "$($PSItem.Exception.Message)" } -StatusCode 500
    }
}
