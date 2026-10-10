#Requires -Version 5.1
<#
    install.ps1 - deploy rime-tts-readback on this machine.

    Copies the Lua side into the Rime user directory and the Windows scripts into a
    binaries directory, then (optionally) starts the watcher.

    It does NOT edit your Rime schemas for you: you still have to add

        patch:
          engine/processors/+:
            - lua_processor@tts_reporter

    to each *.custom.yaml you use, then redeploy Rime.
#>
param(
    [string]$RimeDir = (Join-Path $env:APPDATA 'Rime'),
    [string]$BinDir  = $env:USERPROFILE,
    [switch]$NoStart
)

$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }

Write-Host 'rime-tts-readback installer'
Write-Host "  Rime user dir : $RimeDir"
Write-Host "  scripts dir   : $BinDir"
Write-Host ''

if (-not (Test-Path -LiteralPath $RimeDir)) { New-Item -ItemType Directory -Force -Path $RimeDir | Out-Null }
Copy-Item -LiteralPath (Join-Path $here 'rime\rime.lua') -Destination (Join-Path $RimeDir 'rime.lua') -Force
Write-Host "installed: $RimeDir\rime.lua"

Get-ChildItem -LiteralPath (Join-Path $here 'windows') -File | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $BinDir $_.Name) -Force
    Write-Host "installed: $BinDir\$($_.Name)"
}

$iconSrc = Join-Path $here 'icons'
if (Test-Path -LiteralPath $iconSrc) {
    $iconDst = Join-Path $BinDir 'icons'
    New-Item -ItemType Directory -Force -Path $iconDst | Out-Null
    Copy-Item -Path (Join-Path $iconSrc '*') -Destination $iconDst -Force
    Write-Host "installed icons: $iconDst"
}

$queue = Join-Path $env:USERPROFILE 'Rime_tts_queue'
if (-not (Test-Path -LiteralPath $queue)) { New-Item -ItemType Directory -Force -Path $queue | Out-Null }

Write-Host ''
Write-Host 'Next steps:'
Write-Host "  1) Add to each schema's *.custom.yaml under $RimeDir :"
Write-Host '         patch:'
Write-Host '           engine/processors/+:'
Write-Host '             - lua_processor@tts_reporter'
Write-Host '  2) Redeploy Rime (tray icon -> Redeploy)'

if (-not $NoStart) {
    Start-Process -FilePath 'powershell.exe' `
        -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File', (Join-Path $BinDir 'Rime_tts_watcher.ps1')) `
        -WindowStyle Hidden
    Write-Host '  3) Watcher started.'
} else {
    Write-Host "  3) Start the watcher with: $BinDir\Rime_tts_start.bat"
}
