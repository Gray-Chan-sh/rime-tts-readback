#Requires -Version 5.1
<#
    uninstall.ps1 - remove rime-tts-readback from this machine.

    * stops the background reader
    * removes the lua_processor@tts_reporter patch from every *.custom.yaml
    * deletes %APPDATA%\Rime\rime.lua and redeploys Rime
    * removes the autostart entry
    * deletes the scripts / icons / config / queue / logs under %USERPROFILE%

    The repository folder itself is not touched.
#>
param(
    [switch]$KeepRedeploy,   # do not run the Rime redeploy
    [switch]$Force           # skip the confirmation prompt
)

$ErrorActionPreference = 'Continue'

$userHome   = $env:USERPROFILE
$rimeDir    = Join-Path $env:APPDATA 'Rime'
$queueDir   = Join-Path $userHome 'Rime_tts_queue'
$runKey     = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$runName    = 'RimeTtsReadback'

function Info($m) { Write-Host $m }

if (-not $Force) {
    $a = Read-Host 'Remove rime-tts-readback from this machine? (y/N)'
    if ($a -notmatch '^[yY]') { Info 'Cancelled.'; exit 0 }
}

# 1) stop the background reader
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match 'Rime_tts_watcher\.ps1' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Info 'stopped background reader'

# 2) remove the schema patches and rime.lua
if (Test-Path -LiteralPath $rimeDir) {
    Get-ChildItem -LiteralPath $rimeDir -Filter '*.custom.yaml' -ErrorAction SilentlyContinue | ForEach-Object {
        $file = $_.FullName
        $lines = @(Get-Content -LiteralPath $file -Encoding UTF8)
        if (($lines -join "`n") -notmatch 'tts_reporter') { return }
        $kept = New-Object System.Collections.Generic.List[string]
        foreach ($l in $lines) {
            if ($l -match 'rime-tts-readback') { continue }
            if ($l -match 'lua_processor@tts_reporter') { continue }
            $kept.Add($l)
        }
        $res = New-Object System.Collections.Generic.List[string]
        for ($i = 0; $i -lt $kept.Count; $i++) {
            $l = $kept[$i]
            if ($l -match '^\s*engine/processors/\+:\s*$') {
                $j = $i + 1
                while ($j -lt $kept.Count -and ($kept[$j].Trim() -eq '' -or $kept[$j].Trim().StartsWith('#'))) { $j++ }
                if ($j -ge $kept.Count -or -not ($kept[$j] -match '^\s*-\s')) { continue }
            }
            $res.Add($l)
        }
        Set-Content -LiteralPath $file -Value $res -Encoding UTF8
        Info ('patch removed: ' + $_.Name)
    }
    Remove-Item -LiteralPath (Join-Path $rimeDir 'rime.lua') -Force -ErrorAction SilentlyContinue
    Info 'removed rime.lua'
}

# 3) redeploy Rime
if (-not $KeepRedeploy) {
    $dep = $null
    foreach ($base in @('C:\Program Files\Rime', 'C:\Program Files (x86)\Rime')) {
        if (Test-Path -LiteralPath $base) {
            $dep = Get-ChildItem -LiteralPath $base -Directory -ErrorAction SilentlyContinue |
                   ForEach-Object { Join-Path $_.FullName 'WeaselDeployer.exe' } |
                   Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
            if ($dep) { break }
        }
    }
    if ($dep) {
        Info 'redeploying Rime ...'
        try { Start-Process -FilePath $dep -ArgumentList '/deploy' -WorkingDirectory (Split-Path -Parent $dep) -Wait }
        catch { Info ('redeploy failed: ' + $_.Exception.Message) }
    } else { Info 'WeaselDeployer.exe not found; skipping redeploy' }
}

# 4) autostart entry
Remove-ItemProperty -Path $runKey -Name $runName -ErrorAction SilentlyContinue
Info 'removed autostart entry'

# 5) user files
foreach ($f in @('Rime_tts_watcher.ps1', 'Rime_tts_start.bat', 'Rime_tts_stop.bat', 'Rime_tts_stop.ps1',
                 'Rime_tts_off.bat', 'Rime_tts_on.bat', 'Rime_tts_watcher.log', 'Rime_tts_watcher.log.1',
                 'Rime_tts_config.json', 'Rime_tts_off', 'RimeTtsReadback.Gui.ps1', 'RimeTtsReadback.bat')) {
    Remove-Item -LiteralPath (Join-Path $userHome $f) -Force -ErrorAction SilentlyContinue
}
Remove-Item -LiteralPath $queueDir -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath (Join-Path $userHome 'icons') -Recurse -Force -ErrorAction SilentlyContinue
Info 'removed scripts / config / queue / icons'

Info 'Done. The repository folder was not touched.'
