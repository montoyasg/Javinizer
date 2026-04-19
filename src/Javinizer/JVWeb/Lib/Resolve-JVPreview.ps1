function ConvertTo-JVTreeObject {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Node,
        [Parameter(Mandatory = $true)]
        [hashtable]$Counts
    )
    $Counts.folders++
    $Counts.files += $Node.files.Count
    $children = @()
    foreach ($child in $Node.children.Values) {
        $children += ConvertTo-JVTreeObject -Node $child -Counts $Counts
    }
    [PSCustomObject]@{
        name     = $Node.name
        children = $children
        files    = @($Node.files | Sort-Object)
    }
}

function Resolve-JVFileInfo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.FileInfo]$File,

        [Parameter(Mandatory = $true)]
        [PSObject]$Settings
    )

    $fileItem = Get-Item -LiteralPath $File.FullName -ErrorAction SilentlyContinue
    if (-not $fileItem) { return $null }

    $regexEnabled = [bool]$Settings.'match.regex'
    $regexString = $Settings.'match.regex.string'
    $regexIdMatch = $Settings.'match.regex.idmatch'
    $regexPtMatch = $Settings.'match.regex.ptmatch'

    $converted = Convert-JVTitle -Files $fileItem `
        -RegexEnabled $regexEnabled `
        -RegexString $regexString `
        -RegexIdMatch $regexIdMatch `
        -RegexPtMatch $regexPtMatch `
        -ErrorAction SilentlyContinue

    if (-not ($converted -and $converted.Id)) { return $null }

    $pn = 0
    if ($converted.PSObject.Properties.Name -contains 'PartNumber' -and $converted.PartNumber) {
        $pn = [int]$converted.PartNumber
    }

    [PSCustomObject]@{
        Id         = $converted.Id
        PartNumber = $pn
    }
}

function Resolve-JVContentId {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.FileInfo]$File,

        [Parameter(Mandatory = $true)]
        [PSObject]$Settings
    )

    $info = Resolve-JVFileInfo -File $File -Settings $Settings
    if ($info) { return $info.Id }
    $null
}

function Resolve-JVPreviewOne {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$DestinationPath,

        [Parameter(Mandatory = $true)]
        [PSObject]$Settings,

        [Parameter()]
        [hashtable]$Cache,

        [Parameter()]
        [PSObject]$DataOverride
    )

    $file = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    if (-not $file) {
        return [PSCustomObject]@{ ok = $false; reason = "File not found: $Path" }
    }

    $info = Resolve-JVFileInfo -File $file -Settings $Settings
    $partNumber = if ($info) { [int]$info.PartNumber } else { 0 }

    $data = $DataOverride
    if (-not $data) {
        if (-not $info) {
            return [PSCustomObject]@{ ok = $false; reason = "Could not extract content ID from filename" }
        }
        $data = Invoke-JVScrapeCached -Id $info.Id -Cache $Cache
        if (-not $data) {
            return [PSCustomObject]@{ ok = $false; reason = "No R18.dev match for ID" }
        }
    }

    try {
        $sortResult = Get-JVSortData -Path $file.FullName -DestinationPath $DestinationPath -Data $data -Settings $Settings -PartNumber $partNumber -ErrorAction Stop
    } catch {
        return [PSCustomObject]@{ ok = $false; reason = "Get-JVSortData failed: $PSItem" }
    }

    $sd = $sortResult.SortData
    $leaves = @("$($sd.FileName)$($file.Extension)")
    # NFO is written per file (sort.create.nfoperfile=true by default) — one per part.
    if ($Settings.'sort.create.nfo' -and $sd.NfoPath) { $leaves += "$($sd.FileName).nfo" }
    # Images are deduped to part 0/1 by Set-JVMovie.
    if ($partNumber -le 1) {
        if ($Settings.'sort.download.posterimg' -and $sd.PosterName) {
            foreach ($n in $sd.PosterName) { $leaves += "$n.jpg" }
        }
        if ($Settings.'sort.download.thumbimg' -and $sd.ThumbName) { $leaves += "$($sd.ThumbName).jpg" }
    }

    [PSCustomObject]@{
        ok          = $true
        source      = $file.FullName
        id          = $data.Id
        partNumber  = $partNumber
        folderPath  = $sd.FolderPath
        filePath    = $sd.FilePath
        leaves      = $leaves
        data        = $data
    }
}

function Resolve-JVPreviewTree {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Paths,

        [Parameter(Mandatory = $true)]
        [string]$DestinationPath,

        [Parameter(Mandatory = $true)]
        [PSObject]$Settings,

        [Parameter()]
        [hashtable]$Cache
    )

    $resolved = @()
    $unresolved = @()

    foreach ($p in $Paths) {
        $r = Resolve-JVPreviewOne -Path $p -DestinationPath $DestinationPath -Settings $Settings -Cache $Cache
        if ($r.ok) { $resolved += $r }
        else { $unresolved += [PSCustomObject]@{ source = $p; reason = $r.reason } }
    }

    $root = @{ name = $DestinationPath; children = [ordered]@{}; files = @() }

    foreach ($r in $resolved) {
        $rel = $r.folderPath
        if ($rel.StartsWith($DestinationPath)) {
            $rel = $rel.Substring($DestinationPath.Length).TrimStart('\', '/')
        }
        $segments = $rel -split '[\\/]' | Where-Object { $_ -ne '' }
        $node = $root
        foreach ($seg in $segments) {
            if (-not $node.children.Contains($seg)) {
                $node.children[$seg] = @{ name = $seg; children = [ordered]@{}; files = @() }
            }
            $node = $node.children[$seg]
        }
        foreach ($leaf in $r.leaves) {
            if ($node.files -notcontains $leaf) { $node.files += $leaf }
        }
    }

    $counts = @{ folders = 0; files = 0 }
    $tree = ConvertTo-JVTreeObject -Node $root -Counts $counts

    [PSCustomObject]@{
        tree          = $tree
        unresolved    = $unresolved
        totalFolders  = $counts.folders
        totalFiles    = $counts.files
        resolvedCount = $resolved.Count
    }
}
