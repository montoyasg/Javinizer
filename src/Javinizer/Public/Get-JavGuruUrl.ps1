function Get-JavGuruUrl {
    <#
    .SYNOPSIS
        Find the jav.guru detail page for a movie ID.
    .DESCRIPTION
        Searches jav.guru (https://jav.guru/?s=<ID>) and returns the first
        result whose slug matches the ID. jav.guru slugs lead with the lower-
        cased code (e.g. /963008/abf-343-...), so we match on that.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true)]
        [String]$Id
    )

    process {
        $searchId = $Id.Trim()
        $searchUrl = "https://jav.guru/?s=$([uri]::EscapeDataString($searchId))"

        Write-JVLog -Write:$script:JVLogWrite -LogPath $script:JVLogPath -WriteLevel $script:JVLogWriteLevel -Level Debug -Message "[$Id] [$($MyInvocation.MyCommand.Name)] Performing [GET] on URL [$searchUrl]"
        $webRequest = Invoke-JavGuruRequest -Uri $searchUrl
        if (-not $webRequest -or -not $webRequest.Content) {
            Write-JVLog -Write:$script:JVLogWrite -LogPath $script:JVLogPath -WriteLevel $script:JVLogWriteLevel -Level Warning -Message "[$Id] [$($MyInvocation.MyCommand.Name)] no search results from jav.guru"
            return
        }

        # Result links look like https://jav.guru/<postid>/<slug>/.
        $slugId = ($searchId -replace '\s+', '-').ToLower()
        $matchesFound = [regex]::Matches($webRequest.Content, '<a[^>]+href="(https://jav\.guru/\d+/([a-z0-9-]+)/)"')

        $detailUrl = $null
        foreach ($m in $matchesFound) {
            $slug = $m.Groups[2].Value
            if ($slug -like "$slugId-*" -or $slug -eq $slugId) {
                $detailUrl = $m.Groups[1].Value
                break
            }
        }

        if (-not $detailUrl) {
            Write-JVLog -Write:$script:JVLogWrite -LogPath $script:JVLogPath -WriteLevel $script:JVLogWriteLevel -Level Warning -Message "[$Id] [$($MyInvocation.MyCommand.Name)] not matched on jav.guru"
            return
        }

        Write-JVLog -Write:$script:JVLogWrite -LogPath $script:JVLogPath -WriteLevel $script:JVLogWriteLevel -Level Debug -Message "[$Id] [$($MyInvocation.MyCommand.Name)] matched [$detailUrl]"

        [PSCustomObject]@{
            Id  = $Id
            Url = $detailUrl
        }
    }
}
