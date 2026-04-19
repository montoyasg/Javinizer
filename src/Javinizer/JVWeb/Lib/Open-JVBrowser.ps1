function Open-JVBrowser {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Url
    )

    try {
        if ($IsWindows -or $PSVersionTable.PSEdition -eq 'Desktop') {
            Start-Process $Url
        } elseif ($IsMacOS) {
            & open $Url
        } elseif ($IsLinux) {
            & xdg-open $Url 2>$null
        } else {
            Write-Warning "Could not detect OS to open browser. Navigate manually to $Url"
        }
    } catch {
        Write-Warning "Failed to open browser: $PSItem. Navigate manually to $Url"
    }
}
