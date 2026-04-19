$script:JVImageSharpLoaded = $false
$script:JVImageSharpVersion = '3.1.5'

function Get-JVImageSharpCachePath {
    $cacheDir = Join-Path $HOME '.javinizer' 'assemblies'
    if (-not (Test-Path -LiteralPath $cacheDir)) {
        New-Item -Path $cacheDir -ItemType Directory -Force | Out-Null
    }
    Join-Path $cacheDir "SixLabors.ImageSharp.$script:JVImageSharpVersion.dll"
}

function Install-JVImageSharp {
    [CmdletBinding()]
    param(
        [string]$Version = $script:JVImageSharpVersion,
        [switch]$Force
    )

    $dllPath = Get-JVImageSharpCachePath
    if ((Test-Path -LiteralPath $dllPath) -and (-not $Force)) {
        return $dllPath
    }

    $tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) "jvweb-imagesharp-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    New-Item -Path $tmpRoot -ItemType Directory -Force | Out-Null

    try {
        $nupkgUrl = "https://www.nuget.org/api/v2/package/SixLabors.ImageSharp/$Version"
        $zipPath = Join-Path $tmpRoot 'pkg.zip'
        Invoke-WebRequest -Uri $nupkgUrl -OutFile $zipPath -UseBasicParsing -ErrorAction Stop
        Expand-Archive -Path $zipPath -DestinationPath $tmpRoot -Force

        $tfms = @('net8.0', 'net7.0', 'net6.0', 'netstandard2.1', 'netstandard2.0')
        $sourceDll = $null
        foreach ($tfm in $tfms) {
            $candidate = Join-Path $tmpRoot 'lib' $tfm 'SixLabors.ImageSharp.dll'
            if (Test-Path -LiteralPath $candidate) { $sourceDll = $candidate; break }
        }
        if (-not $sourceDll) {
            throw "No suitable TFM found in ImageSharp nupkg"
        }
        Copy-Item -LiteralPath $sourceDll -Destination $dllPath -Force
        return $dllPath
    } finally {
        Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Test-JVImageSharpTypeAvailable {
    $found = [AppDomain]::CurrentDomain.GetAssemblies() |
        Where-Object { $_.GetName().Name -eq 'SixLabors.ImageSharp' } |
        Select-Object -First 1
    [bool]$found
}

function Initialize-JVImageSharp {
    [CmdletBinding()]
    param([switch]$Force)

    if ($script:JVImageSharpLoaded -and (-not $Force)) { return $true }

    # If the assembly is already loaded in this process (e.g. by a sibling
    # Pode runspace at startup), skip Add-Type — the type is already resolvable.
    if (Test-JVImageSharpTypeAvailable) {
        $script:JVImageSharpLoaded = $true
        return $true
    }

    try {
        $dllPath = Get-JVImageSharpCachePath
        if (-not (Test-Path -LiteralPath $dllPath)) {
            $dllPath = Install-JVImageSharp
        }
        Add-Type -Path $dllPath -ErrorAction Stop
        $script:JVImageSharpLoaded = $true
        return $true
    } catch {
        if (Test-JVImageSharpTypeAvailable) {
            $script:JVImageSharpLoaded = $true
            return $true
        }
        Write-Warning "Initialize-JVImageSharp: $PSItem"
        return $false
    }
}

function Invoke-JVCrop {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Source,

        [Parameter(Mandatory = $true)]
        [string]$Destination,

        [double]$WidthDivisor = 1.895734597
    )

    if (-not (Test-Path -LiteralPath $Source)) { return $false }
    if (-not (Initialize-JVImageSharp)) { return $false }

    $img = $null
    try {
        $img = [SixLabors.ImageSharp.Image]::Load($Source)
        $left = [int]($img.Width / $WidthDivisor)
        $width = $img.Width - $left
        $rect = [SixLabors.ImageSharp.Rectangle]::new($left, 0, $width, $img.Height)

        $cropAction = [System.Action[SixLabors.ImageSharp.Processing.IImageProcessingContext]] {
            param($ctx)
            [SixLabors.ImageSharp.Processing.CropExtensions]::Crop($ctx, $rect) | Out-Null
        }.GetNewClosure()
        [SixLabors.ImageSharp.Processing.ProcessingExtensions]::Mutate($img, $cropAction)

        if ($img.Metadata.ExifProfile) { $img.Metadata.ExifProfile = $null }

        $encoder = New-Object SixLabors.ImageSharp.Formats.Jpeg.JpegEncoder
        $encoder.Quality = 75
        $encoder.ColorType = [SixLabors.ImageSharp.Formats.Jpeg.JpegEncodingColor]::YCbCrRatio420

        [SixLabors.ImageSharp.ImageExtensions]::SaveAsJpeg($img, $Destination, $encoder)
        return $true
    } catch {
        Write-Warning "Invoke-JVCrop failed: $PSItem"
        return $false
    } finally {
        if ($img) { $img.Dispose() }
    }
}
