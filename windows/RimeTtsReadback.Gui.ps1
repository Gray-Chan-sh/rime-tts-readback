#Requires -Version 5.1
<#
    RimeTtsReadback.Gui.ps1
    Control panel for rime-tts-readback: detect Rime, install/remove the readback
    integration, enable/disable it, redeploy, tune parameters, filter by program,
    autostart, watchdog, global hotkey and tray icon.

    Run:      powershell -NoProfile -STA -ExecutionPolicy Bypass -File RimeTtsReadback.Gui.ps1
    Tray:     ... -Tray      (start hidden, tray icon only - used for autostart)
    Check:    ... -Check     (print a detection report, no window)
    Smoke:    ... -Smoke     (build the form head-less and exit)
#>
param(
    [switch]$Check,
    [switch]$Smoke,
    [switch]$Tray,
    [switch]$HotkeyDialog,
    [switch]$AboutDialog
)

$ErrorActionPreference = 'Stop'

$script:AppVersion = '1.0.0'
$script:RepoUrl    = 'https://github.com/Gray-Chan-sh/rime-tts-readback'

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
$script:RunKey      = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$script:RunName     = 'RimeTtsReadback'

$script:WinFiles = @(
    'Rime_tts_watcher.ps1', 'Rime_tts_start.bat', 'Rime_tts_stop.bat',
    'Rime_tts_stop.ps1', 'Rime_tts_off.bat', 'Rime_tts_on.bat'
)

