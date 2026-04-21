function Invoke-JVScrapeCached {
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowEmptyString()]
        [string]$Id,

        [Parameter()]
        [string]$Url,

        [Parameter()]
        [hashtable]$Cache,

        [Parameter()]
        [object]$Settings
    )

    if (-not $Url -and [string]::IsNullOrWhiteSpace($Id)) {
        throw 'Invoke-JVScrapeCached requires either -Id or -Url.'
    }

    $key = if ($Url) { "url:$Url" } else { "id:$($Id.ToUpper())" }

    if ($Cache -and $Cache.ContainsKey($key)) {
        return $Cache[$key]
    }

    $fallbackEnabled = $true
    if ($Settings) {
        try {
            $flag = $Settings.'web.scrape.javdb.fallback'
            if ($null -ne $flag) { $fallbackEnabled = [bool]$flag }
        } catch {}
    }

    $data = $null

    # Direct URL path - dispatch by domain. Surface errors for explicit user
    # intent; fall-through paths below keep silent failure.
    if ($Url) {
        if ($Url -match 'javdb\.com') {
            $data = Invoke-JavdbBranch -Url $Url -Settings $Settings -ThrowOnError
        } else {
            $data = Get-R18DevData -Url $Url -ErrorAction Stop
        }
    } else {
        # ID path: R18.dev primary, javdb fallback.
        $urlObj = Get-R18DevUrl -Id $Id -ErrorAction SilentlyContinue
        if ($urlObj) {
            $data = Get-R18DevData -Url $urlObj.Url -ErrorAction SilentlyContinue
        }

        if (-not $data -and $fallbackEnabled) {
            $data = Invoke-JavdbBranch -Id $Id -Settings $Settings
        }
    }

    if (-not $data) { return $null }

    if ($Cache) {
        $Cache[$key] = $data
        if ($data.Id) { $Cache["id:$($data.Id.ToUpper())"] = $data }
    }

    $data
}

function Invoke-JavdbBranch {
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$Id,

        [Parameter()]
        [string]$Url,

        [Parameter()]
        [object]$Settings,

        [Parameter()]
        [switch]$ThrowOnError
    )

    $sessionInfo = $null
    try {
        $sessionInfo = Get-JavdbSession -Settings $Settings -PassThru -ErrorAction Stop
    } catch {
        $msg = "javdb: could not resolve session: $PSItem"
        Write-PodeHost $msg -ForegroundColor Yellow
        if ($ThrowOnError) { throw $msg }
        return $null
    }

    if (-not $sessionInfo -or -not $sessionInfo.Session) {
        $msg = 'javdb: no session cookie available. Click Refresh Javdb session (or set javdb.cookie.browser / paste cookies).'
        Write-PodeHost $msg -ForegroundColor Yellow
        if ($ThrowOnError) { throw $msg }
        return $null
    }
    $cookie = $sessionInfo.Session
    $cfClear = $sessionInfo.CfClearance
    $ua = $null
    try { $ua = $sessionInfo.UserAgent } catch {}

    try {
        if ($Url) {
            return Get-JavdbData -Url $Url -Session $cookie -CfClearance $cfClear -UserAgent $ua -ErrorAction Stop
        }

        $urlObj = Get-JavdbUrl -Id $Id -Session $cookie -CfClearance $cfClear -UserAgent $ua -ErrorAction SilentlyContinue
        if (-not $urlObj) { return $null }
        return Get-JavdbData -Url $urlObj.En -Session $cookie -CfClearance $cfClear -UserAgent $ua -ErrorAction Stop
    } catch {
        if ("$PSItem" -match 'JavdbAuthRequired') {
            try {
                Write-PodeHost "javdb session rejected (403). Re-capturing..." -ForegroundColor Yellow
                $refreshed = Get-JavdbSession -Force -Settings $Settings -PassThru
                if ($refreshed -and $refreshed.Session) {
                    $rUa = $null
                    try { $rUa = $refreshed.UserAgent } catch {}
                    if ($Url) {
                        return Get-JavdbData -Url $Url -Session $refreshed.Session -CfClearance $refreshed.CfClearance -UserAgent $rUa -ErrorAction Stop
                    }
                    $urlObj = Get-JavdbUrl -Id $Id -Session $refreshed.Session -CfClearance $refreshed.CfClearance -UserAgent $rUa -ErrorAction SilentlyContinue
                    if ($urlObj) {
                        return Get-JavdbData -Url $urlObj.En -Session $refreshed.Session -CfClearance $refreshed.CfClearance -UserAgent $rUa -ErrorAction Stop
                    }
                }
                if ($ThrowOnError) { throw 'javdb: session recapture did not yield cookies' }
            } catch {
                Write-PodeHost "javdb re-capture failed: $PSItem" -ForegroundColor Red
                if ($ThrowOnError) { throw }
            }
        } else {
            Write-PodeHost "javdb error: $PSItem" -ForegroundColor Yellow
            if ($ThrowOnError) { throw }
        }
        return $null
    }
}
