# Rime committed-text TTS watcher  (low-latency version)
#
# SAPI adds ~0.45s of silence before/after every utterance and costs ~1s on the audio
# device; synthesis itself is ~20ms. So we synthesize SSML to a WAV file, trim the
# leading/trailing silence (optionally scale the volume), then play with SoundPlayer ->
# audio starts almost instantly.
#
# Watches %USERPROFILE%\Rime_tts_queue for *.txt written by rime.lua on each commit.
# Toggle: if %USERPROFILE%\Rime_tts_off exists, incoming text is drained silently.
# Config: %USERPROFILE%\Rime_tts_config.json (written by the GUI).
# ASCII-only source on purpose.

param(
  [string]$QueueDir   = (Join-Path $env:USERPROFILE 'Rime_tts_queue'),
  [string]$Voice      = 'Microsoft Huihui Desktop',
  [int]$Rate          = 0,      # lower = each character is pronounced longer/clearer
  [int]$BreakMs       = 30,     # gap between characters (when CharByChar)
  [int]$IdleMs        = 60,     # group commits that arrive this close together
  [int]$MaxWaitMs     = 200,    # ...but never wait longer than this
  [int]$Threshold     = 180,
  [int]$PadMs         = 15,
  [int]$Volume        = 100,    # 0..100, applied to the rendered samples
  [bool]$CharByChar   = $true,  # false = read the phrase in one go (no per-char break)
  [bool]$IncludeAscii = $true,  # read ASCII letters and digits too
  [string]$AppFilterMode = 'all', # 'all' | 'only' | 'except'
  [string[]]$AppFilterList = @()
)

# ---- config file (written by the GUI) ----
$ConfigFile = Join-Path $env:USERPROFILE 'Rime_tts_config.json'
if (Test-Path -LiteralPath $ConfigFile) {
  try {
    $cfg = Get-Content -LiteralPath $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($n in @('Voice','Rate','BreakMs','IdleMs','MaxWaitMs','Threshold','PadMs',
                     'Volume','CharByChar','IncludeAscii','AppFilterMode','AppFilterList')) {
      $v = $cfg.$n
      if ($null -ne $v) { Set-Variable -Name $n -Value $v }
    }
  } catch { }
}

$OffFile = Join-Path $env:USERPROFILE 'Rime_tts_off'
$LogFile = Join-Path $env:USERPROFILE 'Rime_tts_watcher.log'
$RawWav  = Join-Path $env:TEMP 'rime_tts_raw.wav'
$OutWav  = Join-Path $env:TEMP 'rime_tts_out.wav'
$SampleRate = 22050
$MaxLogBytes = 1MB

# ---- log rotation (keep it from growing without bound) ----
try {
  if ((Test-Path -LiteralPath $LogFile) -and ((Get-Item -LiteralPath $LogFile).Length -gt $MaxLogBytes)) {
    Move-Item -LiteralPath $LogFile -Destination ($LogFile + '.1') -Force -ErrorAction SilentlyContinue
  }
} catch { }

function Log($m) {
  try { Add-Content -LiteralPath $LogFile -Value ((Get-Date).ToString('HH:mm:ss.fff') + ' ' + $m) -Encoding UTF8 } catch {}
}

Add-Type -AssemblyName System.Speech
Add-Type -Namespace RimeTTSCore -Name Win -MemberDefinition @'
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
'@ -ErrorAction SilentlyContinue

$synth = New-Object System.Speech.Synthesis.SpeechSynthesizer
try { $synth.SelectVoice($Voice) } catch { Log "SelectVoice failed: $_" }
$synth.Rate = $Rate

function Pending {
  @(Get-ChildItem -LiteralPath $QueueDir -Filter *.txt -File -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime, Name)
}

function ReadableChars([string]$txt) {
  $out = ''
  foreach ($ch in $txt.ToCharArray()) {
    if ([char]::IsWhiteSpace($ch)) { continue }
    if (-not [char]::IsLetterOrDigit($ch)) { continue }
    $u = [int][char]$ch
    if (-not $IncludeAscii -and $u -lt 128 -and [char]::IsLetter($ch)) { continue }
    $out += $ch
  }
  return $out
}

