function Update-JVR18Dump {
    <#
    .SYNOPSIS
        Rebuild the local r18.dev SQLite cache from the weekly dump.
    .DESCRIPTION
        Downloads r18.dev's weekly CC0 PostgreSQL dump (https://r18.dev/dumps)
        and imports it into a local SQLite database that Get-R18DevDbRecord
        queries. The import is atomic (temp file -> rename) and writes a
        sidecar <db>.meta.json marker recording the dump date and build time,
        which Get-R18DevDumpStatus reports and the startup auto-refresh checks.

        Requires python3 (stdlib only). Throws on failure so callers/jobs can
        surface the error.
    .EXAMPLE
        Update-JVR18Dump
    .EXAMPLE
        Update-JVR18Dump -Source /path/to/dump.sql.gz -PassThru
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param (
        # Target SQLite path. Defaults to the 'location.r18dumpdb' setting or
        # ~/.javinizer/r18dev.sqlite.
        [Parameter()]
        [String]$DbPath,

        # Override the dump source (URL or local .sql.gz). Defaults to the
        # importer's built-in https://r18.dev/dumps/latest.
        [Parameter()]
        [String]$Source,

        # Optional callback invoked with each progress line from the importer.
        [Parameter()]
        [ScriptBlock]$OnProgress,

        [Parameter()]
        [Switch]$PassThru
    )

    if (-not $DbPath) {
        $DbPath = Get-R18DevDbPath
    }

    $python = $env:PYTHON
    if (-not $python) {
        $cmd = Get-Command python3 -ErrorAction SilentlyContinue
        if (-not $cmd) { $cmd = Get-Command python -ErrorAction SilentlyContinue }
        if (-not $cmd) {
            throw "python3 is required to build the r18.dev cache. Install python3 or set `$env:PYTHON."
        }
        $python = $cmd.Source
    }

    $importScript = Join-Path -Path ((Get-Item $PSScriptRoot).Parent) -ChildPath 'Misc/r18dump_import.py'
    if (-not (Test-Path -LiteralPath $importScript)) {
        throw "r18.dev importer not found at [$importScript]."
    }

    $argList = @($importScript, '--out', $DbPath)
    if ($Source) { $argList += @('--source', $Source) }

    if (-not $PSCmdlet.ShouldProcess($DbPath, 'Rebuild r18.dev cache')) {
        return
    }

    Write-JVLog -Write:$script:JVLogWrite -LogPath $script:JVLogPath -WriteLevel $script:JVLogWriteLevel -Level Info -Message "[Update-JVR18Dump] building r18.dev cache at [$DbPath]"

    # The importer logs phase progress to stderr; merge and forward each line.
    & $python @argList 2>&1 | ForEach-Object {
        $line = "$_"
        if ($line) {
            Write-JVLog -Write:$script:JVLogWrite -LogPath $script:JVLogPath -WriteLevel $script:JVLogWriteLevel -Level Debug -Message "[Update-JVR18Dump] $line"
            if ($OnProgress) { & $OnProgress $line }
        }
    }
    $exit = $LASTEXITCODE

    if ($exit -ne 0) {
        throw "r18.dev importer exited with code $exit."
    }

    $status = Get-R18DevDumpStatus -DbPath $DbPath
    Write-JVLog -Write:$script:JVLogWrite -LogPath $script:JVLogPath -WriteLevel $script:JVLogWriteLevel -Level Info -Message "[Update-JVR18Dump] done; dump [$($status.dumpDate)]"

    if ($PassThru) { Write-Output $status }
}
