@echo off
setlocal
title DeepSeek Harness Portable Bootstrap
cd /d "%~dp0"

echo.
echo  DeepSeek Harness - Windows portable bootstrap
echo  Double-click / this window will prepare a temporary runtime,
echo  run the install agent, then you may delete this folder.
echo.

where powershell >nul 2>nul
if errorlevel 1 (
  echo [ERR] PowerShell not found. Windows 10+ is required.
  pause
  exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start.ps1" %*
set ERR=%ERRORLEVEL%
echo.
if not "%ERR%"=="0" (
  echo [ERR] Exit code %ERR%
  pause
)
endlocal & exit /b %ERR%
