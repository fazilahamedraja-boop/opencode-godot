@echo off
rem ---------------------------------------------------------------------------
rem Beginner-proof entry point.
rem
rem A fresh Windows install refuses to run .ps1 files ("running scripts is
rem disabled on this system"), and a file downloaded from the internet is also
rem blocked by the Mark-of-the-Web. -ExecutionPolicy Bypass handles both for
rem THIS process only; it changes no machine or user policy.
rem
rem   install.cmd                      install, then start the service
rem   install.cmd -PatchOpencode       also add the MCP server to opencode.json
rem   install.cmd -InstallServer       also run: uv tool install godot-editor-mcp
rem   install.cmd -Verify              also probe the service
rem
rem Every argument is passed straight through to install.ps1.
rem ---------------------------------------------------------------------------
setlocal
set "HERE=%~dp0"

powershell -NoProfile -ExecutionPolicy Bypass -File "%HERE%install.ps1" %*
set "CODE=%ERRORLEVEL%"

rem When double-clicked the console vanishes on exit, so hold it open. Called
rem with arguments (or from a script) it must not block.
if "%~1"=="" pause
exit /b %CODE%
