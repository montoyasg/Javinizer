function Get-R18DevData {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [String]$Url,

        [Parameter()]
        [Switch]$Ja,

        [Parameter()]
        [System.IO.FileInfo]$UncensorCsvPath = (Join-Path -Path ((Get-Item $PSScriptRoot).Parent) -ChildPath 'jvUncensor.csv'),

        # Pre-fetched API-shaped body. Get-R18DevUrl already resolved the
        # record from the local r18.dev cache (or the live page) and passes it
        # through as the pipeline object's 'Response' property, so we reuse it
        # instead of querying the cache a second time.
        [Parameter(ValueFromPipelineByPropertyName = $true)]
        [Alias('Response')]
        [PSObject]$PreFetched
    )

    process {
        $movieDataObject = @()

        try {
            $replaceHashtable = Import-Csv -LiteralPath $UncensorCsvPath
        } catch {
            Write-JVLog -Write:$script:JVLogWrite -LogPath $script:JVLogPath -WriteLevel $script:JVLogWriteLevel -Level Error -Message "[$($MyInvocation.MyCommand.Name)] Error occurred when import uncensor csv at path [$UncensorCsvPath]: $PSItem"
        }

        if ($PreFetched) {
            $webRequest = $PreFetched
        } else {
            # No pre-fetched body: resolve from the local r18.dev cache by the
            # content_id embedded in the Url.
            if ($Url -like '*combined=*') {
                $contentId = (($Url -split 'combined=')[1] -split '\/')[0]
            } elseif ($Url -like '*id=*') {
                $contentId = (($Url -split 'id=')[1] -split '\/')[0]
            } else {
                Write-JVLog -Write:$script:JVLogWrite -LogPath $script:JVLogPath -WriteLevel $script:JVLogWriteLevel -Level Error -Message "[$($MyInvocation.MyCommand.Name)] Invalid URL provided [$Url]"
            }

            if ($contentId) {
                $webRequest = Get-R18DevDbRecord -ContentId $contentId
            }
        }

        # Field extractors below all declare $Webrequest as Mandatory, so a null
        # response would surface as a terminating parameter-binding error that
        # bubbles past callers' SilentlyContinue. Bail out cleanly so the
        # caller can fall back to javdb.
        if (-not $webRequest) {
            Write-JVLog -Write:$script:JVLogWrite -LogPath $script:JVLogPath -WriteLevel $script:JVLogWriteLevel -Level Warning -Message "[$($MyInvocation.MyCommand.Name)] R18Dev returned no body for [$Url]; returning null"
            return
        }

        $movieDataObject = [PSCustomObject]@{
            Source        = if ($Ja) { 'r18dev-ja' } else { 'r18dev' }
            Url           = $Url
            ContentId     = Get-R18DevContentId -WebRequest $webRequest
            Id            = Get-R18DevId -WebRequest $webRequest
            Title         = Get-R18DevTitle -WebRequest $webRequest -Replace $replaceHashTable -Ja:$Ja
            Description   = Get-R18DevDescription -WebRequest $webRequest -Ja:$Ja
            ReleaseDate   = Get-R18DevReleaseDate -WebRequest $webRequest
            ReleaseYear   = Get-R18DevReleaseYear -WebRequest $webRequest
            Runtime       = Get-R18DevRuntime -WebRequest $webRequest
            Director      = Get-R18DevDirector -WebRequest $webRequest -Ja:$Ja
            Maker         = Get-R18DevMaker -WebRequest $webRequest -Ja:$Ja
            Label         = Get-R18DevLabel -WebRequest $webRequest -Replace $replaceHashTable -Ja:$Ja
            Series        = Get-R18DevSeries -WebRequest $webRequest -Replace $replaceHashTable -Ja:$Ja
            Actress       = Get-R18DevActress -WebRequest $webRequest -Url $Url
            Genre         = Get-R18DevGenre -WebRequest $webRequest -Replace $replaceHashTable -Ja:$Ja
            CoverUrl      = Get-R18DevCoverUrl -WebRequest $webRequest
            ScreenshotUrl = Get-R18DevScreenshotUrl -WebRequest $webRequest
            TrailerUrl    = Get-R18DevTrailerUrl -WebRequest $webRequest
        }

        Write-JVLog -Write:$script:JVLogWrite -LogPath $script:JVLogPath -WriteLevel $script:JVLogWriteLevel -Level Debug -Message "[$($MyInvocation.MyCommand.Name)] R18 data object: $($movieDataObject | ConvertTo-Json -Depth 32 -Compress)"
        Write-Output $movieDataObject
    }
}
