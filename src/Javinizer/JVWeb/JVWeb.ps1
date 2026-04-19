#!/usr/bin/env pwsh
[CmdletBinding()]
param(
    [ValidateRange(1, 65535)]
    [int]$Port = 8600,

    [switch]$NoBrowser,

    [string]$Bind = '127.0.0.1'
)

$ErrorActionPreference = 'Stop'

$script:JVWebRoot = $PSScriptRoot
$moduleRoot = (Get-Item $PSScriptRoot).Parent.FullName
$manifestPath = Join-Path $moduleRoot 'Javinizer.psd1'

if (-not (Get-Command Get-JVSettings -ErrorAction SilentlyContinue)) {
    if (Test-Path $manifestPath) {
        Import-Module $manifestPath -Force -Global
    } else {
        throw "Javinizer module not found. Import-Module Javinizer first, or place JVWeb/ under src/Javinizer/."
    }
}

if (-not (Get-Module -ListAvailable -Name Pode)) {
    Write-Host "Pode module not found." -ForegroundColor Yellow
    $ans = Read-Host "Install Pode to CurrentUser scope now? (y/n)"
    if ($ans -eq 'y') {
        Install-Module Pode -Scope CurrentUser -Force -AllowClobber
    } else {
        throw "Pode is required. Run: Install-Module Pode -Scope CurrentUser"
    }
}

Get-ChildItem -Path (Join-Path $script:JVWebRoot 'Lib') -Filter '*.ps1' | ForEach-Object { . $_.FullName }
. (Join-Path $script:JVWebRoot 'Server' 'Start-JVWebServer.ps1')

Start-JVWebServer -Port $Port -Bind $Bind -NoBrowser:$NoBrowser -JVWebRoot $script:JVWebRoot -ManifestPath $manifestPath
