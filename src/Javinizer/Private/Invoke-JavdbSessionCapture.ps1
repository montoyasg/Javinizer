function Invoke-JavdbSessionCapture {
    [CmdletBinding()]
    param (
        [Parameter()]
        [Int]$TimeoutSeconds = 300,

        [Parameter()]
        [Switch]$Headless
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

    $playwright = $null
    $browser = $null
    $context = $null
    $page = $null
    $result = $null

    try {
        $playwright = [Microsoft.Playwright.Playwright]::CreateAsync().GetAwaiter().GetResult()
        $launchOpts = New-Object Microsoft.Playwright.BrowserTypeLaunchOptions
        $launchOpts.Headless = [bool]$Headless
        $launchOpts.Args = [string[]]@(
            '--no-sandbox',
            '--disable-dev-shm-usage',
            '--disable-gpu'
        )
        $browser = $playwright.Chromium.LaunchAsync($launchOpts).GetAwaiter().GetResult()

        $contextOpts = New-Object Microsoft.Playwright.BrowserNewContextOptions
        $contextOpts.UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
        $context = $browser.NewContextAsync($contextOpts).GetAwaiter().GetResult()
        $page = $context.NewPageAsync().GetAwaiter().GetResult()

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
            CapturedAt    = (Get-Date).ToUniversalTime().ToString('o')
            ExpiresAt     = (Get-Date).AddDays(30).ToUniversalTime().ToString('o')
        }
    } finally {
        if ($page)       { try { $page.CloseAsync().GetAwaiter().GetResult() } catch {} }
        if ($context)    { try { $context.CloseAsync().GetAwaiter().GetResult() } catch {} }
        if ($browser)    { try { $browser.CloseAsync().GetAwaiter().GetResult() } catch {} }
        if ($playwright) { try { $playwright.Dispose() } catch {} }
    }

    Write-Output $result
}