# ---------------------------------------------------------------- helpers
function Get-RimeInstall {
    $cands = New-Object System.Collections.Generic.List[string]
    foreach ($k in @('HKLM:\SOFTWARE\Rime\Weasel', 'HKLM:\SOFTWARE\WOW6432Node\Rime\Weasel')) {
        try {
            if (Test-Path $k) {
                $v = (Get-ItemProperty -Path $k -ErrorAction SilentlyContinue).InstallDir
                if ($v) { $cands.Add($v) }
            }
        } catch { }
    }
    foreach ($base in @('C:\Program Files\Rime', 'C:\Program Files (x86)\Rime')) {
        if (Test-Path $base) {
            Get-ChildItem $base -Directory -ErrorAction SilentlyContinue | ForEach-Object { $cands.Add($_.FullName) }
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
            if ($m.Count -gt 0) { return @($m | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique) }
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
        HasLua    = $hasLua
        Patched   = $patched
        Deployed  = $deployed
        Muted     = (Test-Path -LiteralPath $script:OffFile)
        Watcher   = @(Get-WatcherProcess).Count -gt 0
        Installed = ($hasLua -and $patched.Count -gt 0)
    }
}

function Get-Voices {
    try {
        Add-Type -AssemblyName System.Speech
        $s = New-Object System.Speech.Synthesis.SpeechSynthesizer
        return @($s.GetInstalledVoices() | ForEach-Object { $_.VoiceInfo.Name })
    } catch { return @() }
}

# only processes that own a visible, titled top-level window (what the user can actually see)
function Get-VisibleApps {
    $rows = @()
    try { $rows = [RimeHK.WinEnum]::Visible() } catch { return @() }
    $noise = @('TextInputHost', 'SystemSettings', 'ApplicationFrameHost', 'ShellExperienceHost',
               'StartMenuExperienceHost', 'SearchHost', 'LockApp',
               'WindowsInternal.ComposableShell.Experiences.TextInput.InputApp')
    $map = @{}
    foreach ($r in $rows) {
        $parts = $r -split "`t", 3
        if ($parts.Count -lt 3) { continue }
        $procId = 0
        [void][int]::TryParse($parts[0], [ref]$procId)
        if ($procId -le 0) { continue }
        $pname = (Get-Process -Id $procId -ErrorAction SilentlyContinue).ProcessName
        if (-not $pname) { continue }
        if ($noise -contains $pname) { continue }
        if (-not $map.ContainsKey($pname)) {
            $hv = [int64]0
            [void][int64]::TryParse($parts[1], [ref]$hv)
            $map[$pname] = [PSCustomObject]@{ Title = $parts[2]; Hwnd = [IntPtr]$hv }
        }
    }
    return @($map.GetEnumerator() | Sort-Object Name | ForEach-Object {
        [PSCustomObject]@{ Name = $_.Key; Title = $_.Value.Title; Hwnd = $_.Value.Hwnd }
    })
}

function Get-AppIcon([IntPtr]$hwnd, [string]$procName) {
    if ($hwnd -ne [IntPtr]::Zero) {
        try {
            $hicon = [RimeHK.WinEnum]::WindowIcon($hwnd)
            if ($hicon -ne [IntPtr]::Zero) { return ([System.Drawing.Icon]::FromHandle($hicon)).ToBitmap() }
        } catch { }
    }
    try {
        $p = Get-Process -Name $procName -ErrorAction SilentlyContinue | Where-Object { $_.Path } | Select-Object -First 1
        if ($p -and $p.Path) { return ([System.Drawing.Icon]::ExtractAssociatedIcon($p.Path)).ToBitmap() }
    } catch { }
    return $null
}

function Invoke-Redeploy {
    $ri = Get-RimeInstall
    if (-not $ri) { return '未检测到 Rime，无法部署' }
    try {
        $p = Start-Process -FilePath $ri.Deployer -ArgumentList '/deploy' -WorkingDirectory $ri.Dir -PassThru
        if (-not $p.WaitForExit(180000)) { return '部署进程超过 3 分钟仍未结束（可能弹出了窗口，请关闭后重试）' }
        return "已重新部署 Rime (exit=$($p.ExitCode))"
    } catch { return "部署失败: $($_.Exception.Message)" }
}

function Add-ReadbackPatch([string]$file) {
    if (-not (Test-Path -LiteralPath $file)) { Set-Content -LiteralPath $file -Value @('patch:') -Encoding UTF8 }
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

# ---------------------------------------------------------------- config
function Read-Config {
    if (Test-Path -LiteralPath $script:ConfigFile) {
        try { return (Get-Content -LiteralPath $script:ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json) }
        catch { return $null }
    }
    return $null
}
function Write-Config($obj) {
    $json = $obj | ConvertTo-Json -Depth 5
    [System.IO.File]::WriteAllText($script:ConfigFile, $json, (New-Object System.Text.UTF8Encoding($true)))
}

# ---------------------------------------------------------------- actions
function Start-Watcher {
    if (Get-WatcherProcess) { return $false }
    if (-not (Test-Path -LiteralPath $script:WatcherPath)) { return $false }
    Start-Process -FilePath 'powershell.exe' -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
        '-File', $script:WatcherPath) -WindowStyle Hidden
    return $true
}
function Stop-Watcher {
    Get-WatcherProcess | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

function Install-Readback {
    $msgs = New-Object System.Collections.Generic.List[string]
    if (-not (Test-Path $script:RimeUserDir)) { New-Item -ItemType Directory -Force -Path $script:RimeUserDir | Out-Null }
    if (-not (Test-Path $script:QueueDir))    { New-Item -ItemType Directory -Force -Path $script:QueueDir    | Out-Null }

    if (Test-Path -LiteralPath $script:RimeSrc) {
        Copy-Item -LiteralPath $script:RimeSrc -Destination (Join-Path $script:RimeUserDir 'rime.lua') -Force
        $msgs.Add('已安装 rime.lua')
    } else { $msgs.Add("找不到 $script:RimeSrc") }

    foreach ($f in $script:WinFiles) {
        $src = Join-Path $script:WinSrc $f
        if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination (Join-Path $script:UserHome $f) -Force }
    }
    $msgs.Add('已安装朗读脚本到 ' + $script:UserHome)

    $schemas = Get-EnabledSchemas
    if ($schemas.Count -eq 0) { $msgs.Add('未找到启用的方案，未修改 schema 补丁') }
    else {
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
    Stop-Watcher
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
    foreach ($f in $script:WinFiles) { Remove-Item -LiteralPath (Join-Path $script:UserHome $f) -Force -ErrorAction SilentlyContinue }
    $msgs.Add('已清理用户目录中的脚本副本')
    $msgs.Add((Invoke-Redeploy))
    return $msgs
}

function Enable-Readback {
    $msgs = New-Object System.Collections.Generic.List[string]
    Remove-Item -LiteralPath $script:OffFile -Force -ErrorAction SilentlyContinue
    $msgs.Add('已取消静音')
    if (Start-Watcher) { $msgs.Add('已启动后台朗读') } else { $msgs.Add('后台朗读已在运行（或缺少脚本，请先部署）') }
    return $msgs
}

function Disable-Readback {
    $msgs = New-Object System.Collections.Generic.List[string]
    Set-Content -LiteralPath $script:OffFile -Value '1' -Encoding Ascii
    $msgs.Add('已静音（rime.lua 不再写入）')
    Stop-Watcher
    $msgs.Add('已停止后台朗读')
    return $msgs
}

# ---------------------------------------------------------------- autostart
function Get-Autostart {
    try { return [bool](Get-ItemProperty -Path $script:RunKey -Name $script:RunName -ErrorAction SilentlyContinue) }
    catch { return $false }
}
function Set-Autostart([bool]$on) {
    $gui = Join-Path $PSScriptRoot 'RimeTtsReadback.Gui.ps1'
    $val = "powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$gui`" -Tray"
    try {
        if ($on) { New-ItemProperty -Path $script:RunKey -Name $script:RunName -Value $val -PropertyType String -Force | Out-Null }
        else { Remove-ItemProperty -Path $script:RunKey -Name $script:RunName -ErrorAction SilentlyContinue }
        return $true
    } catch { return $false }
}

# ---------------------------------------------------------------- self check
if ($Check) {
    $ri = Get-RimeInstall
    "version      : $script:AppVersion"
    "Rime install : " + $(if ($ri) { "$($ri.Dir)  (v$($ri.Version))" } else { '<not found>' })
    "Rime user dir: $script:RimeUserDir  (exists=$(Test-Path $script:RimeUserDir))"
    "Enabled      : " + ((Get-EnabledSchemas) -join ', ')
    $st = Get-FeatureState
    "hasLua       : $($st.HasLua)"
    "patched      : " + ($st.Patched -join ', ')
    "deployed     : $($st.Deployed)"
    "muted        : $($st.Muted)"
    "watcher      : $($st.Watcher)"
    "autostart    : $(Get-Autostart)"
    "voices       : " + ((Get-Voices) -join ' | ')
    "config       : " + $(if (Test-Path $script:ConfigFile) { 'present' } else { 'none' })
    exit 0
}

# ---------------------------------------------------------------- assemblies / IPC window
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

if (-not ('RimeHK.HotKeyWindow' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Windows.Forms;
using System.Runtime.InteropServices;
namespace RimeHK {
    public class HotKeyWindow : NativeWindow, IDisposable {
        private const int WM_HOTKEY = 0x0312;
        public const int WM_SHOW = 0x8001;   // WM_APP + 1
        [DllImport("user32.dll")] public static extern bool RegisterHotKey(IntPtr hWnd, int id, int fsModifiers, int vk);
        [DllImport("user32.dll")] public static extern bool UnregisterHotKey(IntPtr hWnd, int id);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindow(string cls, string win);
        [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);
        public event Action<int> HotKeyPressed;
        public event Action ShowRequested;
        public HotKeyWindow() {
            var cp = new CreateParams();
            cp.Caption = "RimeTtsReadbackHotKey";
            cp.Parent = IntPtr.Zero;   // normal (never shown) top-level window so FindWindow can locate it
            this.CreateHandle(cp);
        }
        public bool Register(int id, int mods, int vk) { return RegisterHotKey(this.Handle, id, mods, vk); }
        public void Unregister(int id) { UnregisterHotKey(this.Handle, id); }
        protected override void WndProc(ref Message m) {
            if (m.Msg == WM_HOTKEY) { var h = HotKeyPressed; if (h != null) h(m.WParam.ToInt32()); }
            else if (m.Msg == WM_SHOW) { var s = ShowRequested; if (s != null) s(); }
            base.WndProc(ref m);
        }
        public void Dispose() { if (this.Handle != IntPtr.Zero) this.DestroyHandle(); }
    }

    public static class WinEnum {
        [DllImport("user32.dll")] private static extern bool EnumWindows(EnumProc cb, IntPtr l);
        [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr h);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowText(IntPtr h, System.Text.StringBuilder s, int n);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowTextLength(IntPtr h);
        [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
        [DllImport("user32.dll")] private static extern int GetWindowLong(IntPtr h, int idx);
        [DllImport("user32.dll")] private static extern IntPtr SendMessage(IntPtr h, int msg, IntPtr w, IntPtr l);
        private delegate bool EnumProc(IntPtr h, IntPtr l);
        // returns "pid\thwnd\ttitle" for every visible, titled, non-tool top-level window
        public static System.Collections.Generic.List<string> Visible() {
            var list = new System.Collections.Generic.List<string>();
            EnumWindows(delegate(IntPtr h, IntPtr l) {
                if (!IsWindowVisible(h)) return true;
                if (GetWindowTextLength(h) == 0) return true;
                if ((GetWindowLong(h, -20) & 0x00000080) != 0) return true;   // WS_EX_TOOLWINDOW
                uint pid; GetWindowThreadProcessId(h, out pid);
                var sb = new System.Text.StringBuilder(512);
                GetWindowText(h, sb, sb.Capacity);
                list.Add(pid.ToString() + "\t" + h.ToInt64().ToString() + "\t" + sb.ToString());
                return true;
            }, IntPtr.Zero);
            return list;
        }
        // best-effort window icon (WM_GETICON small2 / small / big)
        public static IntPtr WindowIcon(IntPtr hwnd) {
            IntPtr h = SendMessage(hwnd, 0x007F, new IntPtr(2), IntPtr.Zero);
            if (h == IntPtr.Zero) h = SendMessage(hwnd, 0x007F, new IntPtr(0), IntPtr.Zero);
            if (h == IntPtr.Zero) h = SendMessage(hwnd, 0x007F, new IntPtr(1), IntPtr.Zero);
            return h;
        }
    }

    public static class Keys2 {
        [DllImport("user32.dll")] private static extern short GetKeyState(int vKey);
        // true while either Windows key is held
        public static bool WinDown() {
            return ((GetKeyState(0x5B) & 0x8000) != 0) || ((GetKeyState(0x5C) & 0x8000) != 0);
        }
    }
}
'@ -ReferencedAssemblies 'System.Windows.Forms'
}

# single instance: the first instance owns the mutex; a later launch informs and exits.
if (-not ($Check -or $Smoke -or $HotkeyDialog -or $AboutDialog)) {
    $script:Mutex = New-Object System.Threading.Mutex($false, 'Local\RimeTtsReadback.Gui')
    $first = $false
    try { $first = $script:Mutex.WaitOne(0) } catch { $first = $true }
    if (-not $first) {
        [void][System.Windows.Forms.MessageBox]::Show(
            'Rime TTS Readback 已在运行（见右下角通知栏图标）。', 'Rime TTS Readback', 'OK', 'Information')
        exit 0
    }
}
$script:HkWnd = New-Object RimeHK.HotKeyWindow

# ---------------------------------------------------------------- icons
function New-StateIcon([System.Drawing.Color]$c) {
    $bmp = New-Object System.Drawing.Bitmap 32, 32
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)
    $brush = New-Object System.Drawing.SolidBrush $c
    $g.FillEllipse($brush, 3, 3, 26, 26)
    $brush.Dispose(); $g.Dispose()
    $ico = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
    $bmp.Dispose()
    return $ico
}
function Resolve-IconPath([string]$name) {
    foreach ($base in @((Join-Path $PSScriptRoot 'icons'),
                        (Join-Path $script:UserHome 'icons'),
                        (Join-Path $script:RepoRoot 'icons'))) {
        $p = Join-Path $base $name
        if (Test-Path -LiteralPath $p) { return $p }
    }
    return $null
}
function Load-IconOrDraw([string]$name, [System.Drawing.Color]$fallback) {
    $p = Resolve-IconPath $name
    if ($p) { try { return (New-Object System.Drawing.Icon $p) } catch { } }
    return (New-StateIcon $fallback)
}
$script:IcoApp  = Load-IconOrDraw 'rime-tts-readback.ico' ([System.Drawing.Color]::FromArgb(46, 120, 190))
$script:IcoOk   = Load-IconOrDraw 'tray-ok.ico'   ([System.Drawing.Color]::FromArgb(46, 160, 67))
$script:IcoWarn = Load-IconOrDraw 'tray-warn.ico' ([System.Drawing.Color]::FromArgb(224, 150, 0))
$script:IcoOff  = Load-IconOrDraw 'tray-off.ico'  ([System.Drawing.Color]::FromArgb(150, 150, 150))

# ---------------------------------------------------------------- GUI
$form = New-Object System.Windows.Forms.Form
$form.Text = "Rime TTS Readback 控制面板  v$script:AppVersion"
$form.ClientSize = New-Object System.Drawing.Size(780, 1108)
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false
$form.BackColor = [System.Drawing.Color]::FromArgb(245, 246, 249)

# ---- header band
$header = New-Object System.Windows.Forms.Panel
$header.SetBounds(0, 0, 780, 64)
$header.BackColor = [System.Drawing.Color]::FromArgb(46, 120, 190)
$form.Controls.Add($header)
$picIcon = New-Object System.Windows.Forms.PictureBox
$picIcon.SetBounds(14, 10, 44, 44)
$picIcon.SizeMode = 'Zoom'
try { $picIcon.Image = $script:IcoApp.ToBitmap() } catch { }
$header.Controls.Add($picIcon)
$lblHeadTitle = New-Object System.Windows.Forms.Label
$lblHeadTitle.Text = 'Rime TTS Readback'
$lblHeadTitle.ForeColor = [System.Drawing.Color]::White
$lblHeadTitle.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 13, [System.Drawing.FontStyle]::Bold)
$lblHeadTitle.BackColor = [System.Drawing.Color]::Transparent
$lblHeadTitle.SetBounds(68, 9, 420, 26)
$header.Controls.Add($lblHeadTitle)
$lblHeadSub = New-Object System.Windows.Forms.Label
$lblHeadSub.Text = "小狼毫上屏朗读控制面板    v$script:AppVersion"
$lblHeadSub.ForeColor = [System.Drawing.Color]::FromArgb(214, 232, 248)
$lblHeadSub.BackColor = [System.Drawing.Color]::Transparent
$lblHeadSub.SetBounds(70, 36, 420, 20)
$header.Controls.Add($lblHeadSub)

$tip = New-Object System.Windows.Forms.ToolTip
$tip.IsBalloon = $true
$tip.ShowAlways = $true
$tip.AutoPopDelay = 30000
$tip.InitialDelay = 250
$tip.ReshowDelay = 100

$lblFont = New-Object System.Drawing.Font('Microsoft YaHei UI', 9, [System.Drawing.FontStyle]::Bold)

# ---- "About" button lives in the header (top-right), out of the action row
$btnAbout = New-Object System.Windows.Forms.Button
$btnAbout.Text = '关于'
$btnAbout.SetBounds(686, 17, 76, 30)
$btnAbout.FlatStyle = 'Flat'
$btnAbout.UseVisualStyleBackColor = $false
$btnAbout.BackColor = [System.Drawing.Color]::FromArgb(46, 120, 190)
$btnAbout.ForeColor = [System.Drawing.Color]::White
$btnAbout.FlatAppearance.BorderSize = 1
$btnAbout.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(122, 176, 226)
$btnAbout.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(70, 140, 205)
$btnAbout.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::FromArgb(38, 105, 168)
$header.Controls.Add($btnAbout)
$tip.SetToolTip($btnAbout, '显示版本、安装位置与快捷键信息。')

# ---- status group
$gbStatus = New-Object System.Windows.Forms.GroupBox
$gbStatus.Text = '状态'
$gbStatus.SetBounds(10, 76, 760, 152)
$gbStatus.BackColor = [System.Drawing.Color]::White
$form.Controls.Add($gbStatus)

function New-Row([string]$caption, [int]$y, [string]$tipText) {
    $dot = New-Object System.Windows.Forms.Label
    $dot.Text = '●'
    $dot.SetBounds(18, $y, 14, 20)
    $dot.ForeColor = [System.Drawing.Color]::FromArgb(190, 195, 200)
    $gbStatus.Controls.Add($dot)
    $c = New-Object System.Windows.Forms.Label
    $c.Text = $caption
    $c.SetBounds(36, $y, 100, 20)
    $c.Font = $lblFont
    $gbStatus.Controls.Add($c)
    $v = New-Object System.Windows.Forms.Label
    $v.SetBounds(140, $y, 600, 20)
    $v.AutoEllipsis = $true
    $gbStatus.Controls.Add($v)
    $v.Tag = $dot
    if ($tipText) { $tip.SetToolTip($c, $tipText); $tip.SetToolTip($v, $tipText); $tip.SetToolTip($dot, $tipText) }
    return $v
}
$lblRime    = New-Row 'Rime 安装:' 24 '检测到的 Rime/小狼毫 安装目录与版本。未找到说明未安装或路径异常。'
$lblUser    = New-Row '用户目录:' 48 'Rime 用户配置目录（%APPDATA%\Rime）。rime.lua 与各 *.custom.yaml 都在这里。'
$lblFeature = New-Row '回读功能:' 72 '是否已把 lua_processor@tts_reporter 写入各方案补丁、以及是否已部署。[已禁用/静音] 表示当前不朗读。'
$lblRun     = New-Row '后台朗读:' 96 '负责实际发声的后台进程。未运行时不会朗读；静音时 rime.lua 也不再写入队列。'

$btnRefresh = New-Object System.Windows.Forms.Button
$btnRefresh.Text = '刷新检测'
$btnRefresh.SetBounds(640, 118, 104, 26)
$gbStatus.Controls.Add($btnRefresh)
$tip.SetToolTip($btnRefresh, '重新检测：Rime 安装、方案补丁、是否已部署、后台进程与静音状态。')

# ---- actions group
$gbOps = New-Object System.Windows.Forms.GroupBox
$gbOps.Text = '操作'
$gbOps.SetBounds(10, 234, 760, 74)
$gbOps.BackColor = [System.Drawing.Color]::White
$form.Controls.Add($gbOps)

function Set-BtnStyle($b, [switch]$Primary) {
    $b.FlatStyle = 'Flat'
    $b.UseVisualStyleBackColor = $false
    $b.FlatAppearance.BorderSize = 1
    if ($Primary) {
        $b.BackColor = [System.Drawing.Color]::FromArgb(46, 120, 190)
        $b.ForeColor = [System.Drawing.Color]::White
        $b.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(38, 105, 168)
        $b.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(58, 135, 205)
        $b.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::FromArgb(34, 96, 152)
    } else {
        $b.BackColor = [System.Drawing.Color]::White
        $b.ForeColor = [System.Drawing.Color]::FromArgb(50, 55, 62)
        $b.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(202, 208, 216)
        $b.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(234, 243, 251)
        $b.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::FromArgb(214, 232, 248)
    }
}
function New-Btn([string]$text, [int]$x, [int]$w, [string]$tipText, [switch]$Primary) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text
    $b.SetBounds($x, 24, $w, 32)
    Set-BtnStyle $b -Primary:$Primary
    $gbOps.Controls.Add($b)
    if ($tipText) { $tip.SetToolTip($b, $tipText) }
    return $b
}
$btnInstall  = New-Btn '部署到 Rime'   14 128 '安装 rime.lua 与朗读脚本，给所有已启用方案加上回读补丁，然后重新部署 Rime。' -Primary
$btnToggle   = New-Btn '启用 / 禁用'   150 176 '切换回读开关：已启用时点击=禁用（静音并停止后台）；已禁用时点击=启用（取消静音并启动后台）。'
$btnRemove   = New-Btn '删除回读功能'  334 128 '从 Rime 移除所有回读补丁与 rime.lua，并重新部署（会先二次确认）。'
$btnRedeploy = New-Btn '仅重新部署'    470 108 '只调用 Rime 的重新部署，不改动任何配置。'
$btnHelp     = New-Btn '一键安装'      586 160 '一键完成：部署到 Rime + 启用 + 按需设置开机自启。' -Primary

# ---- parameters group
$gbParams = New-Object System.Windows.Forms.GroupBox
$gbParams.Text = '参数'
$gbParams.SetBounds(10, 314, 760, 388)
$gbParams.BackColor = [System.Drawing.Color]::White
$form.Controls.Add($gbParams)

function New-ParamLabel([string]$t, [int]$x, [int]$y, [int]$w = 132, [string]$tipText) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $t
    $l.SetBounds($x, $y, $w, 20)
    $gbParams.Controls.Add($l)
    if ($tipText) { $tip.SetToolTip($l, $tipText) }
    return $l
}

