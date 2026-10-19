<#
.SYNOPSIS
  Report whether this machine is ready to build games in Godot from opencode.

.DESCRIPTION
  Read-only. Prints one block you can copy into a chat or an issue, then exits:
    0 = everything the workflow needs is present (bridge may still be down)
    1 = something is missing

  Needs no Node: the MCP handshake is done with Invoke-WebRequest.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File scripts\godot-doctor.ps1
#>
[CmdletBinding()]
param(
    [int]$TimeoutSec = 5
)

$ErrorActionPreference = 'Continue'

$servicePort = if ($env:GODOT_MCP_HTTP_PORT) { [int]$env:GODOT_MCP_HTTP_PORT } else { 9090 }
$bridgePort = if ($env:GODOT_MCP_BRIDGE_PORT) { [int]$env:GODOT_MCP_BRIDGE_PORT } else { 9080 }
$base = if ($env:GODOT_MCP_URL) { $env:GODOT_MCP_URL } else { "http://127.0.0.1:$servicePort/mcp" }
$configRoot = if ($env:OPENCODE_GODOT_CONFIG) { $env:OPENCODE_GODOT_CONFIG } else { Join-Path $env:USERPROFILE '.config\opencode' }

$rows = [System.Collections.Generic.List[string]]::new()
$bad = 0

function Row { param([string]$Name, [string]$Value, [bool]$Ok = $true)
    if (-not $Ok) { $script:bad++ }
    $rows.Add(('{0,-12} {1}' -f $Name, $Value))
}

function Find-Tool {
    param([string]$Name, [string]$Fallback)
    $c = Get-Command $Name -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($c) { return $c.Source }
    if ($Fallback -and (Test-Path -LiteralPath $Fallback)) { return $Fallback }
    return $null
}

# ---------------------------------------------------------------- environment
$os = Get-CimInstance Win32_OperatingSystem
Row 'windows' ("{0} (build {1})" -f $os.Caption, $os.BuildNumber)
Row 'powershell' ("{0} {1}" -f $PSVersionTable.PSVersion, $(if ($PSVersionTable.PSEdition) { $PSVersionTable.PSEdition } else { 'Desktop' }))

# A doctor run through -ExecutionPolicy Bypass reports "Bypass" for the process,
# which hides the value that actually bites the user later. Show the scopes.
$polMachine = (Get-ExecutionPolicy -Scope LocalMachine).ToString()
$polUser = (Get-ExecutionPolicy -Scope CurrentUser).ToString()
Row 'policy' ("machine={0}  user={1}  (this process: {2})" -f $polMachine, $polUser, (Get-ExecutionPolicy).ToString())

$uv = Find-Tool 'uv' (Join-Path $env:USERPROFILE '.local\bin\uv.exe')
Row 'uv' ($(if ($uv) { $uv } else { 'MISSING - winget install --id=astral-sh.uv -e' })) ([bool]$uv)

$server = Find-Tool 'godot-editor-mcp' (Join-Path $env:USERPROFILE '.local\bin\godot-editor-mcp.exe')
Row 'mcp server' ($(if ($server) { $server } else { 'MISSING - uv tool install godot-editor-mcp' })) ([bool]$server)

$godot = $env:GODOT_BIN
if (-not $godot) { $godot = Find-Tool 'godot_console' $null }
if (-not $godot) { $godot = Find-Tool 'godot' $null }
if (-not $godot) {
    foreach ($d in @((Join-Path $env:USERPROFILE 'Downloads'), (Join-Path $env:USERPROFILE 'Desktop'), (Join-Path $env:USERPROFILE 'godot'))) {
        if (-not (Test-Path -LiteralPath $d)) { continue }
        $hit = Get-ChildItem $d -Filter 'Godot_v*-stable_win64*.exe' -Recurse -Depth 2 -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($hit) { $godot = $hit.FullName; break }
    }
}
Row 'godot' ($(if ($godot) { $godot } else { 'MISSING - -GodotExe <path>, GODOT_BIN, or put it on PATH' })) ([bool]$godot)

$node = Find-Tool 'node' $null
Row 'node' ($(if ($node) { "present (only needed for -Verify)" } else { 'absent (optional)' }))

