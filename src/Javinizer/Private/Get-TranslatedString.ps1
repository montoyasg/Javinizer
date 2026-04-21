function Get-TranslatedString {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyString()]
        [String]$String,

        [String]$Language = 'en',

        [String]$TranslateDeeplApiKey,

        [ValidateSet('googletrans', 'google_trans_new', 'deepl', 'google_web')]
        [String]$Module
    )

    process {
        if ($null -eq $String -or $String -eq '') {
            Write-Output $String
            return
        }

        if ($Language -eq 'en' -and $String -notmatch '[぀-ゟ]|[゠-ヿ]|[ｦ-ﾟ]|[一-龯]') {
            Write-Output $String
            return
        }

        if ($Module -eq 'google_web') {
            $translatedString = Invoke-GoogleWebTranslate -String $String -TargetLanguage $Language
            if ($null -eq $translatedString -or ($translatedString -is [string] -and $translatedString.Trim() -eq '')) {
                $translatedString = $String
            }
            Write-Output $translatedString
            return
        }

        if ($Module -eq 'google_trans_new') {
            $translatePath = Join-Path -Path ((Get-Item $PSScriptRoot).Parent) -ChildPath 'translate_new.py'
        } elseif ($Module -eq 'googletrans') {
            $translatePath = Join-Path -Path ((Get-Item $PSScriptRoot).Parent) -ChildPath 'translate.py'
        } else {
            $translatePath = Join-Path -Path ((Get-Item $PSScriptRoot).Parent) -ChildPath 'translate_deepl.py'
        }

        try {
            if ([System.Environment]::OSVersion.Platform -eq 'Win32NT') {
                $tempFile = python $translatePath $String $Language $TranslateDeeplApiKey
            } elseif ([System.Environment]::OSVersion.Platform -eq 'Unix') {
                $tempFile = python3 $translatePath $String $Language $TranslateDeeplApiKey
            }
            $translatedString = Get-Content -Path $tempFile -Encoding utf8 -Raw
        } finally {
            Remove-Item -Path $tempFile -ErrorAction SilentlyContinue
        }

        if ($null -eq $translatedString -or ($translatedString -is [string] -and $translatedString.Trim() -eq '')) {
            $translatedString = $String
        }

        Write-Output $translatedString
    }
}
