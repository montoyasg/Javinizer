# Worker for the jellyfin-sync background job. Auto-loaded into Pode + ThreadJob
# runspaces by Use-PodeScript. Calls Set-JVJellyfinActresses (Public) and threads
# progress + log updates back through the Start-JVJob helpers.

function Invoke-JVJellyfinSyncWorker {
    param($ctx)

    $progressCb = { param($cur, $tot, $msg) Update-JVJobProgress -Current $cur -Total $tot -Message $msg }
    $logCb      = { param($line) Add-JVJobLog $line }

    $params = @{
        Url               = $ctx.embyUrl
        ApiKey            = $ctx.embyApiKey
        ProgressCallback  = $progressCb
        LogCallback       = $logCb
    }
    if ($ctx.fields)          { $params['Fields']          = @($ctx.fields) }
    if ($ctx.replaceExisting) { $params['ReplaceExisting'] = $true }
    if ($ctx.mergeDuplicates) { $params['MergeDuplicates'] = $true }
    if ($ctx.dryRun)          { $params['DryRun']          = $true }
    if ($ctx.parallelism)     { $params['Parallelism']     = [int]$ctx.parallelism }

    return (Set-JVJellyfinActresses @params)
}