function Build-Ssml([string]$readable) {
  $effBreak = if ($CharByChar) { $BreakMs } else { 0 }
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.Append("<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='zh-CN'>")
  foreach ($ch in $readable.ToCharArray()) {
    [void]$sb.Append([System.Security.SecurityElement]::Escape($ch.ToString()))
    if ($effBreak -gt 0) { [void]$sb.Append("<break time='${effBreak}ms'/>") }
  }
  [void]$sb.Append('</speak>')
  return $sb.ToString()
}

function Get-ForegroundProcessName {
  try {
    $h = [RimeTTSCore.Win]::GetForegroundWindow()
    if ($h -eq [IntPtr]::Zero) { return '' }
    $procId = [uint32]0
    [void][RimeTTSCore.Win]::GetWindowThreadProcessId($h, [ref]$procId)
    if ($procId -le 0) { return '' }
    return (Get-Process -Id $procId -ErrorAction SilentlyContinue).ProcessName
  } catch { return '' }
}

function App-Allowed([string]$procName) {
  if ($AppFilterMode -eq 'all' -or -not $procName) { return $true }
  $list = @($AppFilterList | ForEach-Object { ($_ -replace '\.exe$', '').Trim() } | Where-Object { $_ })
  if ($list.Count -eq 0) { return $true }
  $hit = $false
  foreach ($n in $list) { if ($n -ieq $procName) { $hit = $true; break } }
  if ($AppFilterMode -eq 'only')   { return $hit }
  if ($AppFilterMode -eq 'except') { return -not $hit }
  return $true
}

function Get-DataChunk([byte[]]$bytes) {
  $i = 12
  while ($i -lt ($bytes.Length - 8)) {
    $id = [System.Text.Encoding]::ASCII.GetString($bytes, $i, 4)
    $size = [System.BitConverter]::ToInt32($bytes, $i + 4)
    if ($id -eq 'data') { return @{ Offset = $i + 8; Length = $size } }
    $i += 8 + $size + ($size % 2)
  }
  return @{ Offset = 44; Length = $bytes.Length - 44 }
}

function Trim-Silence([byte[]]$bytes, [int]$volume) {
  $d = Get-DataChunk $bytes
  $off = $d.Offset
  $samples = [int]($d.Length / 2)
  if ($samples -le 0) { return $bytes }
  $shorts = New-Object 'int16[]' $samples
  [System.Buffer]::BlockCopy($bytes, $off, $shorts, 0, $samples * 2)
  $first = -1; $last = -1
  for ($k = 0; $k -lt $samples; $k++) {
    $v = [int]$shorts[$k]
    if ($v -gt $Threshold -or $v -lt (-$Threshold)) {
      if ($first -lt 0) { $first = $k }
      $last = $k
    }
  }
  if ($first -lt 0) { return $bytes }
  $pad = [int]($SampleRate * $PadMs / 1000)
  $first = [Math]::Max(0, $first - $pad)
  $last  = [Math]::Min($samples - 1, $last + $pad)
  $n = $last - $first + 1
  $dataLen = $n * 2

  $ms = New-Object System.IO.MemoryStream
  $bw = New-Object System.IO.BinaryWriter($ms)
  [void]$bw.Write([System.Text.Encoding]::ASCII.GetBytes('RIFF'))
  $bw.Write([int](36 + $dataLen))
  [void]$bw.Write([System.Text.Encoding]::ASCII.GetBytes('WAVE'))
  [void]$bw.Write([System.Text.Encoding]::ASCII.GetBytes('fmt '))
  $bw.Write([int]16)
  $bw.Write([int16]1)
  $bw.Write([int16]1)
  $bw.Write([int]$SampleRate)
  $bw.Write([int]($SampleRate * 2))
  $bw.Write([int16]2)
  $bw.Write([int16]16)
  [void]$bw.Write([System.Text.Encoding]::ASCII.GetBytes('data'))
  $bw.Write([int]$dataLen)
  if ($volume -ge 100) {
    $bw.Write($bytes, $off + $first * 2, $dataLen)
  } else {
    $factor = [double]$volume / 100.0
    $out = New-Object 'int16[]' $n
    for ($k = 0; $k -lt $n; $k++) {
      $s = [int]([int]$shorts[$first + $k] * $factor)
      if ($s -gt 32767) { $s = 32767 } elseif ($s -lt -32768) { $s = -32768 }
      $out[$k] = [int16]$s
    }
    $buf = New-Object byte[] ($n * 2)
    [System.Buffer]::BlockCopy($out, 0, $buf, 0, $n * 2)
    $bw.Write($buf)
  }
  $bw.Flush()
  return ,([byte[]]$ms.ToArray())
}

