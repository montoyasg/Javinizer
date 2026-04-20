#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'

$playwrightDll = '/opt/playwright/bin/Release/net8.0/Microsoft.Playwright.dll'
if (Test-Path -LiteralPath $playwrightDll) {
    try {
        Add-Type -Path $playwrightDll
        Write-Host "Playwright assembly loaded for Javdb session capture." -ForegroundColor DarkGray
    } catch {
        Write-Warning "Failed to load Playwright assembly: $_"
    }
}

$port = if ($env:JVWEB_PORT) { [int]$env:JVWEB_PORT } else { 8600 }
$bind = if ($env:JVWEB_BIND) { $env:JVWEB_BIND } else { '0.0.0.0' }

& /opt/javinizer/src/Javinizer/JVWeb/JVWeb.ps1 -Port $port -Bind $bind -NoBrowser
