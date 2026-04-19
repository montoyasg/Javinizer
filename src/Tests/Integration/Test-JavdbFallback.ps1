# Exercises R18.dev-miss -> javdb fallback -> auto-session -> full data object.
# Prereq: Playwright installed; user has javdb account; Start-JVWeb running.
# Usage:   pwsh ./src/Tests/Integration/Test-JavdbFallback.ps1 [-Port 8600] [-Id GOV-004]

[CmdletBinding()]
param(
    [int]$Port = 8600,
    [string]$Id = 'GOV-004'
)

$ErrorActionPreference = 'Stop'
$base = "http://127.0.0.1:$Port"

$moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' 'Javinizer')
Import-Module (Join-Path $moduleRoot 'Javinizer.psd1') -Force

Write-Host "[1/4] Priming javdb session cache..." -ForegroundColor Cyan
$sess = Get-JavdbSession
if (-not $sess) { throw 'Failed to acquire javdb session.' }
Write-Host "  session length: $($sess.Length)" -ForegroundColor DarkGray

Write-Host "[2/4] Checking JVWeb is reachable at $base..." -ForegroundColor Cyan
try {
    $null = Invoke-RestMethod -Method Get -Uri "$base/api/browse?path=/" -TimeoutSec 5
} catch {
    throw "JVWeb not reachable at $base. Start it with Start-JVWeb -Port $Port first. Error: $PSItem"
}

Write-Host "[3/4] Manual-search for $Id..." -ForegroundColor Cyan
$resp = Invoke-RestMethod -Method Post -Uri "$base/api/manual-search" `
    -Body (@{ query = $Id } | ConvertTo-Json) -ContentType 'application/json'

if ($resp.data.Source -ne 'Javdb') {
    throw "Expected Source=Javdb, got [$($resp.data.Source)]"
}
if (-not $resp.data.Id)       { throw 'Missing Id on data object' }
if (-not $resp.data.Title)    { throw 'Missing Title on data object' }
if (-not $resp.data.CoverUrl) { throw 'Missing CoverUrl on data object' }
if (-not $resp.data.Actress -or @($resp.data.Actress).Count -eq 0) {
    throw 'Missing Actress array'
}
if (-not $resp.data.ScreenshotUrl -or @($resp.data.ScreenshotUrl).Count -eq 0) {
    throw 'Missing ScreenshotUrl array'
}

Write-Host "[4/4] PASS: $Id resolved via javdb fallback" -ForegroundColor Green
$resp.data | ConvertTo-Json -Depth 5
