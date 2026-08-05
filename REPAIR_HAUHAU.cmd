@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" -Repair %*
set "rc=%errorlevel%"
if not "%rc%"=="0" (
  echo.
  echo Repair failed. Read the message above.
  pause
)
exit /b %rc%
