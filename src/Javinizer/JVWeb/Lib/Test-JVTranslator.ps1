function Test-JVTranslator {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Settings
    )

    $module = $Settings.'sort.metadata.nfo.translate.module'
    $language = $Settings.'sort.metadata.nfo.translate.language'
    $deeplKey = $Settings.'sort.metadata.nfo.translate.deeplapikey'
    $enabled = [bool]$Settings.'sort.metadata.nfo.translate'

    if (-not $enabled) {
        return @{
            ok       = $false
            enabled  = $false
            module   = $module
            language = $language
            reason   = 'disabled'
        }
    }

    if (-not $module) {
        return @{ ok = $false; enabled = $true; reason = 'no module configured' }
    }
    if (-not $language) {
        return @{ ok = $false; enabled = $true; module = $module; reason = 'no target language configured' }
    }

    $sample = 'テスト'
    $t0 = Get-Date
    try {
        $out = Get-TranslatedString -String $sample -Language $language -Module $module -TranslateDeeplApiKey $deeplKey
        $latency = [int]((Get-Date) - $t0).TotalMilliseconds
        $trimmed = if ($null -eq $out) { '' } else { ([string]$out).Trim() }

        if (-not $trimmed) {
            return @{
                ok         = $false
                enabled    = $true
                module     = $module
                language   = $language
                latency_ms = $latency
                reason     = 'empty response (possible CAPTCHA or endpoint change)'
            }
        }
        if ($trimmed -eq $sample) {
            return @{
                ok         = $false
                enabled    = $true
                module     = $module
                language   = $language
                latency_ms = $latency
                reason     = 'translator returned original string (fallback path hit; backend unreachable or broken)'
            }
        }

        return @{
            ok         = $true
            enabled    = $true
            module     = $module
            language   = $language
            latency_ms = $latency
            sample     = @{ input = $sample; output = $trimmed }
        }
    } catch {
        $latency = [int]((Get-Date) - $t0).TotalMilliseconds
        return @{
            ok         = $false
            enabled    = $true
            module     = $module
            language   = $language
            latency_ms = $latency
            reason     = "$($_.Exception.Message)"
        }
    }
}
