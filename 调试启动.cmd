@echo off
setlocal
cd /d "%~dp0"
if not exist data mkdir data
echo Starting desktop app...
echo Error log: %~dp0data\last-error.log
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0src\App.ps1" 1>"%~dp0data\last-output.log" 2>"%~dp0data\last-error.log"
if errorlevel 1 (
  echo.
  echo App failed. Error:
  type "%~dp0data\last-error.log"
  echo.
  pause
)
