function Convert-HTMLCharacter {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true)]
        [AllowEmptyString()]
        [String]$String
    )

    process {
        # Decode all named + numeric HTML entities in one pass (e.g. &#8211;
        # en-dash, &quot;, &amp;, &#039;). The old hand-rolled list only covered
        # a handful and let entities like &#8211; leak into folder/file names
        # (e.g. "Kasui Jun &#8211; Jun3 ...").
        $String = [System.Net.WebUtility]::HtmlDecode($String) `
            -replace '#39;s', "'" `
            -replace '※', '.*.' `
            -replace '&#39;', "'" `
            -replace '&#039', '' `
            -replace '	', '' `
            -replace '', '' # Seemingly invisible character that appears in mgstage

        $newString = $String.Trim()

        if ($newString -eq '') {
            $newString = $null
        }

        Write-Output $newString
    }
}
