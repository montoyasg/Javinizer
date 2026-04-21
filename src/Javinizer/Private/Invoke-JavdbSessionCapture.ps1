function Invoke-JavdbSessionCapture {
    [CmdletBinding()]
    param (
        [Parameter()]
        [Int]$TimeoutSeconds = 300,

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

    # TTY-aware headless default: env JVWEB_HEADLESS wins; then unattended shells
    # (redirected stdin) get headless; interactive terminals get a visible window.
    $resolvedHeadless = $null
    if ($PSBoundParameters.ContainsKey('Headless') -and $null -ne $Headless) {
        $resolvedHeadless = [bool]$Headless
    } elseif ($env:JVWEB_HEADLESS) {
        $resolvedHeadless = ($env:JVWEB_HEADLESS -eq '1' -or $env:JVWEB_HEADLESS -ieq 'true')
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

        Write-JVLog -Write:$script:JVLogWrite -LogPath $script:JVLogPath -WriteLevel $script:JVLogWriteLevel -Level Info -Message "[$($MyInvocation.MyCommand.Name)] Opening Chromium to https://javdb.com/login - please sign in to continue."
        $page.GotoAsync('https://javdb.com/login').GetAwaiter().GetResult() | Out-Null

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

            $loggedIn = $false
            if ($session -and ($rememberToken -or ($currentUrl -and $currentUrl -notmatch '/login'))) {
                if ($currentUrl -and $currentUrl -notmatch '/login') { $loggedIn = $true }
            }

            if ($loggedIn -and $session) { break }
        }

        if (-not $session) {
            throw "Timed out after ${TimeoutSeconds}s waiting for javdb login. _jdb_session was never captured."
        }

        Write-JVLog -Write:$script:JVLogWrite -LogPath $script:JVLogPath -WriteLevel $script:JVLogWriteLevel -Level Info -Message "[$($MyInvocation.MyCommand.Name)] Captured javdb session (length=$($session.Length))."

        $result = [PSCustomObject]@{
            Session       = $session
            CfClearance   = $cfClearance
            RememberToken = $rememberToken
            UserAgent     = $userAgent
            Source        = 'playwright'
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
