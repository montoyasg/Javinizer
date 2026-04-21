function Get-JavdbData {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [String]$Url,

        [Parameter(Position = 1)]
        [String]$Session,

        [Parameter()]
        [String]$CfClearance,

        [Parameter()]
        [String]$UserAgent
    )

    process {
        $movieDataObject = @()

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

        $reqParams = @{ Uri = $Url; WebSession = $loginSession }
        if ($UserAgent) { $reqParams['UserAgent'] = $UserAgent }

        try {
            Write-JVLog -Write:$script:JVLogWrite -LogPath $script:JVLogPath -WriteLevel $script:JVLogWriteLevel -Level Debug -Message "[$($MyInvocation.MyCommand.Name)] Performing [GET] on URL [$Url]"
            $webRequest = Invoke-JavdbRequest @reqParams
        } catch {
            Write-JVLog -Write:$script:JVLogWrite -LogPath $script:JVLogPath -WriteLevel $script:JVLogWriteLevel -Level Error -Message "[$($MyInvocation.MyCommand.Name)] Error [GET] on URL [$Url]: $PSItem" -Action 'Continue'
            throw
        }

        $movieDataObject = [PSCustomObject]@{
            Source        = if ($Url -match 'locale=zh') { 'Javdbzh' } else { 'Javdb' }
            Url           = $Url
            Id            = Get-JavdbId -WebRequest $webRequest
            Title         = Get-JavdbTitle -WebRequest $webRequest
            ReleaseDate   = Get-JavdbReleaseDate -WebRequest $webRequest
            ReleaseYear   = Get-JavdbReleaseYear -WebRequest $webRequest
            Runtime       = Get-JavdbRuntime -WebRequest $webRequest
            Director      = Get-JavdbDirector -WebRequest $webRequest
            Maker         = Get-JavdbMaker -WebRequest $webRequest
            Series        = Get-JavdbSeries -WebRequest $webRequest
            Actress       = Get-JavdbActress -WebRequest $webRequest -WebSession $loginSession -UserAgent $UserAgent
            Genre         = Get-JavdbGenre -WebRequest $webRequest
            CoverUrl      = Get-JavdbCoverUrl -WebRequest $webRequest
            ScreenshotUrl = Get-JavdbScreenshotUrl -WebRequest $webRequest
            TrailerUrl    = Get-JavdbTrailerUrl -WebRequest $webRequest
        }

        Write-JVLog -Write:$script:JVLogWrite -LogPath $script:JVLogPath -WriteLevel $script:JVLogWriteLevel -Level Debug -Message "[$($MyInvocation.MyCommand.Name)] Javdb data object: $($movieDataObject | ConvertTo-Json -Depth 32 -Compress)"
        Write-Output $movieDataObject
    }
}