$cbVoice = New-Object System.Windows.Forms.ComboBox
$cbVoice.DropDownStyle = 'DropDownList'
$cbVoice.SetBounds(158, 24, 288, 24)
$gbParams.Controls.Add($cbVoice)
New-ParamLabel '语音' 16 28 132 '朗读使用的系统语音（SAPI）。中文建议选 Microsoft Huihui。' | Out-Null
$tip.SetToolTip($cbVoice, '朗读使用的系统语音（SAPI）。中文建议选 Microsoft Huihui。')
$btnTest = New-Object System.Windows.Forms.Button
$btnTest.Text = '试听'
$btnTest.SetBounds(460, 23, 70, 26)
$gbParams.Controls.Add($btnTest)
$tip.SetToolTip($btnTest, '用当前选择的语音与语速朗读一句，测试发音。')
$lblVoiceHint = New-Object System.Windows.Forms.Label
$lblVoiceHint.Text = '（中文建议选 Huihui）'
$lblVoiceHint.SetBounds(540, 28, 200, 20)
$gbParams.Controls.Add($lblVoiceHint)
$tip.SetToolTip($lblVoiceHint, '中文朗读建议使用 Microsoft Huihui Desktop；点"试听"可先听效果。')

function New-Num([string]$cap, [int]$y, [int]$min, [int]$max, [int]$def, [string]$tipText) {
    New-ParamLabel $cap 16 $y 132 $tipText | Out-Null
    $n = New-Object System.Windows.Forms.NumericUpDown
    $n.SetBounds(158, $y - 3, 90, 24)
    $n.Minimum = $min; $n.Maximum = $max; $n.Value = $def
    $gbParams.Controls.Add($n)
    if ($tipText) { $tip.SetToolTip($n, $tipText) }
    return $n
}
$numRate     = New-Num '语速 Rate'        62  (-10) 10  0   '语速 -10..10。数值越小，每个字读得越慢、越长、越清晰。'
$numBreak    = New-Num '字间停顿 BreakMs' 96    0  1000 30  '逐字朗读时，每个字之间插入的静音毫秒数。'
$numIdle     = New-Num '触发间隔 IdleMs' 130    0  2000 60  '上屏后等待这么久没有新输入才开读。越小越灵敏，越大越能合并成整句。'
$numMaxWait  = New-Num '最长等待 MaxWait' 164    0  3000 200 '从上屏到开读最多等这么久（毫秒），超过就立即朗读。'
$numThresh   = New-Num '静音阈值'         198    0  3000 180 '裁剪首尾静音时的判定阈值（16 位采样）。一般不用改。'
$numPad      = New-Num '边距 PadMs'       232    0   300 15  '裁剪静音时在首尾保留的边距（毫秒），避免把字头字尾切掉。'
$numVolume   = New-Num '音量 Volume'      266    0   100 100 '朗读音量 0..100（只影响本程序朗读，不动系统音量）。'

