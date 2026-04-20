function Get-JavdbSession {
    [CmdletBinding()]
    param (
        [Parameter()]
        [Object]$Settings,

        [Parameter()]
        [Switch]$Force,

        [Parameter()]
        [Switch]$PassThru
    )

    $cachePath = Get-JavdbSessionCachePath

    if (-not $Force) {
        if (Test-Path -LiteralPath $cachePath) {
            try {
                $cached = Get-Content -LiteralPath $cachePath -Raw | ConvertFrom-Json
                if ($cached -is [Array]) {
                    $cached = @($cached | Where-Object { $_ -and $_.PSObject.Properties['Session'] -and $_.Session })[-1]
                }
                if (-not $cached -or -not $cached.ExpiresAt) { throw 'Cache missing ExpiresAt' }
                $expires = [DateTime]::Parse($cached.ExpiresAt).ToUniversalTime()
                if ($expires -gt (Get-Date).ToUniversalTime().AddHours(1)) {
                    if ($PassThru) { return $cached }
                    return $cached.Session
                }
            } catch {
                Write-JVLog -Write:$script:JVLogWrite -LogPath $script:JVLogPath -WriteLevel $script:JVLogWriteLevel -Level Debug -Message "[$($MyInvocation.MyCommand.Name)] Cache file unreadable: $PSItem"
            }
        }

        if ($Settings) {
            $fromSettings = $null
            try { $fromSettings = $Settings.'javdb.cookie.session' } catch {}
            if ($fromSettings) {
                if ($PassThru) {
                    return [PSCustomObject]@{
                        Session       = $fromSettings
                        CfClearance   = $null
                        RememberToken = $null
                        CapturedAt    = $null
                        ExpiresAt     = $null
                        FromSettings  = $true
                    }
                }
                return $fromSettings
            }
        }
    }

    $captured = Invoke-JavdbSessionCapture

    try {
        $dir = Split-Path -Parent $cachePath
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        $captured | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $cachePath -NoNewline
        if (-not ($IsWindows -or ($null -eq $IsWindows -and $env:OS -eq 'Windows_NT'))) {
            try { & chmod 600 $cachePath } catch {}
        }
    } catch {
        Write-JVLog -Write:$script:JVLogWrite -LogPath $script:JVLogPath -WriteLevel $script:JVLogWriteLevel -Level Warning -Message "[$($MyInvocation.MyCommand.Name)] Could not persist session cache: $PSItem"
    }

    if ($PassThru) { return $captured }
    return $captured.Session
}
