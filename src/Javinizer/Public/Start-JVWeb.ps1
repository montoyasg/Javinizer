function Start-JVWeb {
    [CmdletBinding()]
    param(
        [ValidateRange(1, 65535)]
        [int]$Port = 8600,

        [string]$Bind = '127.0.0.1',

        [switch]$NoBrowser,

        [switch]$Next
    )

    $jvWebScript = Join-Path -Path ((Get-Item $PSScriptRoot).Parent.FullName) -ChildPath 'JVWeb' -AdditionalChildPath 'JVWeb.ps1'
    if (-not (Test-Path -LiteralPath $jvWebScript)) {
        Write-Error "JVWeb.ps1 not found at $jvWebScript"
        return
    }

    & $jvWebScript -Port $Port -Bind $Bind -NoBrowser:$NoBrowser -Next:$Next
}
