@echo off
setlocal
if exist "%LOCALAPPDATA%\HauHauVoiceStack\hauhau-voice-stack.cmd" (
  call "%LOCALAPPDATA%\HauHauVoiceStack\hauhau-voice-stack.cmd" doctor
) else (
  echo HauHau Voice Stack is not installed.
  exit /b 1
)
if errorlevel 1 pause
