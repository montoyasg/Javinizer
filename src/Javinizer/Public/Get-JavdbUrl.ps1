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

        # Each Javdb search result is <a class="box" href="/v/SLUG"> ... <strong>CODE</strong> ...
        # in document order. PowerShell's basic HTML parsing on Linux/macOS pwsh
        # collapses .Links[].outerHTML to plain text and drops nested tags, so
        # we scan the raw response body directly to keep the <strong> markup.
        $pattern = '<a\s+[^>]*?\bhref="(/v/[^"]+)"[^>]*?>.*?<strong>([^<]+)</strong>'
        $searchMatches = [regex]::Matches(
            $webRequest.Content,
            $pattern,
            [System.Text.RegularExpressions.RegexOptions]::Singleline
        )

        Write-JVLog -Write:$script:JVLogWrite -LogPath $script:JVLogPath -WriteLevel $script:JVLogWriteLevel -Level Debug `
            -Message "[$Id] [$($MyInvocation.MyCommand.Name)] Search returned [$($searchMatches.Count)] candidate result(s)"

        $resultObject = foreach ($m in $searchMatches) {
            [PSCustomObject]@{
                Id  = $m.Groups[2].Value.Trim()
                Url = "https://javdb.com" + $m.Groups[1].Value
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
                    En = $entry.Url + "?locale=en"
                    Zh = $entry.Url + "?locale=zh"
                    Id = $entry.Id
                }
            }

            Write-Output $urlObject
        } else {
            Write-JVLog -Write:$script:JVLogWrite -LogPath $script:JVLogPath -WriteLevel $script:JVLogWriteLevel -Level Warning -Message "[$Id] [$($MyInvocation.MyCommand.Name)] not matched on Javdb"
            return
        }
    }
}
