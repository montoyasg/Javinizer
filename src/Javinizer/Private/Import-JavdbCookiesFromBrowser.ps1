function Import-JavdbCookiesFromBrowser {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateSet('chrome', 'chromium', 'edge', 'brave', 'firefox', 'opera', 'safari')]
        [string]$Browser
    )

    $python = $env:PYTHON
    if (-not $python) {
        $cmd = Get-Command python3 -ErrorAction SilentlyContinue
        if (-not $cmd) { $cmd = Get-Command python -ErrorAction SilentlyContinue }
        if (-not $cmd) {
            throw "Python 3 is required to read cookies from $Browser. Install python3 and `pip3 install browser_cookie3`, or set `$env:PYTHON` to the python executable."
        }
        $python = $cmd.Source
    }

    $helper = Join-Path $PSScriptRoot 'helpers/browser_cookies.py'
    if (-not (Test-Path -LiteralPath $helper)) {
        throw "browser_cookies.py helper not found at [$helper]."
    }

    $stderrFile = [System.IO.Path]::GetTempFileName()
    try {
        $stdout = & $python $helper $Browser 2>$stderrFile
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) {
            $errMsg = ''
            try { $errMsg = (Get-Content -LiteralPath $stderrFile -Raw).Trim() } catch {}
            throw "browser_cookies.py exited with code ${exitCode}: $errMsg"
        }
    } finally {
        Remove-Item -LiteralPath $stderrFile -ErrorAction SilentlyContinue
    }

    $payload = $null
    try {
        $payload = $stdout | ConvertFrom-Json
    } catch {
        throw "Failed to parse JSON from browser_cookies.py: $PSItem"
    }

    if (-not $payload.session) {
        throw "No _jdb_session cookie found in $Browser. Log into javdb.com in $Browser first, then retry."
    }

    # Browser-extracted cookies inherit the UA of the browser they came from; surface
    # the Chrome-120 UA by default so downstream requests stay on one fingerprint.
    $ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'

    [PSCustomObject]@{
        Session       = $payload.session
        CfClearance   = $payload.cf_clearance
        RememberToken = $payload.remember
        UserAgent     = $ua
        Source        = $payload.source
        CapturedAt    = (Get-Date).ToUniversalTime().ToString('o')
        ExpiresAt     = (Get-Date).AddDays(30).ToUniversalTime().ToString('o')
    }
}
