$pat = 'Rime_tts_' + 'watcher.ps1'
$n = 0
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
  Where-Object { $_.CommandLine -match $pat } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue; $n++ }
Write-Output ("stopped " + $n + " watcher process(es)")
