function ConvertTo-JVOverrideHash {
    [CmdletBinding()]
    param($Overrides)

    $hash = @{}
    if ($null -eq $Overrides) { return $hash }

    if ($Overrides -is [hashtable] -or $Overrides -is [System.Collections.IDictionary]) {
        foreach ($k in $Overrides.Keys) { $hash[$k] = $Overrides[$k] }
    } else {
        foreach ($prop in $Overrides.PSObject.Properties) {
            $hash[$prop.Name] = $prop.Value
        }
    }
    $hash
}