function Speak-Now([string]$readable) {
  $t0 = [DateTime]::UtcNow
  try {
    $synth.SetOutputToWaveFile($RawWav)
    $synth.SpeakSsml((Build-Ssml $readable))
    $synth.SetOutputToNull()
  } catch { Log ("synth error: " + $_); return }
  $bytes = [System.IO.File]::ReadAllBytes($RawWav)
  $trim = Trim-Silence $bytes $Volume
  [System.IO.File]::WriteAllBytes($OutWav, $trim)
  $t1 = [DateTime]::UtcNow
  $player = New-Object System.Media.SoundPlayer $OutWav
  try { $player.PlaySync() } catch { Log ("play error: " + $_) }
  $t2 = [DateTime]::UtcNow
  Log ("read [" + $readable + "] synth=" + [int](($t1-$t0).TotalMilliseconds) +
       "ms play=" + [int](($t2-$t1).TotalMilliseconds) + "ms")
}

# clear stale queue (including half-written .tmp files)
try {
  Get-ChildItem -LiteralPath $QueueDir -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Extension -in '.txt', '.tmp' } | Remove-Item -Force -ErrorAction SilentlyContinue
} catch { }

Log "watcher started voice=$Voice rate=$Rate break=${BreakMs}ms charByChar=$CharByChar vol=$Volume idle=${IdleMs}ms appFilter=$AppFilterMode [$($AppFilterList -join ',')]"

$buffer = ''; $since = $null; $lastAdd = $null; $fgProc = ''
$lastSweep = [DateTime]::UtcNow

while ($true) {
  if (Test-Path -LiteralPath $OffFile) {
    Pending | Remove-Item -Force -ErrorAction SilentlyContinue
    $buffer = ''; $since = $null; $lastAdd = $null
    Start-Sleep -Milliseconds 150
    continue
  }

  # periodic sweep: drop orphaned .tmp files older than 5 minutes
  if ((([DateTime]::UtcNow) - $lastSweep).TotalSeconds -gt 60) {
    $lastSweep = [DateTime]::UtcNow
    try {
      Get-ChildItem -LiteralPath $QueueDir -Filter *.tmp -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddMinutes(-5) } | Remove-Item -Force -ErrorAction SilentlyContinue
    } catch { }
  }

  $files = Pending
  if ($files.Count -gt 0) {
    if (-not $since) { $since = [DateTime]::UtcNow; $fgProc = Get-ForegroundProcessName }
    foreach ($f in $files) {
      $t = ''
      try { $t = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 } catch {}
      Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
      if ($t) { $buffer += $t }
    }
    $lastAdd = [DateTime]::UtcNow
  }

  if ($buffer -eq '') { Start-Sleep -Milliseconds 40; continue }

  $now = [DateTime]::UtcNow
  $quiet  = if ($lastAdd) { ($now - $lastAdd).TotalMilliseconds } else { 9999 }
  $waited = if ($since)   { ($now - $since).TotalMilliseconds }   else { 0 }

  if ($quiet -ge $IdleMs -or $waited -ge $MaxWaitMs) {
    $rawNow = $buffer
    $procNow = $fgProc
    $buffer = ''; $since = $null; $lastAdd = $null; $fgProc = ''
    $readable = ReadableChars $rawNow
    if (-not $readable) { continue }
    if (-not (App-Allowed $procNow)) {
      Log ("skip (app filter '$AppFilterMode') proc=[" + $procNow + "] text=[" + $readable + "]")
      continue
    }
    Speak-Now $readable
  } else {
    Start-Sleep -Milliseconds 20
  }
}
