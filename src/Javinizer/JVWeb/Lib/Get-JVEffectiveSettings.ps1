function Get-JVEffectiveSettings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [PSObject]$Base,

        [Parameter()]
        [hashtable]$Override
    )

    $clone = $Base | ConvertTo-Json -Depth 32 | ConvertFrom-Json -Depth 32

    if ($null -eq $Override) { return $clone }

    foreach ($key in $Override.Keys) {
        if ($clone.PSObject.Properties.Name -contains $key) {
            $clone.$key = $Override[$key]
        } else {
            Add-Member -InputObject $clone -NotePropertyName $key -NotePropertyValue $Override[$key] -Force
        }
    }

    $clone
}
