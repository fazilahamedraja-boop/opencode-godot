<#
.SYNOPSIS
  Report whether this machine is ready to build games in Godot from opencode.

.DESCRIPTION
  Read-only. Prints one block you can copy into a chat or an issue, then exits.

    READY       exit 0  every prerequisite is present AND an editor is attached
    ALMOST      exit 0  the tools are installed, no editor is attached yet
    NOT READY   exit 1  something is missing or broken (the count is on the line)

  ALMOST exits 0 on purpose: "open the project in Godot" is a runtime step, not
  an installation failure, and a script that gates on this must not read it as
  one. Only a missing prerequisite, a config that points at the wrong port, an
  unreachable service or a failed handshake produce NOT READY.

  Two different things are reported separately and must not be conflated:
  the HTTP service being available (port listening + handshake answered), and
  the Godot editor bridge being connected (an editor actually attached). The
  service can be perfectly healthy with no editor anywhere, which is ALMOST.

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
# $bad counts things that are missing or broken: prerequisites, config, service.
# $attached is runtime state, tracked separately - see the verdict below.
$bad = 0
$attached = $false

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

function Get-Sha256 {
    # Deliberately NOT Get-FileHash: a PowerShell 7 session hands its PSModulePath
    # to a Windows PowerShell 5.1 child, 5.1 then resolves
    # Microsoft.PowerShell.Utility from PS7's directory, that Core assembly does
    # not load, and Get-FileHash disappears from the session. The .NET hash API is
    # present on every host, imports nothing, and returns the same uppercase hex.
    param([string]$Path)

    $stream = [System.IO.File]::OpenRead($Path)
    try {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            $bytes = $sha.ComputeHash($stream)
            $sb = New-Object System.Text.StringBuilder
            foreach ($b in $bytes) { $null = $sb.Append($b.ToString('X2')) }
            return $sb.ToString()
        }
        finally { $sha.Dispose() }
    }
    finally { $stream.Dispose() }
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

# Same order as install.ps1 and godot-ensure.ps1: an explicit override first, so
# the doctor never reports MISSING on a machine those two are happy with.
$server = $null
if ($env:GODOT_MCP_SERVER_EXE -and (Test-Path -LiteralPath $env:GODOT_MCP_SERVER_EXE)) { $server = $env:GODOT_MCP_SERVER_EXE }
if (-not $server) { $server = Find-Tool 'godot-editor-mcp' (Join-Path $env:USERPROFILE '.local\bin\godot-editor-mcp.exe') }
Row 'mcp server' ($(if ($server) { $server } else { 'MISSING - uv tool install godot-editor-mcp' })) ([bool]$server)

