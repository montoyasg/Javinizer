function Invoke-JavdbRequest {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, Position = 0)]
        [String]$Uri,

        [Parameter()]
        [Microsoft.PowerShell.Commands.WebRequestSession]$WebSession,

        [Parameter()]
        [String]$UserAgent,

        [Parameter()]
        [Int]$MaxRetries = 3
    )

    if (-not $UserAgent) {
        $UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
    }

    # Cloudflare binds cf_clearance to the exact request fingerprint (UA +
    # client-hint / fetch-metadata headers) that solved the challenge, so we
    # send the full Chrome 120 suite instead of PowerShell's minimal defaults.
    $browserHeaders = @{
        'Accept'                    = 'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7'
        'Accept-Language'           = 'en-US,en;q=0.9'
        'Accept-Encoding'           = 'gzip, deflate, br'
        'Cache-Control'             = 'max-age=0'
        'Upgrade-Insecure-Requests' = '1'
        'Sec-Fetch-Dest'            = 'document'
        'Sec-Fetch-Mode'            = 'navigate'
        'Sec-Fetch-Site'            = 'none'
        'Sec-Fetch-User'            = '?1'
        'Sec-CH-UA'                 = '"Not_A Brand";v="8", "Chromium";v="120", "Google Chrome";v="120"'
        'Sec-CH-UA-Mobile'          = '?0'
        'Sec-CH-UA-Platform'        = '"Windows"'
    }

    $retryStatuses = @(403, 429, 500, 502, 503)
    $attempt = 0
    $lastError = $null

    while ($attempt -lt $MaxRetries) {
        $attempt++
        try {
            $params = @{
                Uri         = $Uri
                Method      = 'Get'
                UserAgent   = $UserAgent
                Headers     = $browserHeaders
                Verbose     = $false
                ErrorAction = 'Stop'
            }
            if ($WebSession) { $params['WebSession'] = $WebSession }

            return Invoke-WebRequest @params
        } catch {
            $lastError = $_
            $status = $null
            try { $status = [int]$_.Exception.Response.StatusCode } catch {}

            if ($status -and ($retryStatuses -contains $status) -and $attempt -lt $MaxRetries) {
                $sleep = (2 * $attempt) + (Get-Random -Minimum 0 -Maximum 2)
                Write-JVLog -Write:$script:JVLogWrite -LogPath $script:JVLogPath -WriteLevel $script:JVLogWriteLevel -Level Debug -Message "[$($MyInvocation.MyCommand.Name)] HTTP $status on [$Uri], attempt $attempt/$MaxRetries, sleeping ${sleep}s"
                Start-Sleep -Seconds $sleep
                continue
            }

            if ($status -eq 403) {
                $hasSession = $false
                if ($WebSession -and $WebSession.Cookies.Count -gt 0) {
                    foreach ($c in $WebSession.Cookies.GetCookies('https://javdb.com')) {
                        if ($c.Name -eq '_jdb_session' -and $c.Value) { $hasSession = $true; break }
                    }
                }
                if (-not $hasSession) {
                    throw "JavdbAuthRequired: 403 on [$Uri]. Set javdb.cookie.session or run Get-JavdbSession -Force."
                }
            }

            throw $lastError
        }
    }

    throw $lastError
}
