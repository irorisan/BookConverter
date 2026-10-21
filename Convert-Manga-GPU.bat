@echo off
setlocal DisableDelayedExpansion
chcp 65001 >nul
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Convert-Manga.ps1" -GPU %*
set "result=%ERRORLEVEL%"
echo.
if not "%result%"=="0" echo GPU conversion failed: %result%
pause
exit /b %result%
