#Requires -Version 5.1
<#
    RimeTtsReadback.Gui.ps1
    Control panel for rime-tts-readback: detect Rime, install/remove the readback
    integration, enable/disable it, redeploy, and tune the parameters.

    Run with:  powershell -NoProfile -STA -ExecutionPolicy Bypass -File RimeTtsReadback.Gui.ps1
    Headless self check:  ... -File RimeTtsReadback.Gui.ps1 -Check
#>
param(
    [switch]$Check,
    [switch]$Smoke
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- paths / state
$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:RimeSrc  = Join-Path $script:RepoRoot 'rime\rime.lua'
$script:WinSrc   = $PSScriptRoot

$script:UserHome    = $env:USERPROFILE
$script:RimeUserDir = Join-Path $env:APPDATA 'Rime'
$script:QueueDir    = Join-Path $script:UserHome 'Rime_tts_queue'
$script:OffFile     = Join-Path $script:UserHome 'Rime_tts_off'
$script:ConfigFile  = Join-Path $script:UserHome 'Rime_tts_config.json'
$script:WatcherPath = Join-Path $script:UserHome 'Rime_tts_watcher.ps1'
$script:LogFile     = Join-Path $script:UserHome 'Rime_tts_watcher.log'

$script:WinFiles = @(
    'Rime_tts_watcher.ps1',
    'Rime_tts_start.bat',
    'Rime_tts_stop.bat',
    'Rime_tts_stop.ps1',
    'Rime_tts_off.bat',
    'Rime_tts_on.bat'
)

# ---------------------------------------------------------------- helpers
function Get-RimeInstall {
    $cands = New-Object System.Collections.Generic.List[string]
    foreach ($k in @('HKLM:\SOFTWARE\Rime\Weasel',
                     'HKLM:\SOFTWARE\WOW6432Node\Rime\Weasel')) {
        try {
            if (Test-Path $k) {
                $v = (Get-ItemProperty -Path $k -ErrorAction SilentlyContinue).InstallDir
                if ($v) { $cands.Add($v) }
            }
        } catch { }
    }
    foreach ($base in @('C:\Program Files\Rime', 'C:\Program Files (x86)\Rime')) {
        if (Test-Path $base) {
            Get-ChildItem $base -Directory -ErrorAction SilentlyContinue |
                ForEach-Object { $cands.Add($_.FullName) }
        }
    }
    foreach ($c in $cands) {
        $dep = Join-Path $c 'WeaselDeployer.exe'
        if (Test-Path -LiteralPath $dep) {
            $ver = ''
            if ($c -match 'weasel-([0-9][0-9.]*)') { $ver = $Matches[1] }
            return [PSCustomObject]@{ Dir = $c; Deployer = $dep; Version = $ver }
        }
    }
    return $null
}

function Get-EnabledSchemas {
    foreach ($f in @((Join-Path $script:RimeUserDir 'default.custom.yaml'),
                     (Join-Path $script:RimeUserDir 'build\default.yaml'))) {
        if (Test-Path -LiteralPath $f) {
            $txt = Get-Content -LiteralPath $f -Raw -Encoding UTF8
            $m = [regex]::Matches($txt, '(?m)^\s*-\s*\{?\s*schema\s*:\s*([A-Za-z0-9_\-]+)')
            if ($m.Count -gt 0) {
                return @($m | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
            }
        }
    }
    $bd = Join-Path $script:RimeUserDir 'build'
    if (Test-Path $bd) {
        return @(Get-ChildItem $bd -Filter '*.schema.yaml' -ErrorAction SilentlyContinue |
                 ForEach-Object { $_.BaseName -replace '\.schema$', '' } | Select-Object -Unique)
    }
    return @()
}

function Get-WatcherProcess {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -match 'Rime_tts_watcher\.ps1' }
}

function Get-FeatureState {
    $lua = Join-Path $script:RimeUserDir 'rime.lua'
    $hasLua = (Test-Path -LiteralPath $lua) -and
              ((Get-Content -LiteralPath $lua -Raw -Encoding UTF8) -match 'tts_reporter')

    $patched = @()
    if (Test-Path $script:RimeUserDir) {
        $patched = @(Get-ChildItem $script:RimeUserDir -Filter '*.custom.yaml' -ErrorAction SilentlyContinue |
                     Where-Object { (Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8) -match 'lua_processor@tts_reporter' } |
                     ForEach-Object { $_.BaseName -replace '\.custom$', '' })
    }

    $deployed = $false
    $bd = Join-Path $script:RimeUserDir 'build'
    if (Test-Path $bd) {
        $deployed = [bool](Get-ChildItem $bd -Filter '*.schema.yaml' -ErrorAction SilentlyContinue |
                     Where-Object { (Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8) -match 'tts_reporter' } |
                     Select-Object -First 1)
    }

    [PSCustomObject]@{
        HasLua     = $hasLua
        Patched    = $patched
        Deployed   = $deployed
        Muted      = (Test-Path -LiteralPath $script:OffFile)
        Watcher    = @(Get-WatcherProcess).Count -gt 0
        Installed  = ($hasLua -and $patched.Count -gt 0)
    }
}

function Get-Voices {
    try {
        Add-Type -AssemblyName System.Speech
        $s = New-Object System.Speech.Synthesis.SpeechSynthesizer
        return @($s.GetInstalledVoices() | ForEach-Object { $_.VoiceInfo.Name })
    } catch { return @() }
}

function Invoke-Redeploy {
    $ri = Get-RimeInstall
    if (-not $ri) { return '未检测到 Rime，无法部署' }
    try {
        $p = Start-Process -FilePath $ri.Deployer -ArgumentList '/deploy' `
                           -WorkingDirectory $ri.Dir -PassThru
        $ok = $p.WaitForExit(180000)
        if (-not $ok) { return '部署进程超过 3 分钟仍未结束（可能弹出了窗口，请关闭后重试）' }
        return "已重新部署 Rime (exit=$($p.ExitCode))"
    } catch {
        return "部署失败: $($_.Exception.Message)"
    }
}

# --------------------------------------------- patch a schema *.custom.yaml
function Add-ReadbackPatch([string]$file) {
    if (-not (Test-Path -LiteralPath $file)) {
        Set-Content -LiteralPath $file -Value @('patch:') -Encoding UTF8
    }
    $lines = @(Get-Content -LiteralPath $file -Encoding UTF8)
    if (($lines -join "`n") -match 'lua_processor@tts_reporter') { return $false }

    $out = New-Object System.Collections.Generic.List[string]
    $inserted = $false
    foreach ($l in $lines) {
        $out.Add($l)
        if (-not $inserted -and $l -match '^patch:\s*$') {
            $out.Add('  # >>> rime-tts-readback >>>')
            $out.Add('  engine/processors/+:')
            $out.Add('    - lua_processor@tts_reporter')
            $out.Add('  # <<< rime-tts-readback <<<')
            $inserted = $true
        }
    }
    if (-not $inserted) {
        $out.Add('')
        $out.Add('patch:')
        $out.Add('  # >>> rime-tts-readback >>>')
        $out.Add('  engine/processors/+:')
        $out.Add('    - lua_processor@tts_reporter')
        $out.Add('  # <<< rime-tts-readback <<<')
    }
    Set-Content -LiteralPath $file -Value $out -Encoding UTF8
    return $true
}

function Remove-ReadbackPatch([string]$file) {
    if (-not (Test-Path -LiteralPath $file)) { return $false }
    $lines = @(Get-Content -LiteralPath $file -Encoding UTF8)
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
    return $true
}

# ---------------------------------------------------------------- actions
function Install-Readback {
    $msgs = New-Object System.Collections.Generic.List[string]
    if (-not (Test-Path $script:RimeUserDir)) { New-Item -ItemType Directory -Force -Path $script:RimeUserDir | Out-Null }
    if (-not (Test-Path $script:QueueDir))    { New-Item -ItemType Directory -Force -Path $script:QueueDir    | Out-Null }

    if (Test-Path -LiteralPath $script:RimeSrc) {
        Copy-Item -LiteralPath $script:RimeSrc -Destination (Join-Path $script:RimeUserDir 'rime.lua') -Force
        $msgs.Add('已安装 rime.lua')
    } else {
        $msgs.Add("找不到 $script:RimeSrc")
    }

    foreach ($f in $script:WinFiles) {
        $src = Join-Path $script:WinSrc $f
        if (Test-Path -LiteralPath $src) {
            Copy-Item -LiteralPath $src -Destination (Join-Path $script:UserHome $f) -Force
        }
    }
    $msgs.Add('已安装朗读脚本到 ' + $script:UserHome)

    $schemas = Get-EnabledSchemas
    if ($schemas.Count -eq 0) {
        $msgs.Add('未找到启用的方案，未修改 schema 补丁')
    } else {
        foreach ($s in $schemas) {
            $file = Join-Path $script:RimeUserDir "$s.custom.yaml"
            if (Add-ReadbackPatch $file) { $msgs.Add("已加入回读补丁: $s.custom.yaml") }
            else { $msgs.Add("已有回读补丁: $s.custom.yaml") }
        }
    }

    Remove-Item -LiteralPath $script:OffFile -Force -ErrorAction SilentlyContinue
    $msgs.Add((Invoke-Redeploy))
    return $msgs
}

function Remove-Readback {
    $msgs = New-Object System.Collections.Generic.List[string]
    Get-WatcherProcess | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    $msgs.Add('已停止后台朗读')

    if (Test-Path $script:RimeUserDir) {
        Get-ChildItem $script:RimeUserDir -Filter '*.custom.yaml' -ErrorAction SilentlyContinue |
            ForEach-Object { if (Remove-ReadbackPatch $_.FullName) { $msgs.Add("已移除补丁: $($_.Name)") } }
        Remove-Item -LiteralPath (Join-Path $script:RimeUserDir 'rime.lua') -Force -ErrorAction SilentlyContinue
        $msgs.Add('已删除 rime.lua')
    }

    if (Test-Path $script:QueueDir) {
        Get-ChildItem $script:QueueDir -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $script:OffFile -Force -ErrorAction SilentlyContinue

    foreach ($f in $script:WinFiles) {
        Remove-Item -LiteralPath (Join-Path $script:UserHome $f) -Force -ErrorAction SilentlyContinue
    }
    $msgs.Add('已清理用户目录中的脚本副本')

    $msgs.Add((Invoke-Redeploy))
    return $msgs
}

function Enable-Readback {
    $msgs = New-Object System.Collections.Generic.List[string]
    Remove-Item -LiteralPath $script:OffFile -Force -ErrorAction SilentlyContinue
    $msgs.Add('已取消静音')
    if (-not (Get-WatcherProcess)) {
        if (Test-Path -LiteralPath $script:WatcherPath) {
            Start-Process -FilePath 'powershell.exe' -ArgumentList @(
                '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
                '-File', $script:WatcherPath) -WindowStyle Hidden
            $msgs.Add('已启动后台朗读')
        } else {
            $msgs.Add('未找到朗读脚本，请先“部署到 Rime”')
        }
    } else {
        $msgs.Add('后台朗读已在运行')
    }
    return $msgs
}

function Disable-Readback {
    $msgs = New-Object System.Collections.Generic.List[string]
    Set-Content -LiteralPath $script:OffFile -Value '1' -Encoding Ascii
    $msgs.Add('已静音（rime.lua 不再写入）')
    Get-WatcherProcess | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    $msgs.Add('已停止后台朗读')
    return $msgs
}

function Read-Config {
    if (Test-Path -LiteralPath $script:ConfigFile) {
        try { return (Get-Content -LiteralPath $script:ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json) }
        catch { return $null }
    }
    return $null
}

function Write-Config($obj) {
    $json = $obj | ConvertTo-Json
    [System.IO.File]::WriteAllText($script:ConfigFile, $json, (New-Object System.Text.UTF8Encoding($true)))
}

function Restart-Watcher {
    Get-WatcherProcess | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 400
    if (Test-Path -LiteralPath $script:WatcherPath) {
        Start-Process -FilePath 'powershell.exe' -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
            '-File', $script:WatcherPath) -WindowStyle Hidden
        return $true
    }
    return $false
}

# ---------------------------------------------------------------- self check
if ($Check) {
    $ri = Get-RimeInstall
    "Rime install : " + $(if ($ri) { "$($ri.Dir)  (v$($ri.Version))" } else { '<not found>' })
    "Rime user dir: $script:RimeUserDir  (exists=$(Test-Path $script:RimeUserDir))"
    "Enabled      : " + ((Get-EnabledSchemas) -join ', ')
    $st = Get-FeatureState
    "hasLua       : $($st.HasLua)"
    "patched      : " + ($st.Patched -join ', ')
    "deployed     : $($st.Deployed)"
    "muted        : $($st.Muted)"
    "watcher      : $($st.Watcher)"
    "voices       : " + ((Get-Voices) -join ' | ')
    "config       : " + $(if (Test-Path $script:ConfigFile) { 'present' } else { 'none' })
    exit 0
}

# ---------------------------------------------------------------- GUI
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Rime TTS Readback 控制面板'
$form.ClientSize = New-Object System.Drawing.Size(780, 800)
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false

$lblFont = New-Object System.Drawing.Font('Microsoft YaHei UI', 9, [System.Drawing.FontStyle]::Bold)

# ---- status group
$gbStatus = New-Object System.Windows.Forms.GroupBox
$gbStatus.Text = '状态'
$gbStatus.SetBounds(10, 8, 760, 152)
$form.Controls.Add($gbStatus)

function New-Row([string]$caption, [int]$y) {
    $c = New-Object System.Windows.Forms.Label
    $c.Text = $caption
    $c.SetBounds(16, $y, 110, 20)
    $c.Font = $lblFont
    $gbStatus.Controls.Add($c)
    $v = New-Object System.Windows.Forms.Label
    $v.SetBounds(132, $y, 610, 20)
    $v.AutoEllipsis = $true
    $gbStatus.Controls.Add($v)
    return $v
}
$lblRime    = New-Row 'Rime 安装:' 24
$lblUser    = New-Row '用户目录:' 48
$lblFeature = New-Row '回读功能:' 72
$lblRun     = New-Row '后台朗读:' 96

$btnRefresh = New-Object System.Windows.Forms.Button
$btnRefresh.Text = '刷新检测'
$btnRefresh.SetBounds(640, 118, 104, 26)
$gbStatus.Controls.Add($btnRefresh)

# ---- actions group
$gbOps = New-Object System.Windows.Forms.GroupBox
$gbOps.Text = '操作'
$gbOps.SetBounds(10, 166, 760, 74)
$form.Controls.Add($gbOps)

function New-Btn([string]$text, [int]$x, [int]$w) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text
    $b.SetBounds($x, 24, $w, 32)
    $gbOps.Controls.Add($b)
    return $b
}
$btnInstall  = New-Btn '部署到 Rime'   14 140
$btnEnable   = New-Btn '启用'          164 96
$btnDisable  = New-Btn '禁用'          270 96
$btnRemove   = New-Btn '删除回读功能'  376 140
$btnRedeploy = New-Btn '仅重新部署'    526 120

# ---- parameters group
$gbParams = New-Object System.Windows.Forms.GroupBox
$gbParams.Text = '参数'
$gbParams.SetBounds(10, 246, 760, 320)
$form.Controls.Add($gbParams)

function New-ParamLabel([string]$t, [int]$x, [int]$y, [int]$w = 132) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $t
    $l.SetBounds($x, $y, $w, 20)
    $gbParams.Controls.Add($l)
}

