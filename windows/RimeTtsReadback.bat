@echo off
rem Launch the rime-tts-readback control panel (no console window).
start "" powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0RimeTtsReadback.Gui.ps1"
