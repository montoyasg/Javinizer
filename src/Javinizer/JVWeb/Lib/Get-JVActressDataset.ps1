# jvActresses.json I/O + lookup helpers.
#
# Storage layout:
#   ~/.jvsettings/jvActresses.json   ← user-writable copy (read+written here)
#   <module>/jvActresses.json        ← bundled empty seed (only read on first run)
#
# Schema: object keyed by normalized lookup string, where each value is the
# canonical entry. Multiple keys can point to the same canonical entry — a
# single name and a JapaneseName for the same actress live as two keys with
# the same payload, deduped logically by `xcityId`.

function Get-JVActressDatasetPath {
    [CmdletBinding()]
    param([switch]$BundledSeed)

    if ($BundledSeed) {
        $base = if ($env:JVWEB_LIB) {
            (Get-Item $env:JVWEB_LIB).Parent.Parent.FullName
        } elseif ($PSScriptRoot) {
            (Get-Item $PSScriptRoot).Parent.Parent.FullName
        } else {
            return $null
        }
        return Join-Path $base 'jvActresses.json'
    }

    $homeDir = if ($HOME) { $HOME } elseif ($env:HOME) { $env:HOME } elseif ($env:USERPROFILE) { $env:USERPROFILE } else { '.' }
    return Join-Path -Path $homeDir -ChildPath '.jvsettings/jvActresses.json'
}

function ConvertTo-JVActressKey {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    if (-not $Value) { return '' }
    # Lowercase, collapse whitespace, trim. Kanji / hiragana pass through unchanged.
    return ($Value.ToLowerInvariant() -replace '\s+', ' ').Trim()
}

function Get-JVActressDataset {
    [CmdletBinding()]
    param(
        [switch]$Force
    )

    if (-not $Force) {
        try {
            $cached = Get-PodeState -Name 'actressDataset' -ErrorAction SilentlyContinue
            if ($cached) { return $cached }
        } catch {
            # Not in a Pode runspace (e.g., ThreadJob worker) — fall through to disk read.
        }
    }

    $path = Get-JVActressDatasetPath
    if (-not (Test-Path -LiteralPath $path)) {
        $seed = Get-JVActressDatasetPath -BundledSeed
        if (Test-Path -LiteralPath $seed) {
            $path = $seed
        } else {
            return [ordered]@{}
        }
    }

    try {
        $raw = Get-Content -LiteralPath $path -Raw -Encoding utf8
        if (-not $raw -or -not $raw.Trim()) {
            $dataset = [ordered]@{}
        } else {
            $parsed = $raw | ConvertFrom-Json -AsHashtable
            $dataset = if ($parsed) { [ordered]@{} + $parsed } else { [ordered]@{} }
        }
    } catch {
        Write-Warning "[Actresses] failed to parse $path : $_"
        $dataset = [ordered]@{}
    }

    try { Set-PodeState -Name 'actressDataset' -Value $dataset | Out-Null } catch {}
    return $dataset
}

