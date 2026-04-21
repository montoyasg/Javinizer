function Invoke-JavdbSessionCapture {
    [CmdletBinding()]
    param (
        [Parameter()]
        [ValidateSet('Anonymous', 'Login')]
        [string]$Mode = 'Anonymous',

        [Parameter()]
        [Int]$TimeoutSeconds,

        [Parameter()]
        [Object]$Headless,

        [Parameter()]
        [string]$UserDataDir
    )

    if ($PSVersionTable.PSVersion.Major -lt 7) {
        throw 'Invoke-JavdbSessionCapture requires PowerShell 7.2 or newer (Playwright .NET targets .NET 6+).'
    }

    try {
        $null = [Microsoft.Playwright.Playwright]
    } catch {
        throw @'
Microsoft.Playwright assembly is not loaded. Install it with:

  dotnet new console -o ~/.javinizer/playwright
  cd ~/.javinizer/playwright
  dotnet add package Microsoft.Playwright
  dotnet build
  pwsh bin/Debug/net*/playwright.ps1 install chromium

Then add the built DLL path to $env:PSModulePath or load it via Add-Type -Path.
See https://playwright.dev/dotnet/docs/intro for details.
'@
    }

    if (-not $PSBoundParameters.ContainsKey('TimeoutSeconds')) {
        $TimeoutSeconds = if ($Mode -eq 'Login') { 300 } else { 60 }
    }

    # Headless default:
    #   - Anonymous: always headless (no user interaction needed).
    #   - Login: TTY-aware (headed in terminals, headless under redirected stdin).
    #   Explicit -Headless and $env:JVWEB_HEADLESS override both.
    $resolvedHeadless = $null
    if ($PSBoundParameters.ContainsKey('Headless') -and $null -ne $Headless) {
        $resolvedHeadless = [bool]$Headless
    } elseif ($env:JVWEB_HEADLESS) {
        $resolvedHeadless = ($env:JVWEB_HEADLESS -eq '1' -or $env:JVWEB_HEADLESS -ieq 'true')
    } elseif ($Mode -eq 'Anonymous') {
        $resolvedHeadless = $true
    } else {
        $interactive = $false
        try { $interactive = (-not [Console]::IsInputRedirected) -and ($null -ne $Host.UI.RawUI) } catch {}
        $resolvedHeadless = -not $interactive
    }

    if (-not $UserDataDir) {
        $isWin = ($IsWindows -or ($null -eq $IsWindows -and $env:OS -eq 'Windows_NT'))
        $cfgRoot = if ($isWin) {
            if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'Javinizer' } else { Join-Path $HOME '.javinizer' }
        } else {
            Join-Path $HOME '.config/Javinizer'
        }
        $UserDataDir = Join-Path $cfgRoot 'playwright-profile'
    }
    if (-not (Test-Path -LiteralPath $UserDataDir)) {
        New-Item -ItemType Directory -Path $UserDataDir -Force | Out-Null
    }

    $userAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'

    $playwright = $null
    $context = $null
    $page = $null
    $result = $null

    try {
        $playwright = [Microsoft.Playwright.Playwright]::CreateAsync().GetAwaiter().GetResult()

        $launchOpts = New-Object Microsoft.Playwright.BrowserTypeLaunchPersistentContextOptions
        $launchOpts.Headless = [bool]$resolvedHeadless
        $launchOpts.Args = [string[]]@(
            '--no-sandbox',
            '--disable-dev-shm-usage',
            '--disable-gpu',
            '--disable-blink-features=AutomationControlled'
        )
        $launchOpts.IgnoreDefaultArgs = [string[]]@('--enable-automation')
        $launchOpts.UserAgent = $userAgent
        $launchOpts.Locale = 'en-US'
        $launchOpts.TimezoneId = 'America/Los_Angeles'
        try {
            $vp = New-Object Microsoft.Playwright.ViewportSize
            $vp.Width = 1920
            $vp.Height = 1080
            $launchOpts.ViewportSize = $vp
        } catch {}

        $context = $playwright.Chromium.LaunchPersistentContextAsync($UserDataDir, $launchOpts).GetAwaiter().GetResult()

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

        if ($context.Pages -and $context.Pages.Count -gt 0) {
            $page = $context.Pages[0]
        } else {
            $page = $context.NewPageAsync().GetAwaiter().GetResult()
        }

        $targetUrl = if ($Mode -eq 'Login') { 'https://javdb.com/login' } else { 'https://javdb.com/' }
        $msg = if ($Mode -eq 'Login') {
            "[$($MyInvocation.MyCommand.Name)] Opening Chromium to $targetUrl - please sign in to continue."
        } else {
            "[$($MyInvocation.MyCommand.Name)] Capturing anonymous javdb session via $targetUrl (headless, no sign-in needed)."
        }
        Write-JVLog -Write:$script:JVLogWrite -LogPath $script:JVLogPath -WriteLevel $script:JVLogWriteLevel -Level Info -Message $msg
        $page.GotoAsync($targetUrl).GetAwaiter().GetResult() | Out-Null

        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        $session = $null
        $cfClearance = $null
        $rememberToken = $null

        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 1
            $cookies = $context.CookiesAsync().GetAwaiter().GetResult()
            $currentUrl = ''
            try { $currentUrl = $page.Url } catch {}

            foreach ($c in $cookies) {
                switch ($c.Name) {
                    '_jdb_session'       { $session = $c.Value }
                    'cf_clearance'       { $cfClearance = $c.Value }
                    'remember_me_token'  { $rememberToken = $c.Value }
                }
            }

            if ($Mode -eq 'Login') {
                $loggedIn = $false
                if ($session -and ($rememberToken -or ($currentUrl -and $currentUrl -notmatch '/login'))) {
                    if ($currentUrl -and $currentUrl -notmatch '/login') { $loggedIn = $true }
                }
                if ($loggedIn -and $session) { break }
            } else {
                # Anonymous: cf_clearance is the must-have (it's what CF actually gates on).
                # A guest _jdb_session usually appears alongside; wait briefly for it, but
                # don't block forever on it.
                if ($cfClearance) {
                    if ($session) { break }
                    # Give _jdb_session a short grace period after cf_clearance appears.
                    Start-Sleep -Milliseconds 1500
                    $cookies2 = $context.CookiesAsync().GetAwaiter().GetResult()
                    foreach ($c in $cookies2) { if ($c.Name -eq '_jdb_session') { $session = $c.Value } }
                    break
                }
            }
        }

        if ($Mode -eq 'Login' -and -not $session) {
            throw "Timed out after ${TimeoutSeconds}s waiting for javdb login. _jdb_session was never captured."
        }
        if ($Mode -eq 'Anonymous' -and -not $cfClearance) {
            throw "Timed out after ${TimeoutSeconds}s waiting for Cloudflare clearance on javdb.com. Try again, or check that the container's outbound IP isn't on a CF block list."
        }

        $sessionLen = if ($session) { $session.Length } else { 0 }
        $cfLen = if ($cfClearance) { $cfClearance.Length } else { 0 }
        Write-JVLog -Write:$script:JVLogWrite -LogPath $script:JVLogPath -WriteLevel $script:JVLogWriteLevel -Level Info -Message "[$($MyInvocation.MyCommand.Name)] Captured javdb $Mode session (session=$sessionLen, cf_clearance=$cfLen)."

        $result = [PSCustomObject]@{
            Session       = $session
            CfClearance   = $cfClearance
            RememberToken = $rememberToken
            UserAgent     = $userAgent
            Source        = "playwright:$($Mode.ToLower())"
            CapturedAt    = (Get-Date).ToUniversalTime().ToString('o')
            ExpiresAt     = (Get-Date).AddDays(30).ToUniversalTime().ToString('o')
        }
    } finally {
        if ($page)       { try { $page.CloseAsync().GetAwaiter().GetResult() } catch {} }
        if ($context)    { try { $context.CloseAsync().GetAwaiter().GetResult() } catch {} }
        if ($playwright) { try { $playwright.Dispose() } catch {} }
    }

    Write-Output $result
}
