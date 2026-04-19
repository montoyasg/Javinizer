function Get-JavdbSessionCachePath {
    [CmdletBinding()]
    param ()

    if ($IsWindows -or ($null -eq $IsWindows -and $env:OS -eq 'Windows_NT')) {
        $base = $env:LOCALAPPDATA
        if (-not $base) { $base = Join-Path $env:USERPROFILE 'AppData\Local' }
        return Join-Path $base 'Javinizer\javdb-session.json'
    }

    $base = $env:XDG_CONFIG_HOME
    if (-not $base) { $base = Join-Path $env:HOME '.config' }
    return Join-Path $base 'Javinizer/javdb-session.json'
}