$cbVoice = New-Object System.Windows.Forms.ComboBox
$cbVoice.DropDownStyle = 'DropDownList'
$cbVoice.SetBounds(158, 24, 288, 24)
$gbParams.Controls.Add($cbVoice)
New-ParamLabel '语音' 16 28
$btnTest = New-Object System.Windows.Forms.Button
$btnTest.Text = '试听'
$btnTest.SetBounds(460, 23, 70, 26)
$gbParams.Controls.Add($btnTest)
$lblVoiceHint = New-Object System.Windows.Forms.Label
$lblVoiceHint.Text = '（中文建议选 Huihui）'
$lblVoiceHint.SetBounds(540, 28, 200, 20)
$gbParams.Controls.Add($lblVoiceHint)

function New-Num([string]$cap, [int]$y, [int]$min, [int]$max, [int]$def) {
    New-ParamLabel $cap 16 $y
    $n = New-Object System.Windows.Forms.NumericUpDown
    $n.SetBounds(158, $y - 3, 90, 24)
    $n.Minimum = $min
    $n.Maximum = $max
    $n.Value = $def
    $gbParams.Controls.Add($n)
    return $n
}
$numRate     = New-Num '语速 Rate'        62  (-10) 10  0
$numBreak    = New-Num '字间停顿 BreakMs' 96    0  1000 30
$numIdle     = New-Num '触发间隔 IdleMs' 130    0  2000 60
$numMaxWait  = New-Num '最长等待 MaxWait' 164    0  3000 200
$numThresh   = New-Num '静音阈值'         198    0  3000 180
$numPad      = New-Num '边距 PadMs'       232    0   300 15

