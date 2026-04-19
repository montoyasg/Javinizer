function Invoke-JVSortOne {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$DestinationPath,

        [Parameter(Mandatory = $true)]
        [PSObject]$Settings,

        [Parameter()]
        [PSObject]$Data,

        [Parameter()]
        [hashtable]$Cache,

        [Parameter()]
        [switch]$Force,

        [Parameter()]
        [switch]$Update
    )

    $file = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    if (-not $file) {
        return [PSCustomObject]@{ ok = $false; error = "File not found: $Path" }
    }

    $effectiveData = $Data
    if (-not $effectiveData) {
        $id = Resolve-JVContentId -File $file -Settings $Settings
        if (-not $id) {
            return [PSCustomObject]@{ ok = $false; error = "Could not extract content ID from filename" }
        }
        $effectiveData = Invoke-JVScrapeCached -Id $id -Cache $Cache
        if (-not $effectiveData) {
            return [PSCustomObject]@{ ok = $false; error = "No R18.dev match for ID [$id]" }
        }
    }

    try {
        $sortResult = Get-JVSortData -Path $file.FullName -DestinationPath $DestinationPath -Data $effectiveData -Settings $Settings -Update:$Update -Force:$Force -ErrorAction Stop
    } catch {
        return [PSCustomObject]@{ ok = $false; error = "Get-JVSortData failed: $PSItem" }
    }

    try {
        Set-JVMovie -Path $file.FullName `
            -DestinationPath $DestinationPath `
            -Settings $Settings `
            -Data $sortResult.Data `
            -SortData $sortResult.SortData `
            -Update:$Update `
            -Force:$Force `
            -ErrorAction Stop | Out-Null
    } catch {
        return [PSCustomObject]@{ ok = $false; error = "Set-JVMovie failed: $PSItem"; folderPath = $sortResult.SortData.FolderPath; filePath = $sortResult.SortData.FilePath }
    }

    # Poster-crop fallback: if posterimg is enabled but folder.jpg wasn't produced
    # (e.g. crop.py silently failed due to missing Pillow, or Python isn't installed),
    # crop it ourselves with SixLabors.ImageSharp. Copy-fanart is the last resort
    # for offline first-runs.
    $warnings = @()
    if ($Settings.'sort.download.posterimg' -and $sortResult.SortData.PosterPath) {
        $thumb = $sortResult.SortData.ThumbPath
        foreach ($poster in @($sortResult.SortData.PosterPath)) {
            if (Test-Path -LiteralPath $poster) { continue }
            if (-not ($thumb -and (Test-Path -LiteralPath $thumb))) {
                $warnings += "Poster [$(Split-Path -Leaf $poster)] missing and fanart.jpg not available."
                continue
            }
            $cropped = $false
            try { $cropped = Invoke-JVCrop -Source $thumb -Destination $poster } catch { $cropped = $false }
            if ($cropped) { continue }
            try {
                Copy-Item -LiteralPath $thumb -Destination $poster -Force
                $warnings += "ImageSharp crop unavailable; wrote uncropped fanart.jpg as [$(Split-Path -Leaf $poster)]."
            } catch {
                $warnings += "Poster [$(Split-Path -Leaf $poster)] missing and fallback copy failed: $PSItem"
            }
        }
    }

    [PSCustomObject]@{
        ok         = $true
        folderPath = $sortResult.SortData.FolderPath
        filePath   = $sortResult.SortData.FilePath
        id         = $effectiveData.Id
        warnings   = $warnings
    }
}