$godot = $env:GODOT_BIN
if (-not $godot) { $godot = Find-Tool 'godot_console' $null }
if (-not $godot) { $godot = Find-Tool 'godot' $null }
if (-not $godot) {
    # Same directories, filter and "newest first" pick as godot-ensure.ps1, so
    # the two can never disagree about which copy of the editor is in use.
    $godotDirs = @(
        (Join-Path $env:USERPROFILE 'Downloads'),
        (Join-Path $env:USERPROFILE 'Desktop'),
        (Join-Path $env:USERPROFILE 'godot'),
        (Join-Path $env:LOCALAPPDATA 'Programs'),
        (Join-Path ${env:ProgramFiles} 'Godot'),
        (Join-Path ${env:ProgramFiles} 'Godot Engine')
    )
    foreach ($d in $godotDirs) {
        if (-not (Test-Path -LiteralPath $d)) { continue }
        $hit = Get-ChildItem $d -Filter 'Godot_v*-stable_win64*.exe' -Recurse -Depth 2 -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending | Select-Object -First 1
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
        # opencode reads MCP servers from mcp.servers.<name>. The older flat
        # mcp.<name> form is deprecated in the schema but still parsed, so both
        # are honoured here - reading only the flat form made this row report
        # "MISSING" (and NOT READY) on a config that was working fine.
        $godotEntry = if ($j.mcp.servers.godot) { $j.mcp.servers.godot } else { $j.mcp.godot }
        $hasGodot = $null -ne $godotEntry
        if (-not $hasGodot) {
            Row 'opencode.json' ("{0}  godot entry: MISSING" -f $cfg) $false
        }
        else {
            # The URL must point at the port the service is actually on, or
            # opencode connects to nothing and the tools silently never appear.
            $url = [string]$godotEntry.url
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

# ---------------------------------------------------------------- install drift
# install.ps1 leaves scripts\.install-source.json: the checkout it installed
# from and a SHA-256 per installed file. Two different mismatches matter, and
# neither is a broken machine, so both are reported as information only:
#   * a recorded file whose hash changed here -> the local copy was edited
#     (a user's deliberate change, or something else writing to the config)
#   * a recorded file whose hash changed in the checkout -> the checkout has
#     moved on since this install, i.e. a fix that was never installed
# Reading only the versions cannot see either: same file, different content.
$recordPath = Join-Path $configRoot 'scripts\.install-source.json'
if (Test-Path -LiteralPath $recordPath) {
    try {
        $record = Get-Content -LiteralPath $recordPath -Raw | ConvertFrom-Json
        $sourceRepo = [string]$record.repo

        function Get-RecordedFiles {
            param($Record)
            # Empty (or unreadable) "files" must yield nothing, not throw.
            if (-not $Record -or -not $Record.files) { return @() }
            $Record.files.PSObject.Properties | ForEach-Object { [pscustomobject]@{ Rel = $_.Name; Sha = [string]$_.Value } }
        }

        $recorded = @(Get-RecordedFiles -Record $record)
        $missingHere = 0
        $editedHere = 0
        foreach ($item in $recorded) {
            $file = Join-Path $configRoot ($item.Rel -replace '/', '\')
            if (-not (Test-Path -LiteralPath $file)) { $missingHere++; continue }
            if ((Get-Sha256 -Path $file) -ne $item.Sha) { $editedHere++ }
        }

        $repoMoved = 0
        $repoPresent = $false
        if ($sourceRepo) { $repoPresent = Test-Path -LiteralPath $sourceRepo }
        if ($repoPresent) {
            foreach ($item in $recorded) {
                $src = Join-Path $sourceRepo ($item.Rel -replace '/', '\')
                if (-not (Test-Path -LiteralPath $src)) { $repoMoved++; continue }
                if ((Get-Sha256 -Path $src) -ne $item.Sha) { $repoMoved++ }
            }
        }

        $facts = @()
        if ($missingHere) { $facts += "$missingHere missing here" }
        if ($editedHere) { $facts += "$editedHere edited here" }
        if (-not $facts) { $facts += 'all files as installed' }
        $source = if ($sourceRepo) { $sourceRepo } else { '(no source path recorded)' }
        Row 'install' ("{0}  ({1})" -f $source, ($facts -join ', '))

        if ($repoMoved) {
            Row '   drift' ("{0} file(s) in the checkout differ from this install - run install.cmd to update" -f $repoMoved)
        }
        if (-not $repoPresent) {
            Row '   drift' 'the recorded checkout is not there any more - update checks skipped (re-run install.cmd to re-record)'
        }
    }
    catch {
        Row 'install' ("$recordPath  UNREADABLE - " + $_.Exception.Message)
    }
}
elseif (Test-Path -LiteralPath (Join-Path $configRoot 'scripts\godot-ensure.ps1')) {
    # An install that predates the record: nothing is wrong, so this is a hint,
    # not a failure. Counting it would make every older install NOT READY.
    Row 'install' 'no install record (run install.cmd again to enable drift checks)'
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
        $attached = [bool]$health.bridge_connected
        # Deliberately NOT counted in $bad. An unattached editor is the normal
        # state on a machine that is installed but idle, and counting it here is
        # what made the ALMOST verdict unreachable: $bad -eq 0 then implied the
        # bridge was up, so the READY branch always won and ALMOST was dead code.
        Row 'bridge' ($(if ($attached) { "CONNECTED (addon $($health.addon_version))" } else { 'no editor attached - open the project in Godot' })) $true
    }
    else {
        Row 'bridge' 'unknown - godot_health_check did not answer' $false
    }
}

# ---------------------------------------------------------------- verdict
$rows | ForEach-Object { Write-Host "  $_" }
Write-Host ''
if ($bad -gt 0) {
    Write-Host "  NOT READY - $bad item(s) above need attention." -ForegroundColor Red
    exit 1
}
if ($attached) {
    Write-Host '  READY - opencode can build games here right now.' -ForegroundColor Green
    exit 0
}
Write-Host '  ALMOST - tools are installed; the editor is not attached yet.' -ForegroundColor Yellow
Write-Host '           open the project in Godot, or run godot-ensure.ps1.' -ForegroundColor Yellow
exit 0
