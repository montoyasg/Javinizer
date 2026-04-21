function Get-JavdbSession {
    [CmdletBinding()]
    param (
        [Parameter()]
        [Object]$Settings,

        [Parameter()]
        [Switch]$Force,

        [Parameter()]
        [Switch]$PassThru,

        [Parameter()]
        [ValidateSet('Anonymous', 'Login')]
        [string]$Mode = 'Anonymous'
    )

    $cachePath = Get-JavdbSessionCachePath

    if (-not $Force) {
        $cached = Read-JavdbSessionCache -Path $cachePath
        if ($cached) {
            if ($PassThru) { return $cached }
            return $cached.Session
        }
    }

    # Strategy 1: cookies pasted into settings (javdb.cookie.session + javdb.cookie.cf_clearance)
    $fromSettings = Resolve-JavdbSessionFromSettings -Settings $Settings
    if ($fromSettings) {
        Save-JavdbSessionCache -Path $cachePath -Session $fromSettings
        if ($PassThru) { return $fromSettings }
        return $fromSettings.Session
    }

    # Strategy 2: extract from a real browser profile via browser_cookie3
    $browserChoice = $null
    if ($Settings) {
        try { $browserChoice = $Settings.'javdb.cookie.browser' } catch {}
    }
    if ($browserChoice -and $browserChoice -ne 'none' -and $browserChoice -ne 'playwright' -and $browserChoice -ne 'paste') {
        try {
            $captured = Import-JavdbCookiesFromBrowser -Browser $browserChoice
            if ($captured -and $captured.Session) {
                Save-JavdbSessionCache -Path $cachePath -Session $captured
                if ($PassThru) { return $captured }
                return $captured.Session
            }
        } catch {
            Write-JVLog -Write:$script:JVLogWrite -LogPath $script:JVLogPath -WriteLevel $script:JVLogWriteLevel -Level Warning -Message "[$($MyInvocation.MyCommand.Name)] Browser cookie import failed: $PSItem"
        }
    }

    # Strategy 3: Playwright capture. Anonymous by default (headless, zero interaction,
    # just grabs cf_clearance for Cloudflare). Login mode is opt-in for login-gated data.
    $captured = Invoke-JavdbSessionCapture -Mode $Mode
    Save-JavdbSessionCache -Path $cachePath -Session $captured

    if ($PassThru) { return $captured }
    return $captured.Session
}

function Read-JavdbSessionCache {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) { return $null }

    try {
        $cached = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        if ($cached -is [Array]) {
            $cached = @($cached | Where-Object { $_ -and $_.PSObject.Properties['Session'] -and $_.Session })[-1]
        }
        if (-not $cached -or -not $cached.ExpiresAt) { return $null }
        $expires = [DateTime]::Parse($cached.ExpiresAt).ToUniversalTime()
        if ($expires -gt (Get-Date).ToUniversalTime().AddHours(1)) {
            return $cached
        }
    } catch {
        Write-JVLog -Write:$script:JVLogWrite -LogPath $script:JVLogPath -WriteLevel $script:JVLogWriteLevel -Level Debug -Message "[Get-JavdbSession] Cache file unreadable: $PSItem"
    }
    return $null
}

function Resolve-JavdbSessionFromSettings {
    [CmdletBinding()]
    param (
        [Parameter()]
        [Object]$Settings
    )

    if (-not $Settings) { return $null }

    $session = $null
    $cf      = $null
    $ua      = $null
    try { $session = $Settings.'javdb.cookie.session' } catch {}
    try { $cf      = $Settings.'javdb.cookie.cf_clearance' } catch {}
    try { $ua      = $Settings.'javdb.cookie.user_agent' } catch {}

    if (-not $session) { return $null }

    # cf_clearance isn't strictly required for every javdb request, but if the user only
    # pasted _jdb_session we still treat that as an explicit override worth honouring.
    [PSCustomObject]@{
        Session       = $session
        CfClearance   = $cf
        RememberToken = $null
        UserAgent     = $ua
        Source        = 'settings'
        CapturedAt    = (Get-Date).ToUniversalTime().ToString('o')
        ExpiresAt     = (Get-Date).AddDays(30).ToUniversalTime().ToString('o')
    }
}

function Save-JavdbSessionCache {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [Object]$Session
    )

    try {
        $dir = Split-Path -Parent $Path
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        $Session | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Path -NoNewline
        if (-not ($IsWindows -or ($null -eq $IsWindows -and $env:OS -eq 'Windows_NT'))) {
            try { & chmod 600 $Path } catch {}
        }
    } catch {
        Write-JVLog -Write:$script:JVLogWrite -LogPath $script:JVLogPath -WriteLevel $script:JVLogWriteLevel -Level Warning -Message "[Get-JavdbSession] Could not persist session cache: $PSItem"
    }
}
