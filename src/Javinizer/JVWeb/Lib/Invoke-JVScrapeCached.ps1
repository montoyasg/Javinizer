function Invoke-JVScrapeCached {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Id,

        [Parameter()]
        [string]$Url,

        [Parameter()]
        [hashtable]$Cache
    )

    $key = if ($Url) { "url:$Url" } else { "id:$($Id.ToUpper())" }

    if ($Cache -and $Cache.ContainsKey($key)) {
        return $Cache[$key]
    }

    $resolvedUrl = $Url
    if (-not $resolvedUrl) {
        $urlObj = Get-R18DevUrl -Id $Id -ErrorAction SilentlyContinue
        if (-not $urlObj) { return $null }
        $resolvedUrl = $urlObj.Url
    }

    $data = Get-R18DevData -Url $resolvedUrl -ErrorAction SilentlyContinue
    if (-not $data) { return $null }

    if ($Cache) {
        $Cache[$key] = $data
        if ($data.Id) { $Cache["id:$($data.Id.ToUpper())"] = $data }
    }

    $data
}
