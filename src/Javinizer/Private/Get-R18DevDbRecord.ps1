function Get-R18DevDbRecord {
    <#
    .SYNOPSIS
        Look a movie up in the local r18.dev SQLite cache.
    .DESCRIPTION
        r18.dev retired its public JSON detail API; the data now ships as a
        weekly CC0 PostgreSQL dump that r18dump_import.py loads into a local
        SQLite database. This wrapper shells out to r18dump_query.py, which
        reconstructs the exact JSON object shape the old r18.dev API returned,
        so the existing field extractors in Scraper.R18dev.ps1 consume it
        unchanged.

        Returns the parsed object on a hit, or $null on any miss/failure
        (db missing, python missing, id not found) so callers degrade
        gracefully exactly as they did when the live API failed.
    #>
    [CmdletBinding()]
    param (
        [Parameter(ParameterSetName = 'DvdId', Mandatory = $true)]
        [String]$DvdId,

        [Parameter(ParameterSetName = 'ContentId', Mandatory = $true)]
        [String]$ContentId,

        # Path to the SQLite cache. Defaults to the module setting
        # 'location.r18dumpdb' or ~/.javinizer/r18dev.sqlite.
        [Parameter()]
        [String]$DbPath
    )

    process {
        if (-not $DbPath) {
            $DbPath = Get-R18DevDbPath
        }
        if (-not (Test-Path -LiteralPath $DbPath)) {
            Write-JVLog -Write:$script:JVLogWrite -LogPath $script:JVLogPath -WriteLevel $script:JVLogWriteLevel -Level Debug -Message "[$($MyInvocation.MyCommand.Name)] r18.dev cache not found at [$DbPath]; skipping db lookup"
            return
        }

        $python = $env:PYTHON
        if (-not $python) {
            $cmd = Get-Command python3 -ErrorAction SilentlyContinue
            if (-not $cmd) { $cmd = Get-Command python -ErrorAction SilentlyContinue }
            if (-not $cmd) {
                Write-JVLog -Write:$script:JVLogWrite -LogPath $script:JVLogPath -WriteLevel $script:JVLogWriteLevel -Level Warning -Message "[$($MyInvocation.MyCommand.Name)] python3 not found; cannot query r18.dev cache. Set `$env:PYTHON or install python3."
                return
            }
            $python = $cmd.Source
        }

        $script = Join-Path -Path ((Get-Item $PSScriptRoot).Parent) -ChildPath 'Misc/r18dump_query.py'
        if (-not (Test-Path -LiteralPath $script)) {
            Write-JVLog -Write:$script:JVLogWrite -LogPath $script:JVLogPath -WriteLevel $script:JVLogWriteLevel -Level Error -Message "[$($MyInvocation.MyCommand.Name)] query helper not found at [$script]"
            return
        }

        if ($PSCmdlet.ParameterSetName -eq 'ContentId') {
            $idArgs = @('--content-id', $ContentId)
            $idLabel = $ContentId
        } else {
            $idArgs = @('--dvd-id', $DvdId)
            $idLabel = $DvdId
        }

        $stderrFile = [System.IO.Path]::GetTempFileName()
        try {
            $stdout = & $python $script '--db' $DbPath @idArgs 2>$stderrFile
            $exitCode = $LASTEXITCODE
        } catch {
            Write-JVLog -Write:$script:JVLogWrite -LogPath $script:JVLogPath -WriteLevel $script:JVLogWriteLevel -Level Warning -Message "[$idLabel] [$($MyInvocation.MyCommand.Name)] failed to invoke query helper: $PSItem"
            return
        } finally {
            Remove-Item -LiteralPath $stderrFile -ErrorAction SilentlyContinue
        }

        if ($exitCode -eq 3) {
            # Clean miss: id not present in this dump.
            Write-JVLog -Write:$script:JVLogWrite -LogPath $script:JVLogPath -WriteLevel $script:JVLogWriteLevel -Level Debug -Message "[$idLabel] [$($MyInvocation.MyCommand.Name)] not found in r18.dev cache"
            return
        }
        if ($exitCode -ne 0) {
            $errMsg = ''
            try { $errMsg = (Get-Content -LiteralPath $stderrFile -Raw -ErrorAction SilentlyContinue).Trim() } catch {}
            Write-JVLog -Write:$script:JVLogWrite -LogPath $script:JVLogPath -WriteLevel $script:JVLogWriteLevel -Level Warning -Message "[$idLabel] [$($MyInvocation.MyCommand.Name)] query helper exited [$exitCode]: $errMsg"
            return
        }

        if (-not $stdout) { return }
        if ($stdout -is [array]) { $stdout = $stdout -join "`n" }

        try {
            $record = $stdout | ConvertFrom-Json
        } catch {
            Write-JVLog -Write:$script:JVLogWrite -LogPath $script:JVLogPath -WriteLevel $script:JVLogWriteLevel -Level Warning -Message "[$idLabel] [$($MyInvocation.MyCommand.Name)] failed to parse r18.dev cache JSON: $PSItem"
            return
        }

        Write-Output $record
    }
}

function Get-R18DevDbPath {
    <#
    .SYNOPSIS
        Resolve the path to the local r18.dev SQLite cache.
    .DESCRIPTION
        Order of precedence: explicit setting 'location.r18dumpdb', then
        $env:JAVINIZER_R18DB, then the default ~/.javinizer/r18dev.sqlite.
    #>
    [CmdletBinding()]
    param ()

    try {
        $settings = Get-JVSettings -ErrorAction SilentlyContinue
        $configured = $settings.'location.r18dumpdb'
        if ($configured) { return $configured }
    } catch {}

    if ($env:JAVINIZER_R18DB) { return $env:JAVINIZER_R18DB }

    return (Join-Path -Path $HOME -ChildPath '.javinizer/r18dev.sqlite')
}
