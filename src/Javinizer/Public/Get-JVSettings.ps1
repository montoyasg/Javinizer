function Get-JVSettings {
    [CmdletBinding()]
    param (
        [Parameter()]
        [System.IO.FileInfo]$Path
    )

    process {
        if ($PSBoundParameters.ContainsKey('Path')) {
            $settingsPath = $Path
        } else {
            # User override (copy-on-write target from Save-JVSettings) takes
            # precedence over the module-bundled defaults.
            $userPath = Join-Path -Path $HOME -ChildPath '.jvsettings/jvSettings.json'
            if (Test-Path -LiteralPath $userPath) {
                $settingsPath = $userPath
            } else {
                $settingsPath = Join-Path -Path ((Get-Item $PSScriptRoot).Parent) -ChildPath 'jvSettings.json'
            }
        }

        try {
            $rawSettings = Get-Content -Path $settingsPath -Raw
            $settings = $rawSettings | ConvertFrom-Json -Depth 32
        } catch {
            Write-Error "Error occurred when retrieving settings: $PSItem" -ErrorAction Stop
        }

        Write-Output $settings
    }
}
