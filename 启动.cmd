@echo off
chcp 65001 >nul
title Windows 11 国旗 Emoji 修复工具
cd /d "%~dp0"

rem 若无参数，进入交互菜单；有参数则直通脚本
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0flag-fix.ps1" %*

if errorlevel 1 pause