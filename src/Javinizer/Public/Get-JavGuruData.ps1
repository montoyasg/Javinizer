function Get-JavGuruData {
    <#
    .SYNOPSIS
        Scrape a jav.guru detail page into a Javinizer metadata object.
    .DESCRIPTION
        Fetches the detail page (HTTP, with a Playwright fallback for
        Cloudflare) and extracts the fields jav.guru exposes: id, English
        title, release date, director, maker, label, genres, actress and the
        re-hosted DMM cover. jav.guru does not reliably expose a screenshot
        gallery, series, runtime or a static trailer, so those are left null.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [String]$Url
    )

    process {
        Write-JVLog -Write:$script:JVLogWrite -LogPath $script:JVLogPath -WriteLevel $script:JVLogWriteLevel -Level Debug -Message "[$($MyInvocation.MyCommand.Name)] Performing [GET] on URL [$Url]"
        $webRequest = Invoke-JavGuruRequest -Uri $Url
        if (-not $webRequest -or -not $webRequest.Content) {
            Write-JVLog -Write:$script:JVLogWrite -LogPath $script:JVLogPath -WriteLevel $script:JVLogWriteLevel -Level Warning -Message "[$($MyInvocation.MyCommand.Name)] no content for [$Url]; returning null"
            return
        }

        $movieDataObject = [PSCustomObject]@{
            Source        = 'javguru'
            Url           = $Url
            Id            = Get-JavGuruId -Webrequest $webRequest
            Title         = Get-JavGuruTitle -Webrequest $webRequest
            Description   = $null
            ReleaseDate   = Get-JavGuruReleaseDate -Webrequest $webRequest
            ReleaseYear   = Get-JavGuruReleaseYear -Webrequest $webRequest
            Runtime       = $null
            Director      = Get-JavGuruDirector -Webrequest $webRequest
            Maker         = Get-JavGuruMaker -Webrequest $webRequest
            Label         = Get-JavGuruLabel -Webrequest $webRequest
            Series        = $null
            Actress       = Get-JavGuruActress -Webrequest $webRequest
            Genre         = Get-JavGuruGenre -Webrequest $webRequest
            CoverUrl      = Get-JavGuruCoverUrl -Webrequest $webRequest
            ScreenshotUrl = $null
            TrailerUrl    = $null
        }

        Write-JVLog -Write:$script:JVLogWrite -LogPath $script:JVLogPath -WriteLevel $script:JVLogWriteLevel -Level Debug -Message "[$($MyInvocation.MyCommand.Name)] JavGuru data object: $($movieDataObject | ConvertTo-Json -Depth 32 -Compress)"
        Write-Output $movieDataObject
    }
}