# ---------------------------------------------------------------- opencode config
$cfg = Join-Path $configRoot 'opencode.json'
if (Test-Path -LiteralPath $cfg) {
    try {
        $j = Get-Content -LiteralPath $cfg -Raw | ConvertFrom-Json
        $hasGodot = $null -ne $j.mcp.godot
        if (-not $hasGodot) {
            Row 'opencode.json' ("{0}  godot entry: MISSING" -f $cfg) $false
        }
        else {
            # The URL must point at the port the service is actually on, or
            # opencode connects to nothing and the tools silently never appear.
            $url = [string]$j.mcp.godot.url
            $cfgPort = 0
            if ($url -match ':(\d+)/') { $cfgPort = [int]$Matches[1] }
            $portOk = ($cfgPort -eq $servicePort)
            Row 'opencode.json' ("{0}  -> {1}" -f $cfg, $url) $portOk
            if (-not $portOk) {
                Row '   config port' ("{0} but the service listens on {1} - re-run install.cmd -PatchOpencode with GODOT_MCP_HTTP_PORT={1}" -f $cfgPort, $servicePort) $false
            }
        }
    }
    catch {
        Row 'opencode.json' ("$cfg  INVALID JSON - " + $_.Exception.Message) $false
    }
}
else {
    Row 'opencode.json' "no file at $cfg (a fresh opencode install has none)" $false
}

# ---------------------------------------------------------------- service + bridge
$listening = [bool](Get-NetTCPConnection -LocalPort $servicePort -State Listen -ErrorAction SilentlyContinue)
Row "service $servicePort" $(if ($listening) { 'listening' } else { 'not listening' }) $listening

$bridge = [bool](Get-NetTCPConnection -LocalPort $bridgePort -State Listen -ErrorAction SilentlyContinue)
Row "bridge $bridgePort" $(if ($bridge) { 'listening' } else { 'not listening' }) $bridge

$init = $null
$health = $null
if ($listening) {
    try {
        $body = '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"godot-doctor","version":"1"}}}'
        $res = Invoke-WebRequest -Uri $base -Method Post -UseBasicParsing -TimeoutSec $TimeoutSec `
            -ContentType 'application/json' -Headers @{ Accept = 'application/json, text/event-stream' } -Body $body
        $sid = $res.Headers['mcp-session-id']
        $line = ($res.Content -split "`n" | Where-Object { $_ -like 'data:*' } | Select-Object -First 1)
        $init = ($line -replace '^data:\s*', '' | ConvertFrom-Json)

        $hbody = '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"godot_health_check","arguments":{}}}'
        $hres = Invoke-WebRequest -Uri $base -Method Post -UseBasicParsing -TimeoutSec $TimeoutSec `
            -ContentType 'application/json' -Headers @{ Accept = 'application/json, text/event-stream'; 'mcp-session-id' = $sid } -Body $hbody
        $hline = ($hres.Content -split "`n" | Where-Object { $_ -like 'data:*' } | Select-Object -First 1)
        $hjson = ($hline -replace '^data:\s*', '' | ConvertFrom-Json)
        $health = $hjson.result.content[0].text | ConvertFrom-Json
    }
    catch {
        Row 'mcp handshake' ("failed - " + $_.Exception.Message) $false
    }
}

if ($init) {
    Row 'server' ("{0} {1}" -f $init.result.serverInfo.name, $init.result.serverInfo.version)
    if ($health) {
        Row 'bridge' $(if ($health.bridge_connected) { "CONNECTED (addon $($health.addon_version))" } else { 'no editor attached - open the project in Godot' }) ([bool]$health.bridge_connected)
    }
    else {
        Row 'bridge' 'unknown - godot_health_check did not answer' $false
    }
}

# ---------------------------------------------------------------- verdict
$rows | ForEach-Object { Write-Host "  $_" }
Write-Host ''
$bridgeUp = [bool]($health -and $health.bridge_connected)
if ($bad -eq 0 -and $bridgeUp) {
    Write-Host '  READY - opencode can build games here right now.' -ForegroundColor Green
    exit 0
}
if ($bad -eq 0 -and $server -and $godot -and $listening) {
    Write-Host '  ALMOST - tools are installed; the editor is not attached yet.' -ForegroundColor Yellow
    Write-Host '           open the project in Godot, or run godot-ensure.ps1.' -ForegroundColor Yellow
    exit 0
}
Write-Host "  NOT READY - $bad item(s) above need attention." -ForegroundColor Red
exit 1
