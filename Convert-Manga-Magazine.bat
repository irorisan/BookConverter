@echo off
setlocal DisableDelayedExpansion
chcp 65001 >nul

if not exist "%~dp0scripts\Convert-Manga.ps1" (
    echo ERROR: scripts\Convert-Manga.ps1 was not found.
    pause
    exit /b 1
)

pwsh.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Convert-Manga.ps1" -Magazine %*
set "result=%ERRORLEVEL%"

if not "%result%"=="0" (
    echo Finished with errors. Exit code: %result%
    pause
)
exit /b %result%