$chkCharByChar = New-Object System.Windows.Forms.CheckBox
$chkCharByChar.Text = '逐字朗读（字间停顿）'
$chkCharByChar.SetBounds(16, 300, 220, 22)
$chkCharByChar.Checked = $true
$gbParams.Controls.Add($chkCharByChar)
$tip.SetToolTip($chkCharByChar, '勾选=逐字读出（字与字之间加停顿，便于核对）；取消=整句连续朗读。')

$chkAscii = New-Object System.Windows.Forms.CheckBox
$chkAscii.Text = '朗读英文与数字 (IncludeAscii)'
$chkAscii.SetBounds(16, 326, 300, 22)
$chkAscii.Checked = $true
$gbParams.Controls.Add($chkAscii)
$tip.SetToolTip($chkAscii, '勾选后英文与数字也会朗读。注意：只有经输入法上屏的内容才会被读到，直接输入(未上屏)的内容不会。')

$chkAuto = New-Object System.Windows.Forms.CheckBox
$chkAuto.Text = '开机自动启动（托盘）'
$chkAuto.SetBounds(340, 300, 200, 22)
$gbParams.Controls.Add($chkAuto)
$tip.SetToolTip($chkAuto, '开机时自动以托盘方式启动本控制面板（后台朗读与快捷键随之可用）。')

$chkWatch = New-Object System.Windows.Forms.CheckBox
$chkWatch.Text = '看门狗：自动重启后台朗读'
$chkWatch.SetBounds(340, 326, 250, 22)
$chkWatch.Checked = $true
$gbParams.Controls.Add($chkWatch)
$tip.SetToolTip($chkWatch, '后台朗读若意外退出，且未静音，则自动重新启动（5 分钟内最多 5 次）。')

$btnSave = New-Object System.Windows.Forms.Button
$btnSave.Text = '保存参数'
$btnSave.SetBounds(470, 348, 120, 30)
$gbParams.Controls.Add($btnSave)
$tip.SetToolTip($btnSave, '把当前参数保存到 %USERPROFILE%\Rime_tts_config.json；后台朗读会热加载，约 1 秒内自动生效。')
$btnApply = New-Object System.Windows.Forms.Button
$btnApply.Text = '保存并重启朗读'
$btnApply.SetBounds(600, 348, 140, 30)
$gbParams.Controls.Add($btnApply)
$tip.SetToolTip($btnApply, '保存参数并立即重启后台朗读，让改动马上生效。')

$lblUnsaved = New-Object System.Windows.Forms.Label
$lblUnsaved.Text = '● 有未保存的修改'
$lblUnsaved.ForeColor = [System.Drawing.Color]::FromArgb(200, 120, 0)
$lblUnsaved.SetBounds(16, 354, 300, 20)
$lblUnsaved.Visible = $false
$gbParams.Controls.Add($lblUnsaved)
$tip.SetToolTip($lblUnsaved, '参数已改动但尚未保存。点"保存参数"或"保存并重启朗读"写入配置文件。')

# ---- program filter group
$gbFilter = New-Object System.Windows.Forms.GroupBox
$gbFilter.Text = '程序筛选（在哪些程序里朗读）'
$gbFilter.SetBounds(10, 710, 760, 92)
$gbFilter.BackColor = [System.Drawing.Color]::White
$form.Controls.Add($gbFilter)

$lblFilterMode = New-Object System.Windows.Forms.Label
$lblFilterMode.Text = '模式:'
$lblFilterMode.SetBounds(16, 28, 44, 20)
$gbFilter.Controls.Add($lblFilterMode)
$cbFilterMode = New-Object System.Windows.Forms.ComboBox
$cbFilterMode.DropDownStyle = 'DropDownList'
$cbFilterMode.SetBounds(60, 25, 180, 24)
[void]$cbFilterMode.Items.Add('默认：全部程序都读')
[void]$cbFilterMode.Items.Add('仅在这些程序中读')
[void]$cbFilterMode.Items.Add('除这些程序外都读')
$cbFilterMode.SelectedIndex = 0
$gbFilter.Controls.Add($cbFilterMode)
$tip.SetToolTip($lblFilterMode, '选择筛选方式：全部朗读 / 白名单（只读指定程序）/ 黑名单（指定程序不读）。')
$tip.SetToolTip($cbFilterMode, '选择筛选方式：全部朗读 / 白名单（只读指定程序）/ 黑名单（指定程序不读）。')

$lblFilterList = New-Object System.Windows.Forms.Label
$lblFilterList.Text = '程序(逗号分隔):'
$lblFilterList.SetBounds(252, 28, 110, 20)
$gbFilter.Controls.Add($lblFilterList)
$txtFilterList = New-Object System.Windows.Forms.TextBox
$txtFilterList.SetBounds(366, 25, 268, 24)
$gbFilter.Controls.Add($txtFilterList)
$tip.SetToolTip($lblFilterList, '进程名，例如 WINWORD.exe, chrome.exe；也可点右侧按钮从运行中的程序选择。')
$tip.SetToolTip($txtFilterList, '进程名，例如 WINWORD.exe, chrome.exe；也可点右侧按钮从运行中的程序选择。')

$btnPickProc = New-Object System.Windows.Forms.Button
$btnPickProc.Text = '从运行中选择…'
$btnPickProc.SetBounds(644, 24, 104, 28)
$gbFilter.Controls.Add($btnPickProc)
$tip.SetToolTip($btnPickProc, '列出当前运行中的程序，勾选后自动填入上面的列表。')

$lblFilterHint = New-Object System.Windows.Forms.Label
$lblFilterHint.Text = '说明：仅对"经输入法上屏"的内容生效；未上屏的直接输入不会被读到。'
$lblFilterHint.SetBounds(16, 58, 720, 20)
$gbFilter.Controls.Add($lblFilterHint)
$tip.SetToolTip($lblFilterHint, '朗读只监听 Rime 的上屏(commit)事件，因此未经过候选框、直接输入的内容不会被朗读。')

# ---- hotkey group
$gbHot = New-Object System.Windows.Forms.GroupBox
$gbHot.Text = '全局快捷键'
$gbHot.SetBounds(10, 810, 760, 72)
$gbHot.BackColor = [System.Drawing.Color]::White
$form.Controls.Add($gbHot)

$lblHot = New-Object System.Windows.Forms.Label
$lblHot.Text = '切换快捷键:'
$lblHot.SetBounds(16, 28, 92, 20)
$gbHot.Controls.Add($lblHot)
$tip.SetToolTip($lblHot, '在任意程序中都有效的组合键，用来一键切换"启用/禁用回读"。支持 Ctrl/Alt/Shift/Win + A–Z、0–9、F1–F12、Space。')
$txtHot = New-Object System.Windows.Forms.TextBox
$txtHot.SetBounds(112, 25, 130, 24)
$txtHot.Text = 'Ctrl+Alt+R'
$txtHot.ReadOnly = $true
$txtHot.BackColor = [System.Drawing.Color]::White
$gbHot.Controls.Add($txtHot)
$tip.SetToolTip($txtHot, '当前快捷键（只读）。点右侧"设置…"按键捕获新的组合键。')

$btnHotSet = New-Object System.Windows.Forms.Button
$btnHotSet.Text = '设置…'
$btnHotSet.SetBounds(248, 24, 70, 28)
$gbHot.Controls.Add($btnHotSet)
$tip.SetToolTip($btnHotSet, '弹出对话框，直接按下组合键即可设置，并实时报告是否被占用。')