$tip = New-Object System.Windows.Forms.ToolTip
$tip.SetToolTip($cbVoice,     '朗读使用的系统语音')
$tip.SetToolTip($numRate,     '语速 -10..10；越小每个字读得越长越清晰')
$tip.SetToolTip($numBreak,    '每个字之间插入的停顿（毫秒）')
$tip.SetToolTip($numIdle,     '上屏后等待多久算一段；越小越灵敏')
$tip.SetToolTip($numMaxWait,  '最长等待（毫秒），超过就立即朗读')
$tip.SetToolTip($numThresh,   '静音判定阈值（16 位采样），一般不用改')
$tip.SetToolTip($numPad,      '裁剪静音时保留的边距（毫秒）')

$chkAscii = New-Object System.Windows.Forms.CheckBox
$chkAscii.Text = '朗读英文与数字 (IncludeAscii)'
$chkAscii.SetBounds(16, 266, 300, 22)
$chkAscii.Checked = $true
$gbParams.Controls.Add($chkAscii)
$tip.SetToolTip($chkAscii, '勾选后英文与数字也会朗读（受输入法是否上屏限制）')

$btnSave      = New-Object System.Windows.Forms.Button
$btnSave.Text = '保存参数'
$btnSave.SetBounds(470, 262, 120, 30)
$gbParams.Controls.Add($btnSave)
$btnApply     = New-Object System.Windows.Forms.Button
$btnApply.Text = '保存并重启朗读'
$btnApply.SetBounds(600, 262, 140, 30)
$gbParams.Controls.Add($btnApply)

