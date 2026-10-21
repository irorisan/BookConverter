@echo off
setlocal DisableDelayedExpansion
chcp 65001 >nul
if not exist "%~dp0scripts\Update-BookConverter.ps1" (
    echo ERROR: scripts\Update-BookConverter.ps1 not found.
    pause
    exit /b 1
)
pwsh.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Update-BookConverter.ps1"
set "result=%ERRORLEVEL%"
echo.
if not "%result%"=="0" echo BookConverter update failed: %result%
pause
exit /b %result%
