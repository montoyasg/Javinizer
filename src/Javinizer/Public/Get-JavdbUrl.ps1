function Get-JavdbUrl {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true)]
        [String]$Id,

        [Parameter(Position = 1)]
        [String]$Session,

        [Parameter()]
        [String]$CfClearance,

        [Parameter()]
        [String]$UserAgent,

        [Parameter()]
        [Switch]$AllResults
    )

    process {
        $searchUrl = "https://javdb.com/search?q=$Id&f=all"

        $loginSession = $null
        if ($Session -or $CfClearance) {
            $loginSession = New-Object Microsoft.PowerShell.Commands.WebRequestSession
            if ($Session) {
                $cookie = New-Object System.Net.Cookie
                $cookie.Name = '_jdb_session'
                $cookie.Value = $Session
                $cookie.Domain = 'javdb.com'
                $loginSession.Cookies.Add($cookie)
            }
            if ($CfClearance) {
                $cookie = New-Object System.Net.Cookie
                $cookie.Name = 'cf_clearance'
                $cookie.Value = $CfClearance
                $cookie.Domain = 'javdb.com'
                $loginSession.Cookies.Add($cookie)
            }
        }

        $reqParams = @{ Uri = $searchUrl; WebSession = $loginSession }
        if ($UserAgent) { $reqParams['UserAgent'] = $UserAgent }

        try {
            Write-JVLog -Write:$script:JVLogWrite -LogPath $script:JVLogPath -WriteLevel $script:JVLogWriteLevel -Level Debug -Message "[$Id] [$($MyInvocation.MyCommand.Name)] Performing [GET] on URL [$searchUrl]"
            $webRequest = Invoke-JavdbRequest @reqParams
        } catch {
            Write-JVLog -Write:$script:JVLogWrite -LogPath $script:JVLogPath -WriteLevel $script:JVLogWriteLevel -Level Error -Message "[$Id] [$($MyInvocation.MyCommand.Name)] Error on [GET] [$searchUrl]: $PSItem" -Action 'Continue'
            return
        }

        # JavDB search results are <a class="box" href="/v/xxx" ...> elements wrapping
        # inner divs. Each link's outerHTML contains:
        #   <div class="video-title"><strong>SNOS-189</strong> Title text...</div>
        # The legacy <div class="uid"> selector no longer exists on the site, so we
        # extract the ID from the <strong> tag instead.
        $results = $webRequest.Links | Where-Object {
            $_.href -and $_.href -match '^/v/[^/]+$'
        }

        $resultObject = foreach ($link in $results) {
            $idMatch = [regex]::Match($link.outerHTML, '<strong>([^<]+)</strong>')
            $titleMatch = [regex]::Match(
                $link.outerHTML,
                '<div class="video-title">\s*(?:<strong>[^<]+</strong>)?\s*([^<]*)</div>'
            )

            [PSCustomObject]@{
                Id    = if ($idMatch.Success) { $idMatch.Groups[1].Value.Trim() } else { '' }
                Title = if ($titleMatch.Success) { $titleMatch.Groups[1].Value.Trim() } else { '' }
                Url   = "https://javdb.com" + $link.href
            }
        }

        try {
            $cleanId = ($Id | Select-String -Pattern '\d+(\D+-\d+)').Matches.Groups[1].Value
        } catch {
            # Do nothing
        }

        if ($Id -in $resultObject.Id -or $cleanId -in $resultObject.Id) {
            $matchedResult = $resultObject | Where-Object { $Id -eq $_.Id -or $cleanId -eq $_.Id }

            # If we have more than one exact match, select the first option
            if ($matchedResult.Count -gt 1 -and !($AllResults)) {
                $matchedResult = $matchedResult[0]
            }

            $urlObject = foreach ($entry in $matchedResult) {
                [PSCustomObject]@{
                    En    = $entry.Url + "?locale=en"
                    Zh    = $entry.Url + "?locale=zh"
                    Id    = $entry.Id
                    Title = $entry.Title
                }
            }

            Write-Output $urlObject
        } else {
            Write-JVLog -Write:$script:JVLogWrite -LogPath $script:JVLogPath -WriteLevel $script:JVLogWriteLevel -Level Warning -Message "[$Id] [$($MyInvocation.MyCommand.Name)] not matched on Javdb"
            return
        }
    }
}
