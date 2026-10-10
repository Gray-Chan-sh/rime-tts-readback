# Rime committed-text TTS watcher  (low-latency version)
#
# SAPI adds ~0.45s of silence before/after every utterance and costs ~1s on the audio
# device; synthesis itself is ~20ms. So we synthesize SSML to a WAV file, trim the
# leading/trailing silence, then play with SoundPlayer -> audio starts almost instantly.
#
# Watches %USERPROFILE%\Rime_tts_queue for *.txt written by rime.lua on each commit.
# Toggle: if %USERPROFILE%\Rime_tts_off exists, incoming text is drained silently.
# ASCII-only source on purpose.

param(
  [string]$QueueDir   = (Join-Path $env:USERPROFILE 'Rime_tts_queue'),
  [string]$Voice      = 'Microsoft Huihui Desktop',
  [int]$Rate          = 0,     # lower = each character is pronounced longer/clearer
  [int]$BreakMs       = 30,    # gap between characters
  [int]$IdleMs        = 60,    # group commits that arrive this close together
  [int]$MaxWaitMs     = 200,   # ...but never wait longer than this
  [int]$Threshold     = 180,
  [int]$PadMs         = 15,
  [bool]$IncludeAscii = $true  # read ASCII letters and digits too (English/numbers)
)

$OffFile = Join-Path $env:USERPROFILE 'Rime_tts_off'
$LogFile = Join-Path $env:USERPROFILE 'Rime_tts_watcher.log'
$RawWav  = Join-Path $env:TEMP 'rime_tts_raw.wav'
$OutWav  = Join-Path $env:TEMP 'rime_tts_out.wav'
$SampleRate = 22050

function Log($m) {
  try { Add-Content -LiteralPath $LogFile -Value ((Get-Date).ToString('HH:mm:ss.fff') + ' ' + $m) -Encoding UTF8 } catch {}
}

Add-Type -AssemblyName System.Speech
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
    if (-not [char]::IsLetterOrDigit($ch)) { continue }              # drop punctuation/symbols
    $u = [int][char]$ch
    if (-not $IncludeAscii -and $u -lt 128 -and [char]::IsLetter($ch)) { continue }
    $out += $ch
  }
  return $out
}

function Build-Ssml([string]$readable) {
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.Append("<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='zh-CN'>")
  foreach ($ch in $readable.ToCharArray()) {
    [void]$sb.Append([System.Security.SecurityElement]::Escape($ch.ToString()))
    [void]$sb.Append("<break time='${BreakMs}ms'/>")
  }
  [void]$sb.Append('</speak>')
  return $sb.ToString()
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

function Trim-Silence([byte[]]$bytes) {
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
  $bw.Write($bytes, $off + $first * 2, $dataLen)
  $bw.Flush()
  return $ms.ToArray()
}

function Speak-Now([string]$raw, [string]$readable) {
  $t0 = [DateTime]::UtcNow
  try {
    $synth.SetOutputToWaveFile($RawWav)
    $synth.SpeakSsml((Build-Ssml $readable))
    $synth.SetOutputToNull()
  } catch { Log ("synth error: " + $_); return }
  $bytes = [System.IO.File]::ReadAllBytes($RawWav)
  $trim = Trim-Silence $bytes
  [System.IO.File]::WriteAllBytes($OutWav, $trim)
  $t1 = [DateTime]::UtcNow
  $player = New-Object System.Media.SoundPlayer $OutWav
  try { $player.PlaySync() } catch { Log ("play error: " + $_) }
  $t2 = [DateTime]::UtcNow
  Log ("read [" + $readable + "] raw=[" + ($raw -replace '\s',' ') + "] synth=" + [int](($t1-$t0).TotalMilliseconds) + "ms play=" + [int](($t2-$t1).TotalMilliseconds) + "ms")
}

Pending | Remove-Item -Force -ErrorAction SilentlyContinue
Log "watcher started (low-latency) voice=$Voice rate=$Rate break=${BreakMs}ms idle=${IdleMs}ms ascii=$IncludeAscii"

$buffer = ''; $since = $null; $lastAdd = $null

while ($true) {
  if (Test-Path -LiteralPath $OffFile) {
    Pending | Remove-Item -Force -ErrorAction SilentlyContinue
    $buffer = ''; $since = $null; $lastAdd = $null
    Start-Sleep -Milliseconds 150
    continue
  }

  $files = Pending
  if ($files.Count -gt 0) {
    if (-not $since) { $since = [DateTime]::UtcNow }
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
    $readable = ReadableChars $rawNow
    $buffer = ''; $since = $null; $lastAdd = $null
    if ($readable) { Speak-Now $rawNow $readable }
    else { Log ("skip raw=[" + ($rawNow -replace '\s',' ') + "]") }
  } else {
    Start-Sleep -Milliseconds 20
  }
}
