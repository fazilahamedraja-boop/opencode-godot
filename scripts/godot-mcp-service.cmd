@echo off
rem ---------------------------------------------------------------------------
rem Godot Editor MCP - long-lived HTTP service.
rem
rem WHY THIS EXISTS:
rem The editor bridge (ws://127.0.0.1:9080) is a single connection - exactly one
rem server process can own it. Some MCP clients spawn the stdio server more than
rem once (opencode did: 3x, ~3s apart), and the losing duplicates never get the
rem port, so the instance the client actually talks to has no bridge and every
rem addon tool fails with bridge_bind_error 10048. Running ONE long-lived service
rem that owns the bridge, with the client pointed at it as a remote server,
rem removes the race entirely.
rem
rem Configured in opencode.json as:
rem   "godot": { "type": "remote", "url": "http://127.0.0.1:9090/mcp" }
rem
rem Started at logon by godot-mcp-service.vbs in the Startup folder.
rem
rem ENVIRONMENT (all optional):
rem   GODOT_MCP_SERVER_EXE   full path to godot-editor-mcp.exe
rem   GODOT_BIN              full path to the Godot editor binary
rem   GODOT_MCP_HTTP_PORT    default 9090
rem ---------------------------------------------------------------------------
setlocal

if not defined GODOT_MCP_HTTP_PORT set "GODOT_MCP_HTTP_PORT=9090"
if not defined GODOT_MCP_BRIDGE_PORT set "GODOT_MCP_BRIDGE_PORT=9080"

set "LOGDIR=%LOCALAPPDATA%\godot-mcp"
if not exist "%LOGDIR%" mkdir "%LOGDIR%"

rem The running service holds its own stdout log open, so a second instance pointing
rem at the same file would fail to start. Keep the log per port; the default port
rem keeps the plain name so existing setup notes still point somewhere real.
if "%GODOT_MCP_HTTP_PORT%"=="9090" (
  set "LIFELOG=%LOGDIR%\service-lifecycle.log"
) else (
  set "LIFELOG=%LOGDIR%\service-lifecycle-%GODOT_MCP_HTTP_PORT%.log"
)

rem --- idempotency guard: never run a second copy (it would lose the 9080 race)
rem Guard lines go to their OWN log: the running service holds lifecycle.log open
rem as its stdout, so a second writer there would fail with a file lock.
netstat -ano | findstr /C:":%GODOT_MCP_HTTP_PORT%" | findstr /C:"LISTENING" >nul 2>&1
if not errorlevel 1 (
  echo [%date% %time%] already listening on %GODOT_MCP_HTTP_PORT% - not starting a second copy. >> "%LOGDIR%\service-starts.log"
  exit /b 0
)

rem --- locate the MCP server (PyPI package: godot-editor-mcp)
set "SERVER=%GODOT_MCP_SERVER_EXE%"
if not defined SERVER for /f "delims=" %%i in ('where godot-editor-mcp 2^>nul') do set "SERVER=%%i"
if not defined SERVER if exist "%USERPROFILE%\.local\bin\godot-editor-mcp.exe" set "SERVER=%USERPROFILE%\.local\bin\godot-editor-mcp.exe"

if not defined SERVER (
  echo [%date% %time%] godot-editor-mcp not found - install it with: uv tool install godot-editor-mcp >> "%LOGDIR%\service-starts.log"
  echo.
  echo   godot-editor-mcp was not found on PATH.
  echo   Install it first:
  echo.
  echo       uv tool install godot-editor-mcp
  echo.
  echo   or set GODOT_MCP_SERVER_EXE to its full path.
  exit /b 2
)

rem --- locate the Godot editor binary (optional: only headless runs/exports need it)
if not defined GODOT_MCP_GODOT_BIN if defined GODOT_BIN set "GODOT_MCP_GODOT_BIN=%GODOT_BIN%"
if not defined GODOT_MCP_GODOT_BIN for /f "delims=" %%i in ('where godot_console.exe 2^>nul') do set "GODOT_MCP_GODOT_BIN=%%i"
if not defined GODOT_MCP_GODOT_BIN for /f "delims=" %%i in ('dir /b /o-n "%USERPROFILE%\godot\Godot_v*-stable_win64_console.exe" 2^>nul') do (
  if not defined GODOT_MCP_GODOT_BIN set "GODOT_MCP_GODOT_BIN=%USERPROFILE%\godot\%%i"
)

echo [%date% %time%] starting godot-mcp service (server=%SERVER%) >> "%LOGDIR%\service-starts.log"

set GODOT_MCP_TRANSPORT=http
set GODOT_MCP_HTTP_HOST=127.0.0.1
set GODOT_MCP_HTTP_PORT=%GODOT_MCP_HTTP_PORT%
set GODOT_MCP_BRIDGE_URL=ws://127.0.0.1:%GODOT_MCP_BRIDGE_PORT%
set GODOT_MCP_LOG_LEVEL=INFO

"%SERVER%" >> "%LIFELOG%" 2>&1

endlocal
