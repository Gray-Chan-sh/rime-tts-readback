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
  [int]$IdleMs        = 60,     # group commits that arrive this close together
  [int]$MaxWaitMs     = 200,    # ...but never wait longer than this
  [int]$Threshold     = 180,
  [int]$PadMs         = 15,
  [int]$Volume        = 100,    # 0..200, applied to the rendered samples
  [bool]$CharByChar   = $false, # true = separate the characters with a comma pause (slower)
  [bool]$IncludeAscii = $true,  # read ASCII letters and digits too
  [string]$AppFilterMode = 'all', # 'all' | 'only' | 'except'
  [string[]]$AppFilterList = @()
)

# ---- config file (written by the GUI); hot-reloaded whenever it changes ----
$ConfigFile = Join-Path $env:USERPROFILE 'Rime_tts_config.json'

function Import-Config {
  if (-not (Test-Path -LiteralPath $ConfigFile)) { return $false }
  try {
    $cfg = Get-Content -LiteralPath $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($n in @('Voice','Rate','IdleMs','MaxWaitMs','Threshold','PadMs',
                     'Volume','CharByChar','IncludeAscii','AppFilterMode','AppFilterList')) {
      $v = $cfg.$n
      if ($null -ne $v) { Set-Variable -Name $n -Value $v -Scope script }
    }
    return $true
  } catch { return $false }
}
$null = Import-Config
$script:CfgStamp = if (Test-Path -LiteralPath $ConfigFile) { (Get-Item -LiteralPath $ConfigFile).LastWriteTimeUtc } else { [DateTime]::MinValue }

# single instance: never run two readers at once
$script:WtrMutex = New-Object System.Threading.Mutex($false, 'Local\RimeTtsReadback.Watcher')
$wtrFirst = $false
try { $wtrFirst = $script:WtrMutex.WaitOne(0) } catch { $wtrFirst = $true }
if (-not $wtrFirst) { exit 0 }

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
function Apply-VoiceRate {
  try { $synth.SelectVoice($Voice) } catch { Log "SelectVoice failed: $($_.Exception.Message)" }
  try { $synth.Rate = $Rate } catch { }
}
Apply-VoiceRate

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
  # NOTE: never use <break> here. SAPI's Chinese engine repeats the last syllable when a
  # <break> appears inside Chinese text, whatever the break time. A full-width comma
  # (U+FF0C) gives a real pause without the repetition.
  $comma = [char]0xFF0C
  if ($CharByChar) {
    $parts = @()
    foreach ($ch in $readable.ToCharArray()) {
      $parts += [System.Security.SecurityElement]::Escape($ch.ToString())
    }
    $body = $parts -join $comma
  } else {
    $body = [System.Security.SecurityElement]::Escape($readable)
  }
  return "<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='zh-CN'>$body</speak>"
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
  $first = -1; $last = -1; $peak = 0
  for ($k = 0; $k -lt $samples; $k++) {
    $v = [int]$shorts[$k]
    $a = if ($v -lt 0) { -$v } else { $v }
    if ($a -gt $peak) { $peak = $a }
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
  # loudness: normalise the peak (SAPI's output is quiet - only ~38% of full scale),
  # then apply the user volume on top. gain is capped so near-silence is not blown up.
  $gain = 1.0
  if ($peak -ge 200) {
    $gain = (0.90 * 32767.0) / $peak
    if ($gain -gt 4.0) { $gain = 4.0 }
    if ($gain -lt 1.0) { $gain = 1.0 }
  }
  $factor = $gain * ([double]$volume / 100.0)
  $script:LastGain = $factor

  if ([Math]::Abs($factor - 1.0) -lt 0.001) {
    $bw.Write($bytes, $off + $first * 2, $dataLen)
  } else {
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

function Speak-Now([string]$readable, [string]$proc) {
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
  Log ("read [" + $readable + "] proc=[" + $proc + "] gain=" + [math]::Round($script:LastGain, 2) +
       "x synth=" + [int](($t1-$t0).TotalMilliseconds) + "ms play=" + [int](($t2-$t1).TotalMilliseconds) + "ms")
}

# clear stale queue (including half-written .tmp files)
try {
  Get-ChildItem -LiteralPath $QueueDir -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Extension -in '.txt', '.tmp' } | Remove-Item -Force -ErrorAction SilentlyContinue
} catch { }

Log "watcher started voice=$Voice rate=$Rate charByChar=$CharByChar vol=$Volume idle=${IdleMs}ms appFilter=$AppFilterMode [$($AppFilterList -join ',')]"

$buffer = ''; $since = $null; $lastAdd = $null; $fgProc = ''
$lastSweep = [DateTime]::UtcNow
$lastCfgCheck = [DateTime]::UtcNow

while ($true) {
  # hot-reload the config (the GUI writes it) - takes effect within ~1s, no restart needed
  if ((([DateTime]::UtcNow) - $lastCfgCheck).TotalSeconds -ge 1) {
    $lastCfgCheck = [DateTime]::UtcNow
    if (Test-Path -LiteralPath $ConfigFile) {
      $stamp = (Get-Item -LiteralPath $ConfigFile).LastWriteTimeUtc
      if ($stamp -ne $script:CfgStamp) {
        $script:CfgStamp = $stamp
        if (Import-Config) {
          Apply-VoiceRate
          Log "config reloaded: voice=$Voice rate=$Rate charByChar=$CharByChar vol=$Volume idle=${IdleMs}ms appFilter=$AppFilterMode [$($AppFilterList -join ',')]"
        }
      }
    }
  }

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
    Speak-Now $readable $procNow
  } else {
    Start-Sleep -Milliseconds 20
  }
}
