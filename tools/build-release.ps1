#Requires -Version 5.1
<#
    build-release.ps1 - package rime-tts-readback into a distributable zip.

    Produces  dist\rime-tts-readback-<version>.zip  containing the whole project
    (rime/, windows/, macos/, icons/, tools/, install.ps1, uninstall.ps1, README.md,
    README.en.md, DEVELOPING.md, LICENSE, VERSION.txt) with a top-level folder so it extracts cleanly.

    Usage:
        powershell -ExecutionPolicy Bypass -File tools\build-release.ps1
        powershell -ExecutionPolicy Bypass -File tools\build-release.ps1 -Version 1.1.1
#>
param(
    [string]$Version,
    [string]$OutDir
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot          # repo root (script lives in tools\)
if (-not $Version) {
    # take the version from the GUI script if possible
    $gui = Join-Path $root 'windows\RimeTtsReadback.Gui.ps1'
    if (Test-Path -LiteralPath $gui) {
        $m = [regex]::Match((Get-Content -LiteralPath $gui -Raw -Encoding UTF8), "AppVersion\s*=\s*'([0-9][0-9.]*)'")
        if ($m.Success) { $Version = $m.Groups[1].Value }
    }
    if (-not $Version) { $Version = '0.0.0' }
}
if (-not $OutDir) { $OutDir = Join-Path $root 'dist' }

$name = "rime-tts-readback-$Version"
$zip  = Join-Path $OutDir "$name.zip"
$stage = Join-Path $env:TEMP ("rttr-build-" + [Guid]::NewGuid().ToString('N'))
$pkg = Join-Path $stage $name

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
New-Item -ItemType Directory -Force -Path $pkg | Out-Null

$items = @('README.md', 'README.en.md', 'DEVELOPING.md', 'LICENSE', 'install.ps1', 'uninstall.ps1', 'rime', 'windows', 'macos', 'icons', 'tools')
foreach ($i in $items) {
    $src = Join-Path $root $i
    if (Test-Path -LiteralPath $src) {
        Copy-Item -LiteralPath $src -Destination $pkg -Recurse -Force
    } else {
        Write-Warning "missing: $i"
    }
}
Set-Content -LiteralPath (Join-Path $pkg 'VERSION.txt') -Value $Version -Encoding Ascii

if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
Compress-Archive -Path $pkg -DestinationPath $zip -CompressionLevel Optimal -Force
Remove-Item -LiteralPath $stage -Recurse -Force

$fi = Get-Item -LiteralPath $zip
Write-Host ("built: " + $fi.FullName + "  (" + [math]::Round($fi.Length / 1KB, 1) + " KB)")