# ---- log group
$gbLog = New-Object System.Windows.Forms.GroupBox
$gbLog.Text = '日志'
$gbLog.SetBounds(10, 574, 760, 216)
$form.Controls.Add($gbLog)
$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Multiline = $true
$txtLog.ScrollBars = 'Vertical'
$txtLog.ReadOnly = $true
$txtLog.SetBounds(12, 22, 736, 184)
$txtLog.Font = New-Object System.Drawing.Font('Consolas', 9)
$gbLog.Controls.Add($txtLog)

# ---------------------------------------------------------------- view logic
function Log-Line([string]$m) {
    $txtLog.AppendText(('[{0}] {1}{2}' -f (Get-Date).ToString('HH:mm:ss'), $m, [Environment]::NewLine))
}
function Log-Lines($ms) { foreach ($m in $ms) { Log-Line $m } }

function Refresh-View {
    $ri = Get-RimeInstall
    if ($ri) {
        $lblRime.Text = "$($ri.Dir)   (v$($ri.Version))"
        $lblRime.ForeColor = [System.Drawing.Color]::FromArgb(0, 110, 0)
    } else {
        $lblRime.Text = '未检测到 Rime / 小狼毫'
        $lblRime.ForeColor = [System.Drawing.Color]::FromArgb(170, 0, 0)
    }

    $lblUser.Text = "$script:RimeUserDir   " + ($(if (Test-Path $script:RimeUserDir) { '(存在)' } else { '(不存在)' }))

    $st = Get-FeatureState
    if ($st.Installed -and $st.Deployed) {
        $lblFeature.Text = '已安装且已部署  |  补丁: ' + ($st.Patched -join ', ')
        $lblFeature.ForeColor = [System.Drawing.Color]::FromArgb(0, 110, 0)
    } elseif ($st.Installed) {
        $lblFeature.Text = '已安装（尚未部署）  |  补丁: ' + ($st.Patched -join ', ')
        $lblFeature.ForeColor = [System.Drawing.Color]::FromArgb(190, 120, 0)
    } else {
        $lblFeature.Text = '未安装'
        $lblFeature.ForeColor = [System.Drawing.Color]::FromArgb(170, 0, 0)
    }
    if ($st.Muted) { $lblFeature.Text += '  [已禁用/静音]' }

    $procs = @(Get-WatcherProcess)
    if ($st.Watcher) {
        $lblRun.Text = '运行中 (PID ' + ($procs.ProcessId -join ',') + ')' + $(if ($st.Muted) { '  — 静音中，不上屏写入' } else { '' })
        $lblRun.ForeColor = [System.Drawing.Color]::FromArgb(0, 110, 0)
    } else {
        $lblRun.Text = '未运行'
        $lblRun.ForeColor = [System.Drawing.Color]::FromArgb(120, 120, 120)
    }
}