$chkHot = New-Object System.Windows.Forms.CheckBox
$chkHot.Text = '启用全局快捷键'
$chkHot.SetBounds(326, 27, 130, 22)
$chkHot.Checked = $true
$gbHot.Controls.Add($chkHot)
$tip.SetToolTip($chkHot, '取消勾选则注销该全局快捷键，不再响应按键。')
$btnHotApply = New-Object System.Windows.Forms.Button
$btnHotApply.Text = '应用'
$btnHotApply.SetBounds(462, 24, 74, 28)
$gbHot.Controls.Add($btnHotApply)
$tip.SetToolTip($btnHotApply, '按当前显示的组合键重新注册，并把设置保存到配置文件。')
$lblHotStatus = New-Object System.Windows.Forms.Label
$lblHotStatus.SetBounds(544, 29, 204, 20)
$gbHot.Controls.Add($lblHotStatus)
$tip.SetToolTip($lblHotStatus, '显示快捷键的注册结果（成功 / 格式无效 / 被其他程序占用）。')

# ---- log group
$gbLog = New-Object System.Windows.Forms.GroupBox
$gbLog.Text = '日志'
$gbLog.SetBounds(10, 890, 760, 208)
$gbLog.BackColor = [System.Drawing.Color]::White
$form.Controls.Add($gbLog)
$tip.SetToolTip($gbLog, '记录每次操作与结果。后台朗读的详细日志在 %USERPROFILE%\Rime_tts_watcher.log（超过 1MB 自动轮转）。')
$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Multiline = $true
$txtLog.ScrollBars = 'Vertical'
$txtLog.ReadOnly = $true
$txtLog.SetBounds(12, 22, 736, 176)
$txtLog.Font = New-Object System.Drawing.Font('Consolas', 9)
$gbLog.Controls.Add($txtLog)
$tip.SetToolTip($txtLog, '操作日志（只读）。')

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

    # the enable/disable button reflects the current state (click = the opposite action)
    if ($btnToggle) {
        if ($st.Muted) {
            $btnToggle.Text = '启用'
            Set-BtnStyle $btnToggle -Primary
            $tip.SetToolTip($btnToggle, '当前已禁用：点击启用回读（取消静音并启动后台朗读）。')
        } else {
            $btnToggle.Text = '禁用'
            Set-BtnStyle $btnToggle
            $tip.SetToolTip($btnToggle, '当前已启用：点击禁用回读（静音并停止后台朗读）。')
        }
    }

    # mirror each row's colour onto its status dot
    foreach ($l in @($lblRime, $lblUser, $lblFeature, $lblRun)) {
        if ($l.Tag) { $l.Tag.ForeColor = $l.ForeColor }
    }
}

function Get-FilterMode {
    switch ($cbFilterMode.SelectedIndex) { 1 { 'only' } 2 { 'except' } default { 'all' } }
}
function Set-FilterMode([string]$m) {
    switch ($m) { 'only' { $cbFilterMode.SelectedIndex = 1 } 'except' { $cbFilterMode.SelectedIndex = 2 } default { $cbFilterMode.SelectedIndex = 0 } }
}
function Get-FilterList {
    @($txtFilterList.Text -split '[,;，；\s]+' | Where-Object { $_.Trim() } | ForEach-Object { $_.Trim() })
}

function Collect-Config {
    [PSCustomObject]@{
        Voice         = [string]$cbVoice.SelectedItem
        Rate          = [int]$numRate.Value
        BreakMs       = [int]$numBreak.Value
        IdleMs        = [int]$numIdle.Value
        MaxWaitMs     = [int]$numMaxWait.Value
        Threshold     = [int]$numThresh.Value
        PadMs         = [int]$numPad.Value
        Volume        = [int]$numVolume.Value
        CharByChar    = [bool]$chkCharByChar.Checked
        IncludeAscii  = [bool]$chkAscii.Checked
        AppFilterMode = (Get-FilterMode)
        AppFilterList = @(Get-FilterList)
        HotKey        = [string]$txtHot.Text
        HotKeyEnabled = [bool]$chkHot.Checked
        AutoStart     = [bool]$chkAuto.Checked
        Watchdog      = [bool]$chkWatch.Checked
    }
}

function Load-ConfigIntoUi {
    $cfg = Read-Config
    $voices = Get-Voices
    $cbVoice.Items.Clear()
    foreach ($v in $voices) { [void]$cbVoice.Items.Add($v) }

    if ($cfg) {
        if ($cfg.Voice -and $cbVoice.Items.Contains($cfg.Voice)) { $cbVoice.SelectedItem = $cfg.Voice }
        if ($null -ne $cfg.Rate)       { $numRate.Value    = [int]$cfg.Rate }
        if ($null -ne $cfg.BreakMs)    { $numBreak.Value   = [int]$cfg.BreakMs }
        if ($null -ne $cfg.IdleMs)     { $numIdle.Value    = [int]$cfg.IdleMs }
        if ($null -ne $cfg.MaxWaitMs)  { $numMaxWait.Value = [int]$cfg.MaxWaitMs }
        if ($null -ne $cfg.Threshold)  { $numThresh.Value  = [int]$cfg.Threshold }
        if ($null -ne $cfg.PadMs)      { $numPad.Value     = [int]$cfg.PadMs }
        if ($null -ne $cfg.Volume)     { $numVolume.Value  = [int]$cfg.Volume }
        if ($null -ne $cfg.CharByChar) { $chkCharByChar.Checked = [bool]$cfg.CharByChar }
        if ($null -ne $cfg.IncludeAscii) { $chkAscii.Checked = [bool]$cfg.IncludeAscii }
        if ($cfg.AppFilterMode)        { Set-FilterMode ([string]$cfg.AppFilterMode) }
        if ($cfg.AppFilterList)        { $txtFilterList.Text = (@($cfg.AppFilterList) -join ', ') }
        if ($cfg.HotKey)               { $txtHot.Text = [string]$cfg.HotKey }
        if ($null -ne $cfg.HotKeyEnabled) { $chkHot.Checked = [bool]$cfg.HotKeyEnabled }
        if ($null -ne $cfg.AutoStart)  { $chkAuto.Checked = [bool]$cfg.AutoStart }
        if ($null -ne $cfg.Watchdog)   { $chkWatch.Checked = [bool]$cfg.Watchdog }
    }
    if (-not $cbVoice.SelectedItem -and $cbVoice.Items.Count -gt 0) {
        $pref = $voices | Where-Object { $_ -match 'Huihui|Chinese|zh' } | Select-Object -First 1
        $cbVoice.SelectedItem = if ($pref) { $pref } else { $cbVoice.Items[0] }
    }
    $chkAuto.Checked = Get-Autostart
}

# ---------------------------------------------------------------- change feedback
$script:LastVals    = @{}
$script:Unsaved     = $false
$script:LastBalloon = [DateTime]::MinValue
$script:SavedConfig = $null

