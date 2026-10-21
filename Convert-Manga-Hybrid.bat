@echo off
setlocal DisableDelayedExpansion
chcp 65001 >nul
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Convert-Manga.ps1" -ConversionMode Hybrid %*
set "result=%ERRORLEVEL%"
pause
exit /b %result%
