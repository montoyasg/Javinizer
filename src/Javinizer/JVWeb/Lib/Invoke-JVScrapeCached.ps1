function Invoke-JVScrapeCached {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Id,

        [Parameter()]
        [string]$Url,

        [Parameter()]
        [hashtable]$Cache,

        [Parameter()]
        [object]$Settings
    )

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

    # Direct URL path - dispatch by domain.
    if ($Url) {
        if ($Url -match 'javdb\.com') {
            $data = Invoke-JavdbBranch -Url $Url -Settings $Settings
        } else {
            $data = Get-R18DevData -Url $Url -ErrorAction SilentlyContinue
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
        [object]$Settings
    )

    $sessionInfo = $null
    try {
        $sessionInfo = Get-JavdbSession -Settings $Settings -PassThru -ErrorAction Stop
    } catch {
        Write-PodeHost "javdb fallback: could not resolve session: $PSItem" -ForegroundColor Yellow
        return $null
    }

    if (-not $sessionInfo -or -not $sessionInfo.Session) { return $null }
    $cookie = $sessionInfo.Session
    $cfClear = $sessionInfo.CfClearance

    try {
        if ($Url) {
            return Get-JavdbData -Url $Url -Session $cookie -CfClearance $cfClear -ErrorAction Stop
        }

        $urlObj = Get-JavdbUrl -Id $Id -Session $cookie -CfClearance $cfClear -ErrorAction SilentlyContinue
        if (-not $urlObj) { return $null }
        return Get-JavdbData -Url $urlObj.En -Session $cookie -CfClearance $cfClear -ErrorAction Stop
    } catch {
        if ("$PSItem" -match 'JavdbAuthRequired') {
            try {
                Write-PodeHost "javdb session rejected (403). Re-capturing..." -ForegroundColor Yellow
                $refreshed = Get-JavdbSession -Force -PassThru
                if ($refreshed -and $refreshed.Session) {
                    if ($Url) {
                        return Get-JavdbData -Url $Url -Session $refreshed.Session -CfClearance $refreshed.CfClearance -ErrorAction Stop
                    }
                    $urlObj = Get-JavdbUrl -Id $Id -Session $refreshed.Session -CfClearance $refreshed.CfClearance -ErrorAction SilentlyContinue
                    if ($urlObj) {
                        return Get-JavdbData -Url $urlObj.En -Session $refreshed.Session -CfClearance $refreshed.CfClearance -ErrorAction Stop
                    }
                }
            } catch {
                Write-PodeHost "javdb re-capture failed: $PSItem" -ForegroundColor Red
            }
        } else {
            Write-PodeHost "javdb fallback error: $PSItem" -ForegroundColor Yellow
        }
        return $null
    }
}
