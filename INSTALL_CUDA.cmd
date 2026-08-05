@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" -Runtime Cuda %*
set "rc=%errorlevel%"
if not "%rc%"=="0" (
  echo.
  echo CUDA installation failed. Read the message above.
  pause
  exit /b %rc%
)
echo.
if "%~1"=="" pause
exit /b 0
