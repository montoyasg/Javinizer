# Worker for the 'r18dump-refresh' background job. Auto-loaded into Pode +
# ThreadJob runspaces by the Lib glob.
#
# Downloads r18.dev's weekly CC0 PostgreSQL dump and rebuilds the local SQLite
# cache (Update-JVR18Dump). Progress lines from the Python importer are
# forwarded to the job state so the web UI can show them.

function Invoke-JVR18DumpWorker {
    param($ctx)

    Update-JVJobProgress -Message 'starting r18.dev cache rebuild...'

    $status = Update-JVR18Dump -PassThru -OnProgress {
        param($line)
        # Strip the importer's "[r18dump] " prefix for a cleaner UI message.
        $msg = $line -replace '^\[r18dump\]\s*', ''
        if ($msg) { Update-JVJobProgress -Message $msg }
    }

    Update-JVJobProgress -Message "done (dump $($status.dumpDate))"

    return @{
        dumpDate = $status.dumpDate
        ageDays  = $status.ageDays
        dbPath   = $status.dbPath
        builtAt  = $status.builtAt
    }
}