function Set-Unsaved([bool]$on) {
    $script:Unsaved = $on
    if ($lblUnsaved) { $lblUnsaved.Visible = $on }
}
function Balloon-Change([string]$text) {
    if ((([DateTime]::UtcNow) - $script:LastBalloon).TotalSeconds -lt 2) { return }
    $script:LastBalloon = [DateTime]::UtcNow
    try { $notify.ShowBalloonTip(1500, 'Rime 回读 · 参数已修改', $text, [System.Windows.Forms.ToolTipIcon]::Info) } catch { }
}
function Track-Change([string]$key, [string]$disp, $value) {
    $old = $script:LastVals[$key]
    $script:LastVals[$key] = $value
    if ($null -eq $old) { return }
    $ov = if ($old -is [bool]) { if ($old) { '开' } else { '关' } } else { "$old" }
    $nv = if ($value -is [bool]) { if ($value) { '开' } else { '关' } } else { "$value" }
    if ($ov -eq $nv) { return }
    Log-Line ("修改 $disp : $ov → $nv  (未保存)")
    Set-Unsaved $true
    Balloon-Change ("$disp : $ov → $nv（未保存）")
}
function Snapshot-Controls {
    $script:LastVals = @{
        Voice         = [string]$cbVoice.SelectedItem
        Rate          = [int]$numRate.Value
        BreakMs       = [int]$numBreak.Value
        IdleMs        = [int]$numIdle.Value
        MaxWaitMs     = [int]$numMaxWait.Value
        Threshold     = [int]$numThresh.Value
        PadMs         = [int]$numPad.Value
        Volume        = [int]$numVolume.Value
        CharByChar    = [bool]$chkCharByChar.Checked
        IncludeAscii  = [bool]$chkAscii.Checked
        AutoStart     = [bool]$chkAuto.Checked
        Watchdog      = [bool]$chkWatch.Checked
        HotKeyEnabled = [bool]$chkHot.Checked
        AppFilterMode = (Get-FilterMode)
        AppFilterList = (@(Get-FilterList) -join ', ')
    }
}
$script:ParamNames = @{
    Voice = '语音'; Rate = '语速'; BreakMs = '字间停顿'; IdleMs = '触发间隔'; MaxWaitMs = '最长等待'
    Threshold = '静音阈值'; PadMs = '边距'; Volume = '音量'; CharByChar = '逐字朗读'; IncludeAscii = '朗读英文数字'
    AppFilterMode = '筛选模式'; AppFilterList = '筛选列表'; HotKey = '快捷键'; HotKeyEnabled = '启用快捷键'
    AutoStart = '开机自启'; Watchdog = '看门狗'
}
function Get-ConfigDiff($old, $new) {
    $diffs = New-Object System.Collections.Generic.List[string]
    if (-not $old) { return $diffs }
    foreach ($p in $new.PSObject.Properties) {
        $n = $script:ParamNames[$p.Name]; if (-not $n) { $n = $p.Name }
        $ov = $old.($p.Name); $nv = $p.Value
        if ($p.Name -eq 'AppFilterList') {
            $os = (@($ov) -join ', '); $ns = (@($nv) -join ', ')
            if ($os -ne $ns) { $diffs.Add("$n : [$os] → [$ns]") }
        } elseif ($p.Name -in @('CharByChar', 'IncludeAscii', 'AutoStart', 'Watchdog', 'HotKeyEnabled')) {
            $ob = if ($ov) { '开' } else { '关' }; $nb = if ($nv) { '开' } else { '关' }
            if ($ob -ne $nb) { $diffs.Add("$n : $ob → $nb") }
        } else {
            if ("$ov" -ne "$nv") { $diffs.Add("$n : $ov → $nv") }
        }
    }
    return $diffs
}
function Save-Params([switch]$Restart) {
    $new = Collect-Config
    $diff = Get-ConfigDiff $script:SavedConfig $new
    Write-Config $new
    if (-not (Set-Autostart ([bool]$chkAuto.Checked))) { Log-Line '设置开机自启失败（可能无权限）' }
    if ($diff.Count -eq 0) { Log-Line '参数无变化' }
    else { foreach ($d in $diff) { Log-Line ('已保存  ' + $d) } }
    $script:SavedConfig = $new
    Snapshot-Controls
    Set-Unsaved $false
    if ($Restart) {
        Stop-Watcher; Start-Sleep -Milliseconds 400
        if (Start-Watcher) { Log-Line '后台朗读已重启，参数已生效' } else { Log-Line '后台朗读未启动（可能未部署）' }
    }
    $msg = if ($diff.Count -eq 0) { '参数无变化' }
           else { "已保存 $($diff.Count) 项修改" + $(if ($Restart) { '，朗读已重启' } else { '，已自动生效' }) }
    try { $notify.ShowBalloonTip(2500, 'Rime 回读 · 参数已保存', $msg, [System.Windows.Forms.ToolTipIcon]::Info) } catch { }
    Refresh-View
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

try { $form.Icon = $script:IcoApp } catch { }

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
        try { $notify.ShowBalloonTip(1500, 'Rime 回读', '已最小化到通知栏，单击图标可恢复。', [System.Windows.Forms.ToolTipIcon]::Info) } catch { }
    }
}

# ---------------------------------------------------------------- hotkey / IPC
$script:HKId = 0xB001

function Convert-HotKey([string]$spec) {
    if (-not $spec) { return $null }
    $mods = 0; $vk = -1
    foreach ($p in ($spec -split '\s*\+\s*')) {
        $u = $p.Trim().ToUpperInvariant()
        switch ($u) {
            'CTRL'    { $mods = $mods -bor 0x2 }
            'CONTROL' { $mods = $mods -bor 0x2 }
            'ALT'     { $mods = $mods -bor 0x1 }
            'SHIFT'   { $mods = $mods -bor 0x4 }
            'WIN'     { $mods = $mods -bor 0x8 }
            default {
                if     ($u -match '^F([1-9]|1[0-2])$') { $vk = 0x70 + [int]$Matches[1] - 1 }
                elseif ($u -match '^[A-Z0-9]$')        { $vk = [int][char]$u }
                elseif ($u -eq 'SPACE')                { $vk = 0x20 }
                else { return $null }
            }
        }
    }
    if ($vk -lt 0 -or $mods -eq 0) { return $null }
    return @{ Mods = ($mods -bor 0x4000); Vk = $vk }
}
function Apply-HotKey([string]$spec, [bool]$enabled) {
    try { $script:HkWnd.Unregister($script:HKId) } catch { }
    if (-not $enabled) { return @{ Ok = $true; Msg = '已关闭全局快捷键' } }
    $r = Convert-HotKey $spec
    if (-not $r) { return @{ Ok = $false; Msg = "格式无效: $spec" } }
    if ($script:HkWnd.Register($script:HKId, $r.Mods, $r.Vk)) { return @{ Ok = $true; Msg = "已注册: $spec" } }
    return @{ Ok = $false; Msg = "注册失败（可能被占用）: $spec" }
}
function Test-HotKeyFree([string]$spec) {
    if (-not $spec) { return @{ Ok = $false; Msg = '未设置组合键' } }
    $r = Convert-HotKey $spec
    if (-not $r) { return @{ Ok = $false; Msg = "格式无效: $spec" } }
    $testId = 0xB0FE
    $ok = $false
    try { $ok = $script:HkWnd.Register($testId, $r.Mods, $r.Vk) } catch { $ok = $false }
    if ($ok) {
        try { $script:HkWnd.Unregister($testId) } catch { }
        return @{ Ok = $true; Msg = '可用' }
    }
    return @{ Ok = $false; Msg = '该组合键已被其他程序占用（或为系统保留）' }
}

function Show-HotKeyDialog([string]$current) {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = '设置全局快捷键'
    $dlg.ClientSize = New-Object System.Drawing.Size(420, 232)
    $dlg.StartPosition = 'CenterParent'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false
    $dlg.KeyPreview = $true
    $dlg.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
    $dlg.BackColor = [System.Drawing.Color]::FromArgb(245, 246, 249)

    $hint = New-Object System.Windows.Forms.Label
    $hint.Text = '直接按下想要的组合键（需含 Ctrl / Alt / Shift / Win 之一）'
    $hint.SetBounds(16, 12, 390, 20)
    $dlg.Controls.Add($hint)

    $box = New-Object System.Windows.Forms.Label
    $box.Text = $(if ($current) { $current } else { '(未设置)' })
    $box.TextAlign = 'MiddleCenter'
    $box.SetBounds(16, 40, 388, 58)
    $box.BorderStyle = 'FixedSingle'
    $box.BackColor = [System.Drawing.Color]::White
    $box.Font = New-Object System.Drawing.Font('Consolas', 16, [System.Drawing.FontStyle]::Bold)
    $dlg.Controls.Add($box)

    $status = New-Object System.Windows.Forms.Label
    $status.SetBounds(16, 106, 388, 20)
    $dlg.Controls.Add($status)

    $tip2 = New-Object System.Windows.Forms.Label
    $tip2.Text = '支持的按键：A–Z、0–9、F1–F12、Space；Esc 取消，Backspace/Delete 清除'
    $tip2.ForeColor = [System.Drawing.Color]::FromArgb(120, 125, 132)
    $tip2.SetBounds(16, 128, 388, 20)
    $dlg.Controls.Add($tip2)

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = '确定'; $ok.SetBounds(236, 184, 80, 30); $ok.DialogResult = 'OK'
    Set-BtnStyle $ok -Primary
    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = '取消'; $cancel.SetBounds(322, 184, 80, 30); $cancel.DialogResult = 'Cancel'
    Set-BtnStyle $cancel
    $dlg.Controls.Add($ok); $dlg.Controls.Add($cancel)
    $dlg.AcceptButton = $null
    $dlg.CancelButton = $cancel

    $script:captured = if ($current) { $current } else { '' }

    $dlg.Add_KeyDown({
        param($sender, $e)
        $key = $e.KeyCode
        if ($key -eq [System.Windows.Forms.Keys]::Escape) { $dlg.DialogResult = 'Cancel'; return }
        if ($key -eq [System.Windows.Forms.Keys]::Back -or $key -eq [System.Windows.Forms.Keys]::Delete) {
            $script:captured = ''
            $box.Text = '(未设置)'
            $status.Text = ''
            return
        }
        if ($key -eq [System.Windows.Forms.Keys]::ControlKey -or $key -eq [System.Windows.Forms.Keys]::ShiftKey -or
            $key -eq [System.Windows.Forms.Keys]::Menu -or $key -eq [System.Windows.Forms.Keys]::LWin -or
            $key -eq [System.Windows.Forms.Keys]::RWin) { return }

        $parts = @()
        if ($e.Control) { $parts += 'Ctrl' }
        if ($e.Alt) { $parts += 'Alt' }
        if ($e.Shift) { $parts += 'Shift' }
        if ([RimeHK.Keys2]::WinDown()) { $parts += 'Win' }

        $k = [string]$key
        $name = $null
        if ($k -match '^[A-Z]$') { $name = $k }
        elseif ($k -match '^D[0-9]$') { $name = $k.Substring(1) }
        elseif ($k -match '^NumPad[0-9]$') { $name = $k.Substring(6) }
        elseif ($k -match '^F([1-9]|1[0-2])$') { $name = $k }
        elseif ($key -eq [System.Windows.Forms.Keys]::Space) { $name = 'Space' }

        if (-not $name) {
            $status.Text = '不支持的按键：' + $k
            $status.ForeColor = [System.Drawing.Color]::FromArgb(170, 0, 0)
            return
        }
        if ($parts.Count -eq 0) {
            $status.Text = '至少要有一个修饰键（Ctrl / Alt / Shift / Win）'
            $status.ForeColor = [System.Drawing.Color]::FromArgb(170, 0, 0)
            return
        }
        $combo = ($parts -join '+') + '+' + $name
        $script:captured = $combo
        $box.Text = $combo
        $chk = Test-HotKeyFree $combo
        $status.Text = $chk.Msg
        $status.ForeColor = if ($chk.Ok) { [System.Drawing.Color]::FromArgb(0, 110, 0) } else { [System.Drawing.Color]::FromArgb(170, 0, 0) }
    })

    $res = $dlg.ShowDialog($form)
    $dlg.Dispose()
    if ($res -eq 'OK') { return $script:captured }
    return $null
}

