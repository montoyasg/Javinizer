Add-PodeRoute -Method Get -Path '/api/browse' -ScriptBlock {
    $path = $WebEvent.Query['path']
    $recurseRaw = $WebEvent.Query['recurse']
    $recurse = $recurseRaw -in @('1', 'true', 'True', 'yes', 'on')
    if ([string]::IsNullOrWhiteSpace($path)) { $path = $HOME }

    try {
        $resolved = (Resolve-Path -LiteralPath $path -ErrorAction Stop).Path
    } catch {
        Write-PodeJsonResponse -Value @{ error = "Path not found: $path" } -StatusCode 400
        return
    }

    $item = Get-Item -LiteralPath $resolved -ErrorAction SilentlyContinue
    if (-not $item -or -not $item.PSIsContainer) {
        Write-PodeJsonResponse -Value @{ error = "Not a directory: $resolved" } -StatusCode 400
        return
    }

    $parent = Split-Path -Path $resolved -Parent
    if (-not $parent) { $parent = $null }

    $settings = Get-PodeState -Name 'settings'
    $videoExt = @($settings.'match.includedfileextension')
    $minSizeMB = [int]($settings.'match.minimumfilesize')

    $entries = @()
    try {
        if ($recurse) {
            $entries = Get-ChildItem -LiteralPath $resolved -Recurse -File -Force:$false -ErrorAction SilentlyContinue |
                Where-Object {
                    $videoExt -contains $_.Extension.ToLower() -and
                    $_.Length -ge ($minSizeMB * 1MB)
                }
        } else {
            $entries = Get-ChildItem -LiteralPath $resolved -Force:$false -ErrorAction SilentlyContinue
        }
    } catch { }

    $rootLen = $resolved.Length
    $list = foreach ($e in $entries) {
        $rel = $null
        if ($recurse) {
            $full = $e.FullName
            if ($full.StartsWith($resolved)) {
                $rel = $full.Substring($rootLen).TrimStart('\', '/')
            } else {
                $rel = $e.Name
            }
        }
        [PSCustomObject]@{
            name         = $e.Name
            fullPath     = $e.FullName
            relativePath = $rel
            isDir        = if ($recurse) { $false } else { $e.PSIsContainer }
            isVideo      = if ($recurse) { $true } else { (-not $e.PSIsContainer) -and ($videoExt -contains $e.Extension.ToLower()) }
            size         = if ($e.PSIsContainer) { 0 } else { [int64]$e.Length }
            lastModified = $e.LastWriteTime.ToString('o')
            extension    = if ($e.PSIsContainer) { '' } else { $e.Extension }
        }
    }

    Write-PodeJsonResponse -Value @{
        cwd     = $resolved
        parent  = $parent
        recurse = $recurse
        entries = @($list)
    }
}

Add-PodeRoute -Method Get -Path '/api/files' -ScriptBlock {
    $path = $WebEvent.Query['path']
    $pageSize = [int]($WebEvent.Query['pageSize']); if ($pageSize -le 0) { $pageSize = 25 }
    $page = [int]($WebEvent.Query['page']); if ($page -le 0) { $page = 1 }
    $search = $WebEvent.Query['search']

    if ([string]::IsNullOrWhiteSpace($path)) { $path = $HOME }

    try {
        $resolved = (Resolve-Path -LiteralPath $path -ErrorAction Stop).Path
    } catch {
        Write-PodeJsonResponse -Value @{ error = "Path not found: $path" } -StatusCode 400
        return
    }

    $settings = Get-PodeState -Name 'settings'
    $videoExt = @($settings.'match.includedfileextension')

    $all = Get-ChildItem -LiteralPath $resolved -Force:$false -ErrorAction SilentlyContinue

    if ($search) {
        $all = $all | Where-Object { $_.Name -like "*$search*" }
    }

    $total = @($all).Count
    $start = ($page - 1) * $pageSize
    $end = [Math]::Min($start + $pageSize - 1, $total - 1)
    $slice = if ($total -gt 0 -and $start -le $end) { $all[$start..$end] } else { @() }

    $list = foreach ($e in $slice) {
        [PSCustomObject]@{
            name         = $e.Name
            fullPath     = $e.FullName
            isDir        = $e.PSIsContainer
            isVideo      = (-not $e.PSIsContainer) -and ($videoExt -contains $e.Extension.ToLower())
            size         = if ($e.PSIsContainer) { 0 } else { [int64]$e.Length }
            lastModified = $e.LastWriteTime.ToString('o')
            extension    = if ($e.PSIsContainer) { '' } else { $e.Extension }
        }
    }

    Write-PodeJsonResponse -Value @{
        cwd      = $resolved
        page     = $page
        pageSize = $pageSize
        total    = $total
        entries  = @($list)
    }
}
