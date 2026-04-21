function Invoke-GoogleWebTranslate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyString()]
        [String]$String,

        [String]$SourceLanguage = 'auto',

        [String]$TargetLanguage = 'en',

        [Int]$Timeout = 15
    )

    if ($null -eq $String -or $String -eq '') { return $String }

    if ($null -eq $script:JVTranslateCache) {
        $script:JVTranslateCache = @{}
    }
    $cacheKey = "$SourceLanguage|$TargetLanguage|$String"
    if ($script:JVTranslateCache.ContainsKey($cacheKey)) {
        return $script:JVTranslateCache[$cacheKey]
    }

    $chunkLimit = 4500
    if ($String.Length -le $chunkLimit) {
        $chunks = @($String)
    } else {
        $chunks = [System.Collections.Generic.List[String]]::new()
        $remaining = $String
        while ($remaining.Length -gt $chunkLimit) {
            $slice = $remaining.Substring(0, $chunkLimit)
            $breakAt = [Math]::Max(
                [Math]::Max($slice.LastIndexOf("`n"), $slice.LastIndexOf('. ')),
                $slice.LastIndexOf(' ')
            )
            if ($breakAt -lt 1000) { $breakAt = $chunkLimit }
            $chunks.Add($remaining.Substring(0, $breakAt))
            $remaining = $remaining.Substring($breakAt)
        }
        if ($remaining.Length -gt 0) { $chunks.Add($remaining) }
    }

    $userAgent = 'Mozilla/5.0 (Linux; Android 10) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36'
    $backoffs = @(1, 3, 9)
    $captchaMarkers = @('Our systems have detected unusual traffic', 'captcha', 'sorry/index')

    $assembled = [System.Text.StringBuilder]::new()
    foreach ($chunk in $chunks) {
        $encoded = [uri]::EscapeDataString($chunk)
        $url = "https://translate.google.com/m?tl=$TargetLanguage&sl=$SourceLanguage&q=$encoded"
        $chunkResult = $null

        foreach ($backoff in $backoffs) {
            try {
                $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -Method Get -TimeoutSec $Timeout -Headers @{
                    'User-Agent'      = $userAgent
                    'Accept-Language' = "$TargetLanguage,en;q=0.9"
                }
                $html = $resp.Content

                $looksLikeCaptcha = $false
                foreach ($m in $captchaMarkers) {
                    if ($html -match [regex]::Escape($m)) { $looksLikeCaptcha = $true; break }
                }
                if ($looksLikeCaptcha) { throw 'captcha response' }

                if ($html -match 'class="(?:t0|result-container)">(.*?)</') {
                    $chunkResult = [System.Net.WebUtility]::HtmlDecode($Matches[1])
                    break
                }
                throw 'no translation markup in response'
            } catch {
                if ($backoff -eq $backoffs[-1]) { break }
                Start-Sleep -Seconds $backoff
            }
        }

        if ($null -eq $chunkResult -or $chunkResult -eq '') {
            $script:JVTranslateCache[$cacheKey] = $String
            return $String
        }
        [void]$assembled.Append($chunkResult)
    }

    $final = $assembled.ToString()
    $script:JVTranslateCache[$cacheKey] = $final
    return $final
}
