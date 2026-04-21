function Start-JVWebServer {
    [CmdletBinding()]
    param(
        [int]$Port = 8600,
        [string]$Bind = '127.0.0.1',
        [switch]$NoBrowser,
        [switch]$Next,
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
    $repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $JVWebRoot))
    $designPath = Join-Path $repoRoot 'design' 'javinizer-sort'

    # Pode's Invoke-PodeScriptBlock does not preserve $using: variables, and
    # Start-PodeServer has no -ArgumentList. Pass config via env vars which
    # survive into Pode's runspace.
    $env:JVWEB_BIND = $Bind
    $env:JVWEB_PORT = $Port
    $env:JVWEB_STATIC = $staticPath
    $env:JVWEB_DESIGN = $designPath
    $env:JVWEB_LIB = $libDir
    $env:JVWEB_ROUTES = $routesDir
    $env:JVWEB_MANIFEST = $ManifestPath

    $openUrl = "http://${Bind}:${Port}/$(if ($Next) { 'next/' })"
    Write-Host "Starting Javinizer web GUI at $openUrl" -ForegroundColor Cyan

    $startParams = @{}
    # Pode's -Browse opens the root only. When -Next is set we disable it and
    # launch /next/ ourselves below once the listener is up.
    if (-not $NoBrowser -and -not $Next) { $startParams['Browse'] = $true }

    if ($Next -and -not $NoBrowser) {
        $null = Start-Job -ScriptBlock {
            param($url)
            for ($i = 0; $i -lt 60; $i++) {
                try {
                    $r = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 1 -ErrorAction Stop
                    if ($r.StatusCode -eq 200) {
                        if ($IsMacOS)     { Start-Process -FilePath 'open'     -ArgumentList $url }
                        elseif ($IsLinux) { Start-Process -FilePath 'xdg-open' -ArgumentList $url }
                        else              { Start-Process $url }
                        return
                    }
                } catch {
                    Start-Sleep -Milliseconds 250
                }
            }
        } -ArgumentList $openUrl
    }

    Start-PodeServer -Threads 16 @startParams -ScriptBlock {
        $bind = $env:JVWEB_BIND
        $port = [int]$env:JVWEB_PORT
        $staticPath = $env:JVWEB_STATIC
        $designPath = $env:JVWEB_DESIGN
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
            'Get-TranslatedString.ps1'
            'Invoke-GoogleWebTranslate.ps1'
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

        if ($designPath -and (Test-Path -LiteralPath $designPath)) {
            Add-PodeStaticRoute -Path '/next' -Source $designPath -Defaults @('index.html')
        }
        Add-PodeStaticRoute -Path '/' -Source $staticPath -Defaults @('index.html')

        Get-ChildItem -Path $routesDir -Filter 'Routes.*.ps1' | ForEach-Object { . $_.FullName }

        Write-PodeHost "Javinizer web GUI ready" -ForegroundColor Green
    }
}
