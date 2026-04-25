$UserAgent = 'Javinizer (+https://github.com/javinizer/Javinizer)'

function Get-R18DevUrl {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true)]
        [String]$Id,

        [Parameter()]
        [Switch]$Strict
    )

    process {
        $searchUrl = "https://r18.dev/videos/vod/movies/detail/-/dvd_id=$Id/json"

        # If contentId is given, convert it back to standard movie ID to validate
        if (!($Strict)) {
            if ($Id -match '(?:\d{1,5})?([a-zA-Z]{1,10}|[tT]28|[rR]18)(\d{5})') {
                Write-JVLog -Write:$script:JVLogWrite -LogPath $script:JVLogPath -WriteLevel $script:JVLogWriteLevel -Level Debug -Message "[$Id] [$($MyInvocation.MyCommand.Name)] Content ID [$Id] detected"
                $splitId = $Id | Select-String -Pattern '([a-zA-Z|tT28|rR18]{1,10})(\d{1,5})'
                $studioName = $splitId.Matches.Groups[1].Value
                $rawStudioId = $splitId.Matches.Groups[2].Value
                $studioIdIndex = ($rawStudioId | Select-String -Pattern '[1-9]').Matches.Index
                $studioId = ($rawStudioId[$studioIdIndex..($rawStudioId.Length - 1)] -join '').PadLeft(3, '0')

                $Id = "$($studioName.ToUpper())-$studioId"
            }
        }

        # Convert the movie Id (ID-###) to content Id (ID00###) to match dmm naming standards
        if ($Id -match '([a-zA-Z|tT28|rR18]+-\d+z{0,1}Z{0,1}e{0,1}E{0,1})') {
            $splitId = $Id -split '-'
            $contentId = $splitId[0] + $splitId[1].PadLeft(5, '0')
        }

        # Try matching the video with Video ID
        try {
            Write-JVLog -Write:$script:JVLogWrite -LogPath $script:JVLogPath -WriteLevel $script:JVLogWriteLevel -Level Debug -Message "[$Id] [$($MyInvocation.MyCommand.Name)] Performing [GET] on URL [$searchUrl]"
            $webRequest = Invoke-WebRequest -Uri $searchUrl -UserAgent $UserAgent -Method Get -Verbose:$false | ConvertFrom-Json
        } catch {
            Write-JVLog -Write:$script:JVLogWrite -LogPath $script:JVLogPath -WriteLevel $script:JVLogWriteLevel -Level Error -Message "[$Id] [$($MyInvocation.MyCommand.Name)] Error occured on [GET] on URL [$searchUrl]: $PSItem" -Action 'Continue'
        }

        if ($webRequest.content_id) {
            $testUrl = "https://r18.dev/videos/vod/movies/detail/-/combined=$($webRequest.content_id)/json"

            try {
                Write-JVLog -Write:$script:JVLogWrite -LogPath $script:JVLogPath -WriteLevel $script:JVLogWriteLevel -Level Debug -Message "[$Id] [$($MyInvocation.MyCommand.Name)] Performing [GET] on Uri [$testUrl]"
                $webRequest = Invoke-WebRequest -Uri $testUrl -UserAgent $UserAgent -Method Get -Verbose:$false | ConvertFrom-Json
            } catch {
                $webRequest = $null
            }

            if ($null -ne $webRequest) {
                $resultId = Get-R18DevId -WebRequest $webRequest
                Write-JVLog -Write:$script:JVLogWrite -LogPath $script:JVLogPath -WriteLevel $script:JVLogWriteLevel -Level Debug -Message "[$Id] [$($MyInvocation.MyCommand.Name)] Result is [$resultId]"
                # Loose comparison: strip leading zeros from the numeric suffix and
                # uppercase. R18.dev sometimes returns dvd_id as "ABF-00343" while
                # callers pass "ABF-343" (or vice-versa); a strict -eq here was
                # silently dropping legitimate hits and forcing javdb fallback.
                $normResult = ($resultId -replace '-0*(\d)', '-$1').ToUpper().Trim()
                $normInput = ($Id -replace '-0*(\d)', '-$1').ToUpper().Trim()
                if ($normResult -eq $normInput) {
                    $resultObject = [PSCustomObject]@{
                        Id       = $resultId
                        Title    = Get-R18DevTitle -Webrequest $webRequest
                        Url      = $testUrl
                        Response = $webRequest
                    }
                } else {
                    Write-JVLog -Write:$script:JVLogWrite -LogPath $script:JVLogPath -WriteLevel $script:JVLogWriteLevel -Level Debug -Message "[$Id] [$($MyInvocation.MyCommand.Name)] R18Dev dvd_id [$resultId] (norm [$normResult]) does not match input (norm [$normInput]); falling through"
                }
            } else {
                Write-JVLog -Write:$script:JVLogWrite -LogPath $script:JVLogPath -WriteLevel $script:JVLogWriteLevel -Level Warning -Message "[$Id] [$($MyInvocation.MyCommand.Name)] not matched on R18Dev"
                return
            }

            Write-Output $resultObject
        } else {
            Write-JVLog -Write:$script:JVLogWrite -LogPath $script:JVLogPath -WriteLevel $script:JVLogWriteLevel -Level Warning -Message "[$Id] [$($MyInvocation.MyCommand.Name)] not matched on R18Dev"
            return
        }
    }
}