function Load-ConfigIntoUi {
    $cfg = Read-Config
    $voices = Get-Voices
    $cbVoice.Items.Clear()
    foreach ($v in $voices) { [void]$cbVoice.Items.Add($v) }

    if ($cfg) {
        if ($cfg.Voice -and $cbVoice.Items.Contains($cfg.Voice)) { $cbVoice.SelectedItem = $cfg.Voice }
        if ($null -ne $cfg.Rate)      { $numRate.Value    = [int]$cfg.Rate }
        if ($null -ne $cfg.BreakMs)   { $numBreak.Value   = [int]$cfg.BreakMs }
        if ($null -ne $cfg.IdleMs)    { $numIdle.Value    = [int]$cfg.IdleMs }
        if ($null -ne $cfg.MaxWaitMs) { $numMaxWait.Value = [int]$cfg.MaxWaitMs }
        if ($null -ne $cfg.Threshold) { $numThresh.Value  = [int]$cfg.Threshold }
        if ($null -ne $cfg.PadMs)     { $numPad.Value     = [int]$cfg.PadMs }
        if ($null -ne $cfg.IncludeAscii) { $chkAscii.Checked = [bool]$cfg.IncludeAscii }
    }
    if (-not $cbVoice.SelectedItem -and $cbVoice.Items.Count -gt 0) {
        $pref = $voices | Where-Object { $_ -match 'Huihui|Chinese|zh' } | Select-Object -First 1
        $cbVoice.SelectedItem = if ($pref) { $pref } else { $cbVoice.Items[0] }
    }
}

