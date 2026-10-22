@echo off
setlocal DisableDelayedExpansion
chcp 65001 >nul

if not exist "%~dp0scripts\MangaSplit.ps1" (
  echo ERROR: scripts\MangaSplit.ps1 was not found.
  pause
  exit /b 1
)

where pwsh.exe >nul 2>nul
if errorlevel 1 (
  echo ERROR: Windows PowerShell 7.6.x (pwsh.exe) is required.
  pause
  exit /b 1
)

pwsh.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\MangaSplit.ps1" %*
set "result=%ERRORLEVEL%"
echo.
if not "%result%"=="0" (
  echo MangaSplit failed. Exit code: %result%
)
pause
exit /b %result%
