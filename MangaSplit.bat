@echo off
setlocal DisableDelayedExpansion
chcp 65001 >nul

if not exist "%~dp0scripts\Start-BookConverter-Terminal.ps1" (
    echo ERROR: Terminal launcher was not found in scripts.
    pause
    exit /b 1
)

pwsh.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Start-BookConverter-Terminal.ps1" -Mode Split %*
set "result=%ERRORLEVEL%"

if not "%result%"=="0" (
    echo MangaSplit Windows Terminal launch failed. Exit code: %result%
    pause
)
exit /b %result%
