function Start-JVWebServer {
    [CmdletBinding()]
    param(
        [int]$Port = 8600,
        [string]$Bind = '127.0.0.1',
        [switch]$NoBrowser,
        [Parameter(Mandatory = $true)]
        [string]$JVWebRoot,
        [Parameter(Mandatory = $true)]
        [string]$ManifestPath
    )

    Import-Module Pode -Force

    # Warm SixLabors.ImageSharp for poster cropping. On first run this downloads
    # a ~1MB DLL from nuget.org into ~/.javinizer/assemblies/ and caches it.
    . (Join-Path $JVWebRoot 'Lib' 'Invoke-JVCrop.ps1')
    $cacheDllPath = Get-JVImageSharpCachePath
    if (Test-Path -LiteralPath $cacheDllPath) {
        if (Initialize-JVImageSharp) {
            Write-Host "Poster crop: ImageSharp ready (cached)" -ForegroundColor DarkGray
        } else {
            Write-Host "Poster crop: ImageSharp load failed. Will fall back to uncropped fanart copy." -ForegroundColor Yellow
        }
    } else {
        Write-Host "Poster crop: downloading ImageSharp..." -ForegroundColor DarkGray
        if (Initialize-JVImageSharp) {
            Write-Host "Poster crop: ImageSharp ready" -ForegroundColor DarkGray
        } else {
            Write-Host "Poster crop: ImageSharp unavailable (network?). Will fall back to uncropped fanart copy." -ForegroundColor Yellow
        }
    }

    $staticPath = Join-Path $JVWebRoot 'static'
    $libDir = Join-Path $JVWebRoot 'Lib'
    $routesDir = Join-Path $JVWebRoot 'Server'

    # Pode's Invoke-PodeScriptBlock does not preserve $using: variables, and
    # Start-PodeServer has no -ArgumentList. Pass config via env vars which
    # survive into Pode's runspace.
    $env:JVWEB_BIND = $Bind
    $env:JVWEB_PORT = $Port
    $env:JVWEB_STATIC = $staticPath
    $env:JVWEB_LIB = $libDir
    $env:JVWEB_ROUTES = $routesDir
    $env:JVWEB_MANIFEST = $ManifestPath

    Write-Host "Starting Javinizer web GUI at http://$Bind`:$Port" -ForegroundColor Cyan

    $startParams = @{}
    if (-not $NoBrowser) { $startParams['Browse'] = $true }

    Start-PodeServer -Threads 4 @startParams -ScriptBlock {
        $bind = $env:JVWEB_BIND
        $port = [int]$env:JVWEB_PORT
        $staticPath = $env:JVWEB_STATIC
        $libDir = $env:JVWEB_LIB
        $routesDir = $env:JVWEB_ROUTES
        $manifest = $env:JVWEB_MANIFEST

        Add-PodeEndpoint -Address $bind -Port $port -Protocol Http

        # Import Javinizer into every Pode runspace (route handlers run in isolated runspaces)
        Import-PodeModule -Path $manifest

        # Also expose selected Private/ helpers that our Lib wrappers call directly.
        # Private functions are not exported by the module, but we need a few at the
        # top level inside route handlers. Dot-source them into every runspace.
        $moduleRoot = (Get-Item $manifest).Directory.FullName
        $privateNeeded = @(
            'Convert-JVTitle.ps1'
        )
        foreach ($name in $privateNeeded) {
            $p = Join-Path $moduleRoot 'Private' $name
            if (Test-Path $p) { Use-PodeScript -Path $p }
        }

        # Dot-source Lib helper scripts into every Pode runspace
        Get-ChildItem -Path $libDir -Filter '*.ps1' | ForEach-Object {
            Use-PodeScript -Path $_.FullName
        }

        # Also load into this (setup) runspace so Get-JVSettings is callable below
        Import-Module $manifest -Force -Global
        Get-ChildItem -Path $libDir -Filter '*.ps1' | ForEach-Object { . $_.FullName }

        Set-PodeState -Name 'scrapeCache' -Value @{} | Out-Null
        Set-PodeState -Name 'settings' -Value (Get-JVSettings) | Out-Null

        Add-PodeStaticRoute -Path '/' -Source $staticPath -Defaults @('index.html')

        Get-ChildItem -Path $routesDir -Filter 'Routes.*.ps1' | ForEach-Object { . $_.FullName }

        Write-PodeHost "Javinizer web GUI ready" -ForegroundColor Green
    }
}
