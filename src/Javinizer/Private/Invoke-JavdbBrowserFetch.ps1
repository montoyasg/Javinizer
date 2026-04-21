function Invoke-JavdbBrowserFetch {
    <#
    .SYNOPSIS
    Fetches a javdb.com URL through a short-lived Playwright Chromium so the
    TLS/HTTP2 fingerprint matches the browser that originally issued the
    cf_clearance cookie. Returns a PSCustomObject shaped like
    Invoke-WebRequest output (Content + Links + StatusCode).
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Uri,

        [Parameter()]
        [Microsoft.PowerShell.Commands.WebRequestSession]$WebSession,

        [Parameter()]
        [string]$UserAgent,

        [Parameter()]
        [int]$NavigationTimeoutMs = 30000
    )

    if ($PSVersionTable.PSVersion.Major -lt 7) {
        throw 'Invoke-JavdbBrowserFetch requires PowerShell 7.2 or newer (Playwright .NET targets .NET 6+).'
    }
    try {
        $null = [Microsoft.Playwright.Playwright]
    } catch {
        throw 'Microsoft.Playwright assembly is not loaded; cannot run browser fallback. See Invoke-JavdbSessionCapture for install instructions.'
    }

    if (-not $UserAgent) {
        $UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
    }

    $isWin = ($IsWindows -or ($null -eq $IsWindows -and $env:OS -eq 'Windows_NT'))
    $cfgRoot = if ($isWin) {
        if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'Javinizer' } else { Join-Path $HOME '.javinizer' }
    } else {
        Join-Path $HOME '.config/Javinizer'
    }
    $userDataDir = Join-Path $cfgRoot 'playwright-profile'
    if (-not (Test-Path -LiteralPath $userDataDir)) {
        New-Item -ItemType Directory -Path $userDataDir -Force | Out-Null
    }

    $playwrightCookies = New-Object 'System.Collections.Generic.List[Microsoft.Playwright.Cookie]'
    if ($WebSession -and $WebSession.Cookies) {
        foreach ($c in $WebSession.Cookies.GetCookies('https://javdb.com')) {
            $pwc = New-Object Microsoft.Playwright.Cookie
            $pwc.Name = $c.Name
            $pwc.Value = $c.Value
            $pwc.Domain = if ($c.Domain) { $c.Domain } else { '.javdb.com' }
            $pwc.Path = if ($c.Path) { $c.Path } else { '/' }
            $pwc.Secure = [bool]$c.Secure
            $pwc.HttpOnly = [bool]$c.HttpOnly
            $playwrightCookies.Add($pwc)
        }
    }

    $playwright = $null
    $context = $null
    $page = $null

    try {
        $playwright = [Microsoft.Playwright.Playwright]::CreateAsync().GetAwaiter().GetResult()

        $launchOpts = New-Object Microsoft.Playwright.BrowserTypeLaunchPersistentContextOptions
        $launchOpts.Headless = $true
        $launchOpts.Args = [string[]]@(
            '--no-sandbox',
            '--disable-dev-shm-usage',
            '--disable-gpu',
            '--disable-blink-features=AutomationControlled'
        )
        $launchOpts.IgnoreDefaultArgs = [string[]]@('--enable-automation')
        $launchOpts.UserAgent = $UserAgent
        $launchOpts.Locale = 'en-US'
        $launchOpts.TimezoneId = 'America/Los_Angeles'
        try {
            $vp = New-Object Microsoft.Playwright.ViewportSize
            $vp.Width = 1920
            $vp.Height = 1080
            $launchOpts.ViewportSize = $vp
        } catch {}

        $context = $playwright.Chromium.LaunchPersistentContextAsync($userDataDir, $launchOpts).GetAwaiter().GetResult()

        $initScript = @'
Object.defineProperty(navigator, 'webdriver', { get: () => undefined });
Object.defineProperty(navigator, 'languages', { get: () => ['en-US', 'en'] });
Object.defineProperty(navigator, 'plugins', {
    get: () => [
        { name: 'Chrome PDF Plugin', filename: 'internal-pdf-viewer', description: 'Portable Document Format' },
        { name: 'Chrome PDF Viewer', filename: 'mhjfbmdgcfjbbpaeojofohoefgiehjai', description: '' },
        { name: 'Native Client', filename: 'internal-nacl-plugin', description: '' }
    ]
});
if (!window.chrome) { window.chrome = {}; }
if (!window.chrome.runtime) { window.chrome.runtime = {}; }
'@
        $context.AddInitScriptAsync($initScript).GetAwaiter().GetResult() | Out-Null

        if ($playwrightCookies.Count -gt 0) {
            $context.AddCookiesAsync($playwrightCookies).GetAwaiter().GetResult() | Out-Null
        }

        if ($context.Pages -and $context.Pages.Count -gt 0) {
            $page = $context.Pages[0]
        } else {
            $page = $context.NewPageAsync().GetAwaiter().GetResult()
        }

        $gotoOpts = New-Object Microsoft.Playwright.PageGotoOptions
        $gotoOpts.WaitUntil = [Microsoft.Playwright.WaitUntilState]::DOMContentLoaded
        $gotoOpts.Timeout = $NavigationTimeoutMs

        $response = $page.GotoAsync($Uri, $gotoOpts).GetAwaiter().GetResult()
        $status = if ($response) { [int]$response.Status } else { 0 }

        if ($status -ge 400) {
            throw "Browser fetch returned HTTP $status for [$Uri]."
        }

        $html = $page.ContentAsync().GetAwaiter().GetResult()

        $linksScript = @"
Array.from(document.querySelectorAll('a')).map(a => ({
    title: a.title || null,
    href: a.getAttribute('href') || '',
    outerHTML: a.outerHTML
}))
"@
        $linksRaw = $null
        try {
            $linksRaw = $page.EvaluateAsync($linksScript).GetAwaiter().GetResult()
        } catch {
            $linksRaw = $null
        }

        $links = @()
        if ($linksRaw) {
            # EvaluateAsync returns JsonElement-ish objects in PW.NET; round-trip via JSON for uniform access.
            try {
                $json = $linksRaw.ToString()
                $links = @($json | ConvertFrom-Json)
            } catch {
                $links = @()
            }
        }

        [PSCustomObject]@{
            Content    = $html
            Links      = $links
            StatusCode = $status
        }
    } finally {
        if ($page)       { try { $page.CloseAsync().GetAwaiter().GetResult() } catch {} }
        if ($context)    { try { $context.CloseAsync().GetAwaiter().GetResult() } catch {} }
        if ($playwright) { try { $playwright.Dispose() } catch {} }
    }
}
