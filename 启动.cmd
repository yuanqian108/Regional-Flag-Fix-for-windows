@echo off
chcp 65001 >nul
rem Windows 11 Regional Flag Emoji Fix Tool
title Windows 11 Regional Flag Emoji
cd /d "%~dp0"

rem Launch the PowerShell installer (menu if no args)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0flag-fix.ps1" %*

if errorlevel 1 pause
