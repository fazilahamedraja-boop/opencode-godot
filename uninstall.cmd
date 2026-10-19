@echo off
rem Same execution-policy workaround as install.cmd, for removal.
rem
rem   uninstall.cmd           remove the installed files, keep the game journal
rem   uninstall.cmd -KeepAddon   leave addons\godot_mcp inside your projects
rem
setlocal
set "HERE=%~dp0"

powershell -NoProfile -ExecutionPolicy Bypass -File "%HERE%uninstall.ps1" %*
set "CODE=%ERRORLEVEL%"

if "%~1"=="" pause
exit /b %CODE%