function Show-AboutDialog {
    $ri = Get-RimeInstall
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = '关于 Rime TTS Readback'
    $dlg.ClientSize = New-Object System.Drawing.Size(460, 306)
    $dlg.StartPosition = 'CenterParent'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false
    $dlg.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
    $dlg.BackColor = [System.Drawing.Color]::FromArgb(245, 246, 249)

    $t = New-Object System.Windows.Forms.Label
    $t.Text = 'Rime TTS Readback'
    $t.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 13, [System.Drawing.FontStyle]::Bold)
    $t.SetBounds(16, 12, 300, 26)
    $dlg.Controls.Add($t)

    $v = New-Object System.Windows.Forms.Label
    $v.Text = "版本 v$script:AppVersion"
    $v.ForeColor = [System.Drawing.Color]::FromArgb(110, 116, 124)
    $v.SetBounds(18, 38, 300, 20)
    $dlg.Controls.Add($v)

    $riLine = if ($ri) { "$($ri.Dir) (v$($ri.Version))" } else { '未检测到' }
    $hkLine = if ($chkHot.Checked) { $txtHot.Text } else { '(未启用)' }
    $asLine = if (Get-Autostart) { '是' } else { '否' }
    $info = New-Object System.Windows.Forms.Label
    $infoLines = @(
        "Rime 安装: $riLine",
        "用户目录: $script:RimeUserDir",
        "脚本目录: $PSScriptRoot",
        "配置文件: $script:ConfigFile",
        "全局快捷键: $hkLine",
        "开机自启: $asLine"
    )
    $info.Text = ($infoLines -join [Environment]::NewLine)
    $info.SetBounds(18, 66, 424, 132)
    $info.UseCompatibleTextRendering = $true   # keep the newlines (GDI would collapse them)
    $dlg.Controls.Add($info)

    $lblRepo = New-Object System.Windows.Forms.Label
    $lblRepo.Text = '仓库:'
    $lblRepo.SetBounds(18, 206, 44, 20)
    $dlg.Controls.Add($lblRepo)

    $link = New-Object System.Windows.Forms.LinkLabel
    $link.Text = $script:RepoUrl
    $link.SetBounds(62, 206, 384, 20)
    $link.LinkColor = [System.Drawing.Color]::FromArgb(46, 120, 190)
    $link.Add_LinkClicked({ try { Start-Process $script:RepoUrl } catch { } })
    $dlg.Controls.Add($link)
    $tip.SetToolTip($link, '点击用默认浏览器打开仓库；也可点"复制链接"。')

    $btnCopy = New-Object System.Windows.Forms.Button
    $btnCopy.Text = '复制链接'
    $btnCopy.SetBounds(236, 246, 96, 30)
    Set-BtnStyle $btnCopy
    $btnCopy.Add_Click({
        try {
            [System.Windows.Forms.Clipboard]::SetText($script:RepoUrl)
            $lblRepo.Text = '仓库:(已复制)'
        } catch { }
    })
    $dlg.Controls.Add($btnCopy)
    $tip.SetToolTip($btnCopy, '把仓库地址复制到剪贴板。')

    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text = '确定'
    $btnOk.SetBounds(344, 246, 96, 30)
    Set-BtnStyle $btnOk -Primary
    $btnOk.DialogResult = 'OK'
    $dlg.Controls.Add($btnOk)
    $dlg.AcceptButton = $btnOk
    $dlg.CancelButton = $btnOk

    [void]$dlg.ShowDialog($form)
    $dlg.Dispose()
}

function Toggle-Readback {
    $st = Get-FeatureState
    if ($st.Muted) {
        Run-Action '启用回读（快捷键）' { Enable-Readback }
        try { $notify.ShowBalloonTip(800, 'Rime 回读', '已启用', [System.Windows.Forms.ToolTipIcon]::Info) } catch { }
    } else {
        Run-Action '禁用回读（快捷键）' { Disable-Readback }
        try { $notify.ShowBalloonTip(800, 'Rime 回读', '已禁用', [System.Windows.Forms.ToolTipIcon]::Info) } catch { }
    }
}

$script:HkWnd.Add_HotKeyPressed({ param($id) if ($id -eq $script:HKId) { Toggle-Readback } })

# ---------------------------------------------------------------- watchdog
$script:WatchCount = 0
$script:WatchWindow = [DateTime]::UtcNow
function Invoke-Watchdog {
    if (-not $chkWatch.Checked) { return }
    $st = Get-FeatureState
    if (-not $st.Installed -or $st.Muted -or $st.Watcher) { return }
    if ((([DateTime]::UtcNow) - $script:WatchWindow).TotalMinutes -gt 5) { $script:WatchCount = 0; $script:WatchWindow = [DateTime]::UtcNow }
    if ($script:WatchCount -ge 5) { return }
    $script:WatchCount++
    Log-Line '看门狗：检测到后台朗读已停止，正在自动重启…'
    Start-Watcher | Out-Null
    Update-Tray
}

$notify.Add_MouseClick({ param($sender, $evt) if ($evt.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Show-Main } })
$notify.Add_MouseDoubleClick({ Show-Main })
$miShow.Add_Click({ Show-Main })
$miEnable.Add_Click({ Run-Action '启用回读（通知栏）' { Enable-Readback } })
$miDisable.Add_Click({ Run-Action '禁用回读（通知栏）' { Disable-Readback } })
$miExit.Add_Click({
    $script:ReallyExit = $true
    $timer.Stop()
    try { $script:HkWnd.Unregister($script:HKId); $script:HkWnd.Dispose() } catch { }
    $notify.Visible = $false
    $notify.Dispose()
    $form.Close()
})

$form.Add_Resize({
    if ($form.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) { Hide-ToTray }
})
$form.Add_FormClosing({
    param($sender, $evt)
    if (-not $script:ReallyExit) { $evt.Cancel = $true; Hide-ToTray }
})

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 2000
$timer.Add_Tick({ Update-Tray; Invoke-Watchdog })
$timer.Start()

# style the remaining buttons
Set-BtnStyle $btnRefresh
Set-BtnStyle $btnTest
Set-BtnStyle $btnSave
Set-BtnStyle $btnApply -Primary
Set-BtnStyle $btnHotApply
Set-BtnStyle $btnPickProc

# ---- per-change feedback (log + throttled balloon + unsaved marker)
$numRate.Add_ValueChanged({ Track-Change 'Rate' '语速' ([int]$numRate.Value) })
$numBreak.Add_ValueChanged({ Track-Change 'BreakMs' '字间停顿' ([int]$numBreak.Value) })
$numIdle.Add_ValueChanged({ Track-Change 'IdleMs' '触发间隔' ([int]$numIdle.Value) })
$numMaxWait.Add_ValueChanged({ Track-Change 'MaxWaitMs' '最长等待' ([int]$numMaxWait.Value) })
$numThresh.Add_ValueChanged({ Track-Change 'Threshold' '静音阈值' ([int]$numThresh.Value) })
$numPad.Add_ValueChanged({ Track-Change 'PadMs' '边距' ([int]$numPad.Value) })
$numVolume.Add_ValueChanged({ Track-Change 'Volume' '音量' ([int]$numVolume.Value) })
$cbVoice.Add_SelectedIndexChanged({ Track-Change 'Voice' '语音' ([string]$cbVoice.SelectedItem) })
$chkCharByChar.Add_CheckedChanged({ Track-Change 'CharByChar' '逐字朗读' ([bool]$chkCharByChar.Checked) })
$chkAscii.Add_CheckedChanged({ Track-Change 'IncludeAscii' '朗读英文数字' ([bool]$chkAscii.Checked) })
$chkAuto.Add_CheckedChanged({ Track-Change 'AutoStart' '开机自启' ([bool]$chkAuto.Checked) })
$chkWatch.Add_CheckedChanged({ Track-Change 'Watchdog' '看门狗' ([bool]$chkWatch.Checked) })
$chkHot.Add_CheckedChanged({ Track-Change 'HotKeyEnabled' '启用快捷键' ([bool]$chkHot.Checked) })
$cbFilterMode.Add_SelectedIndexChanged({ Track-Change 'AppFilterMode' '筛选模式' (Get-FilterMode) })
$txtFilterList.Add_Leave({ Track-Change 'AppFilterList' '筛选列表' (@(Get-FilterList) -join ', ') })