function Save-JVActressDataset {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Dataset
    )

    $path = Get-JVActressDatasetPath
    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    # Unique tmp filename per save (see Start-JVJob.ps1 Write-JVJobState
    # for the race-condition rationale). This site is normally serial,
    # but we use the same convention everywhere so concurrent callers
    # can't accidentally tear the file.
    $tmp = "$path.$([Guid]::NewGuid().ToString('N')).tmp"
    $json = $Dataset | ConvertTo-Json -Depth 12
    try {
        [System.IO.File]::WriteAllText($tmp, $json, [System.Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $tmp -Destination $path -Force
    } finally {
        if (Test-Path -LiteralPath $tmp) {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
    }

    try { Set-PodeState -Name 'actressDataset' -Value $Dataset | Out-Null } catch {}
    return $path
}

function Find-JVActress {
    [CmdletBinding()]
    param(
        [string]$Name,
        [string]$JapaneseName,
        [string[]]$Aliases,
        $Dataset
    )

    if (-not $Dataset) { $Dataset = Get-JVActressDataset }
    if (-not $Dataset -or $Dataset.Count -eq 0) { return $null }

    $candidates = New-Object System.Collections.Generic.List[string]
    if ($Name)         { $candidates.Add((ConvertTo-JVActressKey $Name)) | Out-Null }
    if ($JapaneseName) { $candidates.Add((ConvertTo-JVActressKey $JapaneseName)) | Out-Null }
    if ($Aliases) {
        foreach ($a in $Aliases) { if ($a) { $candidates.Add((ConvertTo-JVActressKey $a)) | Out-Null } }
    }

    # Try direct hits first.
    foreach ($k in $candidates) {
        if ($k -and $Dataset.Contains($k)) { return $Dataset[$k] }
    }

    # Reverse romaji name order — "Yuna Ogura" ↔ "Ogura Yuna".
    if ($Name) {
        $tokens = $Name -split '\s+' | Where-Object { $_ }
        if ($tokens.Count -eq 2) {
            $swapped = ConvertTo-JVActressKey "$($tokens[1]) $($tokens[0])"
            if ($Dataset.Contains($swapped)) { return $Dataset[$swapped] }
        }
    }

    return $null
}

function Merge-JVActressEntry {
    <#
    .SYNOPSIS
    Field-by-field merge: incoming wins for non-null fields, existing keeps
    null-only slots. Aliases are unioned (case-insensitive, dedup).
    #>
    [CmdletBinding()]
    param(
        $Existing,
        [Parameter(Mandatory)]$Incoming
    )

    if (-not $Existing) { return $Incoming }

    $merged = [ordered]@{}
    foreach ($k in $Existing.Keys)  { $merged[$k] = $Existing[$k] }
    foreach ($k in $Incoming.Keys) {
        $v = $Incoming[$k]
        if ($null -ne $v -and $v -ne '' -and (-not ($v -is [System.Collections.IEnumerable] -and -not ($v -is [string]) -and ($v | Measure-Object).Count -eq 0))) {
            $merged[$k] = $v
        }
    }

    # Union aliases.
    # - Trim whitespace before comparing — "Yamagishi Aika" and "Yamagishi Aika "
    #   were previously treated as distinct, accumulating after enough round-trips.
    # - Case-insensitive dedup — Sort-Object -Unique is case-sensitive by default,
    #   so "Yamagishi Aika" and "yamagishi aika" used to survive as separate
    #   entries.
    # - Drop the canonical name from the aliases list — there's no point listing
    #   the actress's own name as an alias, and historically xcity / Jellyfin
    #   feeds have included the name itself which then accumulated.
    # - Preserve insertion order (existing first, then new), so sync output is
    #   stable across runs. Sort-Object would change the order on every save.
    $existingAliases = @($Existing.aliases) | Where-Object { $_ } | ForEach-Object { "$_".Trim() } | Where-Object { $_ }
    $incomingAliases = @($Incoming.aliases) | Where-Object { $_ } | ForEach-Object { "$_".Trim() } | Where-Object { $_ }
    $canonicalName   = "$($merged.name)".Trim()
    $seen   = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    if ($canonicalName) { [void]$seen.Add($canonicalName) }
    $kept = New-Object System.Collections.Generic.List[string]
    foreach ($a in @($existingAliases + $incomingAliases)) {
        if ($seen.Add($a)) { $kept.Add($a) | Out-Null }
    }
    if ($kept.Count -gt 0) { $merged.aliases = @($kept) }
    elseif ($merged.Contains('aliases')) { $merged.aliases = @() }

    return $merged
}

function Set-JVActressEntry {
    <#
    .SYNOPSIS
    Index a canonical entry into the dataset under all its lookup keys
    (romaji name, JapaneseName, each alias). The same payload is referenced
    by each key, so updates land everywhere.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Dataset,
        [Parameter(Mandatory)]$Entry
    )

    $keys = New-Object System.Collections.Generic.List[string]
    if ($Entry.name)         { $keys.Add((ConvertTo-JVActressKey $Entry.name)) | Out-Null }
    if ($Entry.japaneseName) { $keys.Add((ConvertTo-JVActressKey $Entry.japaneseName)) | Out-Null }
    if ($Entry.aliases) {
        foreach ($a in $Entry.aliases) { if ($a) { $keys.Add((ConvertTo-JVActressKey $a)) | Out-Null } }
    }

    foreach ($k in $keys) {
        if (-not $k) { continue }
        $existing = if ($Dataset.Contains($k)) { $Dataset[$k] } else { $null }
        $Dataset[$k] = Merge-JVActressEntry -Existing $existing -Incoming $Entry
    }
}
