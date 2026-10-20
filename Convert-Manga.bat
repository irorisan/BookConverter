@echo off
setlocal DisableDelayedExpansion
chcp 65001 >nul

if "%~1"=="" (
    echo.
    echo Drag manga folders, ZIP, CBZ, RAR, or EPUB files onto this BAT file.
    echo You can drop multiple items at once.
    echo.
    pause
    exit /b 1
)

if not exist "%~dp0Convert-Manga.ps1" (
    echo ERROR: Convert-Manga.ps1 was not found beside this BAT file.
    pause
    exit /b 1
)

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Convert-Manga.ps1" %*
set "result=%ERRORLEVEL%"

echo.
if not "%result%"=="0" echo Finished with errors. Exit code: %result%
echo Press any key to close.
pause >nul
exit /b %result%