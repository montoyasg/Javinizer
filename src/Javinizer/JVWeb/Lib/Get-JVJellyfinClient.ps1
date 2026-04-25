# Shared Jellyfin / Emby client helpers used by both the actress-refresh
# worker (Phase B promotion) and the actress-sync function (Set-JVJellyfinActresses).
#
# Auto-loaded into every Pode runspace + ThreadJob runspace via the Lib glob.

function Resolve-JVJellyfinUserId {
    <#
    .SYNOPSIS
    Pick a usable userId for /Users/{id}/Items endpoints. Prefers the first
    administrator account; falls back to the first user. Returns $null if
    /Users is unreachable or empty.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$ApiKey
    )
    $base = $Url.TrimEnd('/')
    try {
        $users = Invoke-RestMethod -Method Get -Uri "$base/emby/Users?api_key=$ApiKey" -TimeoutSec 15 -ErrorAction Stop
        $admin = ($users | Where-Object { $_.Policy.IsAdministrator -eq $true } | Select-Object -First 1).Id
        if ($admin) { return $admin }
        if ($users.Count -gt 0) { return $users[0].Id }
        return $null
    } catch {
        return $null
    }
}

function Get-JVJellyfinPersons {
    <#
    .SYNOPSIS
    Fetch the server's person list with optional metadata fields. Tries the
    bulk Fields= path first; if Jellyfin doesn't honor it (older versions),
    the caller can do per-person GETs against /Users/{userId}/Items/{personId}
    using Get-JVJellyfinPersonFull.

    Returns the raw .Items array.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$ApiKey,

        # When set, requests Fields=Overview,PremiereDate,ProductionLocations
        # plus AlternateNames/NameAliases. Some Jellyfin versions silently
        # ignore unknown fields; callers should check for null fields and
        # fall back to per-person GETs if needed.
        [switch]$WithMetadata
    )
    $base = $Url.TrimEnd('/')
    $uri = "$base/emby/Persons/?api_key=$ApiKey"
    if ($WithMetadata) {
        $uri += "&Fields=" + [System.Web.HttpUtility]::UrlEncode('Overview,PremiereDate,ProductionLocations,People,Genres')
    }
    try {
        $resp = Invoke-RestMethod -Method Get -Uri $uri -TimeoutSec 60 -ErrorAction Stop
        return @($resp.Items)
    } catch {
        throw "[Jellyfin] failed to list persons: $_"
    }
}

function Get-JVJellyfinPersonFull {
    <#
    .SYNOPSIS
    Fetch a single person's full item payload (Overview, PremiereDate,
    AlternateNames, etc.). Returns $null on error.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$ApiKey,
        [Parameter(Mandatory)][string]$UserId,
        [Parameter(Mandatory)][string]$PersonId
    )
    $base = $Url.TrimEnd('/')
    try {
        return Invoke-RestMethod -Method Get -Uri "$base/emby/Users/$UserId/Items/$PersonId`?api_key=$ApiKey" -TimeoutSec 15 -ErrorAction Stop
    } catch {
        return $null
    }
}

function ConvertFrom-JVIsoBirthdate {
    <#
    .SYNOPSIS
    Convert a Jellyfin ISO PremiereDate ("1998-11-05T00:00:00.0000000Z" or
    similar) to xcity-style "1998 Nov 05" so the local dataset stays in one
    canonical format. Returns $null on parse failure or empty input.
    #>
    [CmdletBinding()]
    param([AllowEmptyString()][AllowNull()][string]$IsoDate)
    if (-not $IsoDate) { return $null }
    try {
        $dt = if ($IsoDate -is [DateTime]) {
            $IsoDate
        } else {
            [DateTime]::Parse([string]$IsoDate, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
        }
        return $dt.ToString('yyyy MMM dd', [System.Globalization.CultureInfo]::InvariantCulture)
    } catch {
        return $null
    }
}

function ConvertTo-JVIsoBirthdate {
    <#
    .SYNOPSIS
    Inverse of ConvertFrom-JVIsoBirthdate — converts xcity-style "1998 Nov 05"
    to a Jellyfin-compatible ISO timestamp. Equivalent to the local
    ConvertFrom-XcityBirthdate already inside Set-JVJellyfinActresses; lifted
    here so the refresh worker can use it too.
    #>
    [CmdletBinding()]
    param([string]$Value)
    if (-not $Value) { return $null }
    $months = @{
        'Jan'=1;'Feb'=2;'Mar'=3;'Apr'=4;'May'=5;'Jun'=6
        'Jul'=7;'Aug'=8;'Sep'=9;'Oct'=10;'Nov'=11;'Dec'=12
    }
    $parts = $Value.Trim() -split '\s+'
    if ($parts.Count -ne 3) { return $null }
    if (-not $months.ContainsKey($parts[1])) { return $null }
    try {
        $dt = Get-Date -Year ([int]$parts[0]) -Month $months[$parts[1]] -Day ([int]$parts[2]) -Hour 0 -Minute 0 -Second 0
        return $dt.ToString('yyyy-MM-ddTHH:mm:ss.0000000Z')
    } catch {
        return $null
    }
}

function ConvertFrom-JVJellyfinPersonItem {
    <#
    .SYNOPSIS
    Project a Jellyfin Person item into a jvActresses.json-shaped entry
    (lower-case keys to match the local schema). Reads Overview, PremiereDate,
    AlternateNames/NameAlias/Aliases, ProductionLocations, ImageTags. Does
    NOT set primaryUrl — Jellyfin's image URLs require an API key and aren't
    shareable, so the refresh path leaves it null and lets xcity supply a
    public CDN URL when available.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Person,
        [string[]]$AdditionalAliases = @()
    )

    $aliasField = $null
    foreach ($cand in @('AlternateNames', 'NameAlias', 'Aliases')) {
        try {
            if ($Person.PSObject.Properties.Name -contains $cand) { $aliasField = $cand; break }
        } catch {}
    }
    $jellyfinAliases = if ($aliasField) { @($Person.$aliasField) | Where-Object { $_ } } else { @() }
    $aliasUnion = @($jellyfinAliases) + @($AdditionalAliases) | Where-Object { $_ } | Sort-Object -Unique

    $birthCity = $null
    try {
        if ($Person.PSObject.Properties.Name -contains 'ProductionLocations' -and $Person.ProductionLocations) {
            $birthCity = @($Person.ProductionLocations) | Where-Object { $_ } | Select-Object -First 1
        }
    } catch {}

    $hasImages = $false
    try { $hasImages = ([bool]$Person.ImageTags.Primary -or [bool]$Person.ImageTags.Thumb) } catch {}

    return [ordered]@{
        name             = "$($Person.Name)"
        aliases          = @($aliasUnion)
        bio              = "$($Person.Overview)"
        birthdate        = (ConvertFrom-JVIsoBirthdate -IsoDate $Person.PremiereDate)
        birthCity        = $birthCity
        primaryUrl       = $null
        jellyfinPersonId = "$($Person.Id)"
        jellyfinHasImage = $hasImages
    }
}
