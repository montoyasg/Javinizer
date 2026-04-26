# Background job runner + state.
#
# Jobs run in PowerShell ThreadJobs (in-process, separate runspace). State
# lives on disk at ~/.javinizer/jobs/{jobId}.json so any route handler in
# any Pode runspace can read it without IPC. Cancellation is signalled by
# touching ~/.javinizer/jobs/{jobId}.cancel, which the worker checks each
# iteration.

function Get-JVJobsDir {
    $dir = Join-Path $HOME '.javinizer/jobs'
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    return $dir
}

function Get-JVJobStatePath {
    param([Parameter(Mandatory)][string]$JobId)
    Join-Path (Get-JVJobsDir) "$JobId.json"
}

function Get-JVJobCancelPath {
    param([Parameter(Mandatory)][string]$JobId)
    Join-Path (Get-JVJobsDir) "$JobId.cancel"
}

function Write-JVJobState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$StatePath,
        [Parameter(Mandatory)]$State
    )
    $tmp = "$StatePath.tmp"
    $json = $State | ConvertTo-Json -Depth 12 -Compress
    [System.IO.File]::WriteAllText($tmp, $json, [System.Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $tmp -Destination $StatePath -Force
}

function Get-JVJobState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$JobId)
    $path = Get-JVJobStatePath -JobId $JobId
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        return Get-Content -LiteralPath $path -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
    } catch {
        return $null
    }
}

function Test-JVJobCancelled {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$JobId)
    Test-Path -LiteralPath (Get-JVJobCancelPath -JobId $JobId)
}

function Request-JVJobCancel {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$JobId)
    Set-Content -LiteralPath (Get-JVJobCancelPath -JobId $JobId) -Value (Get-Date).ToString('o') -Encoding utf8
}

function Remove-JVOldJobs {
    [CmdletBinding()]
    param([int]$KeepLastHours = 24)
    # Reap stale job state files when starting a new job. Two safeguards:
    #
    # 1. Status check trumps mtime. Even if a file's LastWriteTime looks
    #    old, if its `status` is still 'running' we DO NOT delete it. A
    #    long sequential phase (e.g., Phase B at parallelism=1 against
    #    a 4000-actress library) can write ~once per second; any pause
    #    longer than the TTL would otherwise reap a live job. The bug
    #    that prompted this safeguard: user's GET /api/jobs/{id} began
    #    returning 404 on a running refresh job, and the bar disappeared.
    #
    # 2. TTL bumped from 1h to 24h. The original 1h was reasonable when
    #    jobs took seconds, but post-v1.8.x flows (Phase B + Phase C
    #    sequential walks of large libraries) routinely exceed an hour.
    $cutoff = (Get-Date).AddHours(-$KeepLastHours)
    Get-ChildItem -Path (Get-JVJobsDir) -Filter '*.json' -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $cutoff } |
        ForEach-Object {
            $base = $_.BaseName
            $isRunning = $false
            try {
                $s = Get-Content -LiteralPath $_.FullName -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
                if ($s -and "$($s.status)" -eq 'running') { $isRunning = $true }
            } catch {}
            if ($isRunning) {
                Write-PodeHost "skipping reap of $base.json — status=running" -ForegroundColor Yellow -ErrorAction SilentlyContinue
                return
            }
            Write-PodeHost "reaping stale job $base (status=$(if ($s) { $s.status } else { 'unknown' }), age $([int]((Get-Date) - $_.LastWriteTime).TotalHours)h)" -ForegroundColor DarkGray -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
            $cancelPath = Get-JVJobCancelPath -JobId $base
            if (Test-Path -LiteralPath $cancelPath) {
                Remove-Item -LiteralPath $cancelPath -Force -ErrorAction SilentlyContinue
            }
        }
}

# Job-progress helpers used by worker scriptblocks. Path-driven so workers
# can call these directly after dot-sourcing this file. The active path is
# taken from $global:JVActiveJobStatePath which the worker sets at startup.

$global:JVActiveJobStatePath = $null
$global:JVActiveJobCancelPath = $null

function Set-JVActiveJob {
    param(
        [Parameter(Mandatory)][string]$StatePath,
        [Parameter(Mandatory)][string]$CancelPath
    )
    $global:JVActiveJobStatePath = $StatePath
    $global:JVActiveJobCancelPath = $CancelPath
}

function Read-JVActiveJob {
    if (-not $global:JVActiveJobStatePath) { return $null }
    try {
        Get-Content -LiteralPath $global:JVActiveJobStatePath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
    } catch { $null }
}

