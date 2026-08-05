@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0hauhau-voice-stack.ps1" %*
exit /b %errorlevel%
