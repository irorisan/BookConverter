@echo off
setlocal DisableDelayedExpansion
chcp 65001 >nul

if not exist "%~dp0Convert-Manga.ps1" (
    echo ERROR: Convert-Manga.ps1 was not found beside this BAT file.
    pause
    exit /b 1
)

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Convert-Manga.ps1" %*
set "result=%ERRORLEVEL%"

if not "%result%"=="0" (
    echo Finished with errors. Exit code: %result%
    pause
)
exit /b %result%