function Collect-Config {
    [PSCustomObject]@{
        Voice        = [string]$cbVoice.SelectedItem
        Rate         = [int]$numRate.Value
        BreakMs      = [int]$numBreak.Value
        IdleMs       = [int]$numIdle.Value
        MaxWaitMs    = [int]$numMaxWait.Value
        Threshold    = [int]$numThresh.Value
        PadMs        = [int]$numPad.Value
        IncludeAscii = [bool]$chkAscii.Checked
    }
}

function Run-Action([string]$title, [scriptblock]$body) {
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    Log-Line "== $title =="
    try { Log-Lines (& $body) }
    catch { Log-Line "错误: $($_.Exception.Message)" }
    finally {
        Refresh-View
        Update-Tray
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
    }
}

# ---------------------------------------------------------------- tray icon
$script:ReallyExit   = $false
$script:TrayState    = ''
$script:BalloonShown = $false

function New-StateIcon([System.Drawing.Color]$c) {
    $bmp = New-Object System.Drawing.Bitmap 32, 32
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)
    $brush = New-Object System.Drawing.SolidBrush $c
    $g.FillEllipse($brush, 3, 3, 26, 26)
    $brush.Dispose()
    $g.Dispose()
    $ico = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
    $bmp.Dispose()
    return $ico
}
$script:IcoOk   = New-StateIcon ([System.Drawing.Color]::FromArgb(40, 160, 70))
$script:IcoWarn = New-StateIcon ([System.Drawing.Color]::FromArgb(215, 145, 0))
$script:IcoOff  = New-StateIcon ([System.Drawing.Color]::FromArgb(150, 150, 150))

$notify = New-Object System.Windows.Forms.NotifyIcon
$notify.Icon = $script:IcoOff
$notify.Text = 'Rime 回读'
$notify.Visible = $true

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$miShow    = $menu.Items.Add('显示窗口')
$miEnable  = $menu.Items.Add('启用回读')
$miDisable = $menu.Items.Add('禁用回读')
[void]$menu.Items.Add('-')
$miExit    = $menu.Items.Add('退出')
$notify.ContextMenuStrip = $menu

function Get-TrayState {
    $st = Get-FeatureState
    if (-not $st.Installed) { return 'missing' }
    if ($st.Muted)          { return 'off' }
    if (-not $st.Watcher -or -not $st.Deployed) { return 'warn' }
    return 'ok'
}

function Update-Tray {
    $s = Get-TrayState
    if ($s -ne $script:TrayState) {
        $script:TrayState = $s
        switch ($s) {
            'ok'      { $notify.Icon = $script:IcoOk;   $notify.Text = 'Rime 回读：可用' }
            'warn'    { $notify.Icon = $script:IcoWarn; $notify.Text = 'Rime 回读：未就绪（后台未运行或未部署）' }
            'off'     { $notify.Icon = $script:IcoOff;  $notify.Text = 'Rime 回读：已禁用' }
            'missing' { $notify.Icon = $script:IcoOff;  $notify.Text = 'Rime 回读：未安装' }
        }
    }
    if ($form.Visible) { Refresh-View }
}

