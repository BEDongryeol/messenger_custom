@echo off
setlocal
chcp 65001 >nul
title Dooray Skin Setup
set "DRB_SELF=%~f0"
set "DRB_MODE=install"
if /i "%~1"=="/uninstall" set "DRB_MODE=uninstall"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$s=[IO.File]::ReadAllText($env:DRB_SELF,[Text.Encoding]::UTF8); $i=$s.IndexOf('#'+'DRB_PS_BEGIN'); Invoke-Expression $s.Substring($i)"
set "RC=%ERRORLEVEL%"
echo.
if not "%RC%"=="0" (pause) else (timeout /t 6 >nul)
exit /b %RC%
