function Clear-JavdbSession {
    [CmdletBinding()]
    param ()

    $cachePath = Get-JavdbSessionCachePath
    if (Test-Path -LiteralPath $cachePath) {
        Remove-Item -LiteralPath $cachePath -Force
        Write-JVLog -Write:$script:JVLogWrite -LogPath $script:JVLogPath -WriteLevel $script:JVLogWriteLevel -Level Info -Message "[$($MyInvocation.MyCommand.Name)] Removed cached javdb session."
    }
}
