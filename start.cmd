@echo off
rem Starts the foobar2000 Discord Rich Presence script hidden in the background.
start "" powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0foobar-discord-rpc.ps1"
