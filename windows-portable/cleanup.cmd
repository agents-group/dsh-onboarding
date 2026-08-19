@echo off
setlocal
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0cleanup.ps1" %*
set ERR=%ERRORLEVEL%
echo.
pause
endlocal & exit /b %ERR%
