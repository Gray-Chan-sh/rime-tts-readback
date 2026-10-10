@echo off
start "" /min powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0Rime_tts_watcher.ps1"
echo Rime TTS watcher started.