function Show-Main {
    $form.ShowInTaskbar = $true
    $form.Show()
    $form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
    $form.Activate()
    $form.BringToFront()
}

function Hide-ToTray {
    $form.Hide()
    $form.ShowInTaskbar = $false
    if (-not $script:BalloonShown) {
        $script:BalloonShown = $true
        try {
            $notify.ShowBalloonTip(1500, 'Rime 回读', '已最小化到通知栏，单击图标可恢复。',
                                   [System.Windows.Forms.ToolTipIcon]::Info)
        } catch { }
    }
}

$notify.Add_MouseClick({
    param($sender, $evt)
    if ($evt.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Show-Main }
})
$notify.Add_MouseDoubleClick({ Show-Main })
$miShow.Add_Click({ Show-Main })
$miEnable.Add_Click({ Run-Action '启用回读（通知栏）' { Enable-Readback } })
$miDisable.Add_Click({ Run-Action '禁用回读（通知栏）' { Disable-Readback } })
$miExit.Add_Click({
    $script:ReallyExit = $true
    $timer.Stop()
    $notify.Visible = $false
    $notify.Dispose()
    $form.Close()
})

$form.Add_Resize({
    if ($form.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) { Hide-ToTray }
})
$form.Add_FormClosing({
    param($sender, $evt)
    if (-not $script:ReallyExit) {
        $evt.Cancel = $true
        Hide-ToTray
    }
})

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 2000
$timer.Add_Tick({ Update-Tray })
$timer.Start()

# ---------------------------------------------------------------- wiring
$btnRefresh.Add_Click({ Refresh-View; Log-Line '已刷新检测' })
$btnInstall.Add_Click({ Run-Action '部署到 Rime' { Install-Readback } })
$btnRemove.Add_Click({
    if ([System.Windows.Forms.MessageBox]::Show(
            "将移除 Rime 中的回读集成（补丁、rime.lua）并重新部署。继续？",
            '删除回读功能', 'YesNo', 'Warning') -eq 'Yes') {
        Run-Action '删除回读功能' { Remove-Readback }
    }
})
$btnRedeploy.Add_Click({ Run-Action '仅重新部署' { , (Invoke-Redeploy) } })
$btnEnable.Add_Click({ Run-Action '启用回读' { Enable-Readback } })
$btnDisable.Add_Click({ Run-Action '禁用回读' { Disable-Readback } })

$btnSave.Add_Click({
    try {
        Write-Config (Collect-Config)
        Log-Line '参数已保存（下次启动朗读时生效）'
    } catch { Log-Line "保存失败: $($_.Exception.Message)" }
})
$btnApply.Add_Click({
    try {
        Write-Config (Collect-Config)
        Log-Line '参数已保存'
        if (Restart-Watcher) { Log-Line '后台朗读已重启，参数已生效' }
        else { Log-Line '未找到朗读脚本，请先“部署到 Rime”' }
        Refresh-View
    } catch { Log-Line "应用失败: $($_.Exception.Message)" }
})
$btnTest.Add_Click({
    try {
        Add-Type -AssemblyName System.Speech
        $s = New-Object System.Speech.Synthesis.SpeechSynthesizer
        if ($cbVoice.SelectedItem) { $s.SelectVoice([string]$cbVoice.SelectedItem) }
        $s.Rate = [int]$numRate.Value
        $s.Speak('测试 Rime 回读')
        Log-Line '已试听'
    } catch { Log-Line "试听失败: $($_.Exception.Message)" }
})

$form.Add_Shown({
    Load-ConfigIntoUi
    Refresh-View
    Update-Tray
    Log-Line 'Rime TTS Readback 控制面板已就绪（最小化/关闭窗口会缩到通知栏）'
})

if ($Smoke) {
    [void]$form.CreateControl()
    Load-ConfigIntoUi
    Refresh-View
    Update-Tray
    Write-Output 'smoke ok: form constructed, controls loaded, tray state refreshed'
    $timer.Stop()
    $notify.Visible = $false
    $notify.Dispose()
    $form.Dispose()
    exit 0
}

[void]$form.ShowDialog()
