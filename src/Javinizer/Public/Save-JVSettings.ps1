function Save-JVSettings {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [hashtable]$Update,

        [Parameter()]
        [string]$Path
    )

    process {
        if (-not $PSBoundParameters.ContainsKey('Path') -or [string]::IsNullOrWhiteSpace($Path)) {
            $Path = Join-Path -Path $HOME -ChildPath '.jvsettings/jvSettings.json'
        }

        $parent = Split-Path -Parent $Path
        if ($parent -and -not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }

        $current = Get-JVSettings

        foreach ($key in $Update.Keys) {
            if ($current.PSObject.Properties.Name -contains $key) {
                $current.$key = $Update[$key]
            } else {
                Add-Member -InputObject $current -NotePropertyName $key -NotePropertyValue $Update[$key] -Force
            }
        }

        $current | ConvertTo-Json -Depth 32 | Out-File -LiteralPath $Path -Encoding utf8 -Force

        Write-Output $current
    }
}
