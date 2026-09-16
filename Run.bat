@echo off
title Steam Workshop Downloader
chcp 65001 >nul
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0downloader.ps1"
echo.
echo Нажмите любую клавишу для выхода...
pause >nul
