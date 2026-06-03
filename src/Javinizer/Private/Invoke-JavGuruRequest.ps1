function Invoke-JavGuruRequest {
    <#
    .SYNOPSIS
        GET a jav.guru URL, falling back to Playwright on a Cloudflare block.
    .DESCRIPTION
        jav.guru sits on Cloudflare's CDN but normally serves plain HTTP 200 to
        a browser user-agent, so a direct Invoke-WebRequest works. If Cloudflare
        ever challenges (HTTP 403), we retry once through the shared Chromium
        fetch (Invoke-JavdbBrowserFetch) that JavDB uses. Returns an object with
        a .Content property holding the HTML, or $null on failure.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, Position = 0)]
        [String]$Uri,

        [Parameter()]
        [String]$UserAgent = 'Mozilla/5.0 (Windows NT 10.0; rv:128.0) Gecko/20100101 Firefox/128.0'
    )

    try {
        $resp = Invoke-WebRequest -Uri $Uri -UserAgent $UserAgent -Method Get -Verbose:$false
        return [PSCustomObject]@{ Content = $resp.Content; StatusCode = [int]$resp.StatusCode }
    } catch {
        $status = 0
        try { $status = [int]$_.Exception.Response.StatusCode } catch {}
        if ($status -ne 403) {
            Write-JVLog -Write:$script:JVLogWrite -LogPath $script:JVLogPath -WriteLevel $script:JVLogWriteLevel -Level Debug -Message "[$($MyInvocation.MyCommand.Name)] GET failed for [$Uri] (status $status): $PSItem"
            return
        }
    }

    # 403: try the browser fallback if available.
    if (Get-Command Invoke-JavdbBrowserFetch -ErrorAction SilentlyContinue) {
        try {
            Write-JVLog -Write:$script:JVLogWrite -LogPath $script:JVLogPath -WriteLevel $script:JVLogWriteLevel -Level Debug -Message "[$($MyInvocation.MyCommand.Name)] 403 on [$Uri]; retrying via Playwright"
            return Invoke-JavdbBrowserFetch -Uri $Uri -UserAgent $UserAgent
        } catch {
            Write-JVLog -Write:$script:JVLogWrite -LogPath $script:JVLogPath -WriteLevel $script:JVLogWriteLevel -Level Warning -Message "[$($MyInvocation.MyCommand.Name)] browser fallback failed for [$Uri]: $PSItem"
        }
    }

    return
}