function Write-JVActiveJob {
    param($State)
    if (-not $global:JVActiveJobStatePath) { return }
    $tmp = "$($global:JVActiveJobStatePath).tmp"
    $json = $State | ConvertTo-Json -Depth 12 -Compress
    [System.IO.File]::WriteAllText($tmp, $json, [System.Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $tmp -Destination $global:JVActiveJobStatePath -Force
}

function Update-JVJobProgress {
    [CmdletBinding()]
    param([int]$Current, [int]$Total, [string]$Message)
    $s = Read-JVActiveJob
    if (-not $s) { return }
    # Bump progress.updatedAt whenever ANY visible field changes — message-
    # only updates (e.g., "fetching Jellyfin person list…") are still signs
    # of life and should reset the UI's stalled timer. Previously this only
    # bumped on Current changes, which made slow sequential phases (like a
    # large Jellyfin /Persons/ fetch) falsely show "stalled Xm".
    $changed = $false
    if ($PSBoundParameters.ContainsKey('Current')) {
        if ($s.progress.current -ne $Current) { $changed = $true }
        $s.progress.current = $Current
    }
    if ($PSBoundParameters.ContainsKey('Total')) {
        if ($s.progress.total -ne $Total) { $changed = $true }
        $s.progress.total = $Total
    }
    if ($PSBoundParameters.ContainsKey('Message')) {
        if ($s.progress.message -ne $Message) { $changed = $true }
        $s.progress.message = $Message
    }
    if ($changed) {
        $s.progress.updatedAt = (Get-Date).ToUniversalTime().ToString('o')
    }
    Write-JVActiveJob $s
}

function Add-JVJobLog {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Line)
    $s = Read-JVActiveJob
    if (-not $s) { return }
    $log = @($s.log) + @("[$((Get-Date).ToString('HH:mm:ss'))] $Line")
    if ($log.Count -gt 200) { $log = $log[-200..-1] }
    $s.log = $log
    # Log lines are also signs of life — without this, a phase that emits
    # log entries but doesn't update progress.current (e.g., the merge-
    # duplicates pass in Set-JVJellyfinActresses or Phase A's Jellyfin
    # fetch on a slow server) would falsely show as stalled.
    $s.progress.updatedAt = (Get-Date).ToUniversalTime().ToString('o')
    Write-JVActiveJob $s
}

function Test-JVActiveJobCancelled {
    if (-not $global:JVActiveJobCancelPath) { return $false }
    Test-Path -LiteralPath $global:JVActiveJobCancelPath
}

function Start-JVJob {
    <#
    .SYNOPSIS
    Kick off a background ThreadJob whose progress + result are persisted
    to disk so HTTP polling can observe them.

    The worker scriptblock receives a single hashtable argument named
    $Context with fields: JobId, Arguments, StatePath, ModulePath, LibDir,
    PrivateDir, ManifestRoot. It can call Update-JVJobProgress and
    Add-JVJobLog to publish status, and Test-JVJobCancelled to check for
    cancellation.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Kind,
        [hashtable]$Arguments = @{},
        [Parameter(Mandatory)][string]$WorkerFunction,
        [Parameter(Mandatory)][string]$ModulePath,
        [Parameter(Mandatory)][string]$LibDir,
        [string]$PrivateDir
    )

    Remove-JVOldJobs -KeepLastHours 1

    $jobId = [Guid]::NewGuid().ToString('N').Substring(0, 12)
    $statePath = Get-JVJobStatePath -JobId $jobId
    $cancelPath = Get-JVJobCancelPath -JobId $jobId
    if (Test-Path -LiteralPath $cancelPath) { Remove-Item -LiteralPath $cancelPath -Force }

    $initial = [ordered]@{
        jobId      = $jobId
        kind       = $Kind
        status     = 'running'
        startedAt  = (Get-Date).ToString('o')
        finishedAt = $null
        progress   = [ordered]@{ current = 0; total = 0; message = 'starting'; updatedAt = (Get-Date).ToUniversalTime().ToString('o') }
        log        = @()
        result     = $null
        error      = $null
    }
    Write-JVJobState -StatePath $statePath -State $initial

    $manifestRoot = (Get-Item $ModulePath).Directory.FullName
    if (-not $PrivateDir) { $PrivateDir = Join-Path $manifestRoot 'Private' }

    $worker = {
        param($Context)

        Import-Module $Context.ModulePath -Force -ErrorAction Stop

        # Dot-source Lib helpers (incl. the progress helpers from this file).
        Get-ChildItem -Path $Context.LibDir -Filter '*.ps1' -ErrorAction SilentlyContinue |
            ForEach-Object { . $_.FullName }
        if ($Context.PrivateDir -and (Test-Path -LiteralPath $Context.PrivateDir)) {
            foreach ($f in @('Scraper.Xcity.ps1')) {
                $p = Join-Path $Context.PrivateDir $f
                if (Test-Path -LiteralPath $p) { . $p }
            }
        }

        Set-JVActiveJob -StatePath $Context.StatePath -CancelPath $Context.CancelPath

        try {
            # Resolve the worker function in THIS runspace (scriptblocks bind to
            # their origin session state, so we can't pass one in from outside).
            $cmd = Get-Command -Name $Context.WorkerFunction -CommandType Function -ErrorAction Stop
            $result = & $cmd $Context.Arguments
            $s = Read-JVActiveJob
            $s.status = if (Test-JVActiveJobCancelled) { 'cancelled' } else { 'done' }
            $s.finishedAt = (Get-Date).ToString('o')
            $s.result = $result
            Write-JVActiveJob $s
        } catch {
            $s = Read-JVActiveJob
            if ($s) {
                $s.status = 'error'
                $s.finishedAt = (Get-Date).ToString('o')
                $s.error = "$_"
                Write-JVActiveJob $s
            }
        }
    }

    $context = @{
        JobId          = $jobId
        Arguments      = $Arguments
        StatePath      = $statePath
        CancelPath     = $cancelPath
        ModulePath     = $ModulePath
        LibDir         = $LibDir
        PrivateDir     = $PrivateDir
        WorkerFunction = $WorkerFunction
    }

    $null = Start-ThreadJob -Name "jvjob-$jobId" -ScriptBlock $worker -ArgumentList $context

    return @{ jobId = $jobId; statePath = $statePath }
}
