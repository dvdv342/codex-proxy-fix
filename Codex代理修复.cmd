@echo off
chcp 65001 >nul
setlocal
title Codex Proxy Fix

if not exist "%~dp0CodexProxy.ps1" (
    echo [ERROR] CodexProxy.ps1 not found next to this file.
    echo         Both files must stay in the same folder.
    pause
    exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0CodexProxy.ps1" %*
set "RC=%ERRORLEVEL%"

echo.
echo ------------------------------------------------------------
if "%RC%"=="0" (
    echo Done.
) else (
    echo Exit code: %RC%
)
echo ------------------------------------------------------------
pause
exit /b %RC%
