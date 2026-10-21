@echo off
setlocal DisableDelayedExpansion
chcp 65001 >nul
pwsh.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Convert-Manga.ps1" -ConversionMode Hybrid %*
set "result=%ERRORLEVEL%"
pause
exit /b %result%
