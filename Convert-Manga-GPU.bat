@echo off
setlocal DisableDelayedExpansion
chcp 65001 >nul

if not exist "%~dp0scripts\Start-BookConverter-Terminal.ps1" (
    echo ERROR: scripts\Start-BookConverter-Terminal.ps1 was not found.
    pause
    exit /b 1
)

pwsh.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Start-BookConverter-Terminal.ps1" -Mode GPU %*
set "result=%ERRORLEVEL%"

if not "%result%"=="0" (
    echo BookConverter Windows Terminal launch failed. Exit code: %result%
    pause
)
exit /b %result%