# ---------------------------------------------------------------- wiring
$btnRefresh.Add_Click({ Refresh-View; Log-Line '已刷新检测' })
$btnInstall.Add_Click({ Run-Action '部署到 Rime' { Install-Readback } })
$btnHelp.Add_Click({
    Run-Action '一键安装' {
        $out = New-Object System.Collections.Generic.List[string]
        foreach ($m in (Install-Readback)) { $out.Add($m) }
        foreach ($m in (Enable-Readback))  { $out.Add($m) }
        if ($chkAuto.Checked) { if (Set-Autostart $true) { $out.Add('已设置开机自启（托盘）') } }
        $out.Add('一键安装完成')
        return $out
    }
})
$btnRemove.Add_Click({
    if ([System.Windows.Forms.MessageBox]::Show(
            "将移除 Rime 中的回读集成（补丁、rime.lua）并重新部署。继续？",
            '删除回读功能', 'YesNo', 'Warning') -eq 'Yes') {
        Run-Action '删除回读功能' { Remove-Readback }
    }
})
$btnRedeploy.Add_Click({ Run-Action '仅重新部署' { , (Invoke-Redeploy) } })
$btnToggle.Add_Click({
    $st = Get-FeatureState
    if ($st.Muted) { Run-Action '启用回读' { Enable-Readback } }
    else           { Run-Action '禁用回读' { Disable-Readback } }
})

$btnAbout.Add_Click({ try { Show-AboutDialog } catch { Log-Line "关于窗口失败: $($_.Exception.Message)" } })

$btnSave.Add_Click({
    try { Save-Params } catch { Log-Line "保存失败: $($_.Exception.Message)" }
})
$btnApply.Add_Click({
    try { Save-Params -Restart } catch { Log-Line "应用失败: $($_.Exception.Message)" }
})
$btnHotApply.Add_Click({
    try {
        $r = Apply-HotKey $txtHot.Text ([bool]$chkHot.Checked)
        $lblHotStatus.Text = $r.Msg
        $lblHotStatus.ForeColor = if ($r.Ok) { [System.Drawing.Color]::FromArgb(0, 110, 0) } else { [System.Drawing.Color]::FromArgb(170, 0, 0) }
        Log-Line "全局快捷键: $($r.Msg)"
        Save-Params
    } catch { Log-Line "快捷键设置失败: $($_.Exception.Message)" }
})

$btnHotSet.Add_Click({
    try {
        # release the current hotkey while capturing so it does not fire / so the test is accurate
        try { $script:HkWnd.Unregister($script:HKId) } catch { }
        $new = Show-HotKeyDialog $txtHot.Text
        if ($null -ne $new) {
            $txtHot.Text = $new
            if ($new -eq '') { $chkHot.Checked = $false }   # cleared -> no hotkey
        }
        $r = Apply-HotKey $txtHot.Text ([bool]$chkHot.Checked)
        $lblHotStatus.Text = $r.Msg
        $lblHotStatus.ForeColor = if ($r.Ok) { [System.Drawing.Color]::FromArgb(0, 110, 0) } else { [System.Drawing.Color]::FromArgb(170, 0, 0) }
        Log-Line "全局快捷键: $($r.Msg)"
        Save-Params
    } catch { Log-Line "快捷键设置失败: $($_.Exception.Message)" }
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
$btnPickProc.Add_Click({
    $cur = Get-FilterList
    $apps = @(Get-VisibleApps)
    $names = New-Object System.Collections.Generic.List[string]

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = '选择程序（只列出有可见窗口的程序）'
    $dlg.ClientSize = New-Object System.Drawing.Size(500, 470)
    $dlg.StartPosition = 'CenterParent'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false
    $dlg.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
    $dlg.BackColor = [System.Drawing.Color]::FromArgb(245, 246, 249)

    $hint = New-Object System.Windows.Forms.Label
    $hint.Text = '仅显示当前有可见窗口的程序；勾选后写入筛选列表。'
    $hint.SetBounds(14, 10, 470, 20)
    $dlg.Controls.Add($hint)

    $il = New-Object System.Windows.Forms.ImageList
    $il.ImageSize = New-Object System.Drawing.Size(16, 16)
    $il.ColorDepth = 'Depth32Bit'

    $lv = New-Object System.Windows.Forms.ListView
    $lv.SetBounds(14, 36, 472, 366)
    $lv.View = 'Details'
    $lv.CheckBoxes = $true
    $lv.FullRowSelect = $true
    $lv.MultiSelect = $false
    $lv.HeaderStyle = 'Nonclickable'
    $lv.SmallImageList = $il
    $lv.BackColor = [System.Drawing.Color]::White
    [void]$lv.Columns.Add('程序（勾选 = 加入筛选列表）', 440)
    $dlg.Controls.Add($lv)

    foreach ($a in $apps) {
        $imgIdx = -1
        $bmp = Get-AppIcon $a.Hwnd $a.Name
        if ($bmp) { $il.Images.Add($bmp); $imgIdx = $il.Images.Count - 1 }
        $label = if ($a.Title) { "$($a.Name)   —   $($a.Title)" } else { $a.Name }
        $item = New-Object System.Windows.Forms.ListViewItem($label, $imgIdx)
        $item.Checked = ($cur -contains $a.Name)
        [void]$lv.Items.Add($item)
        $names.Add($a.Name)
    }
    foreach ($n in $cur) {
        if (-not ($names -contains $n)) {
            $item = New-Object System.Windows.Forms.ListViewItem("$n   —   (未运行)", -1)
            $item.Checked = $true
            [void]$lv.Items.Add($item)
            $names.Add($n)
        }
    }

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = '确定'; $ok.SetBounds(320, 412, 80, 30); $ok.DialogResult = 'OK'
    Set-BtnStyle $ok -Primary
    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = '取消'; $cancel.SetBounds(406, 412, 80, 30); $cancel.DialogResult = 'Cancel'
    Set-BtnStyle $cancel
    $dlg.Controls.Add($ok); $dlg.Controls.Add($cancel)
    $dlg.AcceptButton = $ok; $dlg.CancelButton = $cancel

    if ($dlg.ShowDialog($form) -eq 'OK') {
        $sel = New-Object System.Collections.Generic.List[string]
        for ($i = 0; $i -lt $lv.Items.Count; $i++) { if ($lv.Items[$i].Checked) { $sel.Add($names[$i]) } }
        $txtFilterList.Text = ($sel -join ', ')
        if ($sel.Count -gt 0 -and $cbFilterMode.SelectedIndex -eq 0) { $cbFilterMode.SelectedIndex = 1 }
        Log-Line ("程序列表已更新: " + ($sel -join ', '))
    }
    $dlg.Dispose()
})

$form.Add_Shown({
    Load-ConfigIntoUi
    Snapshot-Controls
    $script:SavedConfig = (Collect-Config)
    Refresh-View
    Update-Tray
    $r = Apply-HotKey $txtHot.Text ([bool]$chkHot.Checked)
    $lblHotStatus.Text = $r.Msg
    $lblHotStatus.ForeColor = if ($r.Ok) { [System.Drawing.Color]::FromArgb(0, 110, 0) } else { [System.Drawing.Color]::FromArgb(170, 0, 0) }
    Log-Line "全局快捷键: $($r.Msg)"
    Log-Line "Rime TTS Readback v$script:AppVersion 已就绪（最小化/关闭窗口会缩到通知栏）"
    $st = Get-FeatureState
    if ($st.Installed -and -not $st.Muted -and -not $st.Watcher) { Start-Watcher | Out-Null }
    if ($Tray) { Hide-ToTray }
})

if ($Smoke) {
    [void]$form.CreateControl()
    Load-ConfigIntoUi
    Refresh-View
    Update-Tray
    $hk = Apply-HotKey $txtHot.Text ([bool]$chkHot.Checked)
    Write-Output ("smoke ok: form built; hotkey " + $hk.Msg)
    $timer.Stop()
    try { $script:HkWnd.Unregister($script:HKId); $script:HkWnd.Dispose() } catch { }
    $notify.Visible = $false
    $notify.Dispose()
    $form.Dispose()
    exit 0
}

if ($HotkeyDialog) {
    Write-Output ('captured=' + (Show-HotKeyDialog 'Ctrl+Alt+R'))
    exit 0
}
if ($AboutDialog) {
    Load-ConfigIntoUi
    Show-AboutDialog
    exit 0
}

# Application.Run (not ShowDialog) so hiding the form to the tray keeps the app alive.
[System.Windows.Forms.Application]::Run($form)
