<#
.SYNOPSIS
    Install the opencode -> Godot prompt-to-game workflow into an opencode config.

.DESCRIPTION
    Copies the five automation scripts, the godot-game-by-prompt skill, the /game
    command, and the pinned Godot addon into an opencode config directory, then
    (optionally) starts the long-lived MCP service and points opencode at it.

    Idempotent: re-running it on an up-to-date install changes nothing. A file that
    exists and differs is backed up to <name>.bak before being replaced, so a local
    edit is never silently destroyed.

.PARAMETER ConfigRoot
    opencode config directory. Defaults to %USERPROFILE%\.config\opencode.
    Point this at a temp directory to test an install without touching your config.

.PARAMETER PatchOpencode
    Insert the "godot" remote MCP server into <ConfigRoot>\opencode.json if it is
    not already there. Without this flag the snippet is printed and nothing is
    modified.

.PARAMETER NoAutostart
    Do not create the logon shortcut (godot-mcp-service.vbs) in the Startup folder.

.PARAMETER NoService
    Do not start the MCP service now.

.PARAMETER Verify
    Run the probe after installing and report whether the service and bridge are up.

.EXAMPLE
    .\install.ps1 -PatchOpencode -Verify

.EXAMPLE
    # clean-room test: install into a throwaway directory, touch nothing else
    .\install.ps1 -ConfigRoot "$env:TEMP\og-test" -NoAutostart -NoService
#>
[CmdletBinding()]
param(
    [string]$ConfigRoot = (Join-Path $env:USERPROFILE '.config\opencode'),
    [switch]$PatchOpencode,
    [switch]$NoAutostart,
    [switch]$NoService,
    [switch]$Verify
)

$ErrorActionPreference = 'Stop'
$repo = $PSScriptRoot

function Say { param([string]$Text, [string]$Color = 'Gray') Write-Host $Text -ForegroundColor $Color }

function Test-Port {
    param([int]$Port)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect('127.0.0.1', $Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne(400)) { return $false }
        $client.EndConnect($iar)
        return $true
    }
    catch { return $false }
    finally { $client.Close() }
}

function Install-File {
    param([string]$From, [string]$To, [string]$Label)
    $dir = Split-Path -Parent $To
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    if (Test-Path -LiteralPath $To) {
        $same = (Get-FileHash -LiteralPath $From).Hash -eq (Get-FileHash -LiteralPath $To).Hash
        if ($same) { Say ("  = {0}" -f $Label); return }
        Copy-Item -LiteralPath $To -Destination "$To.bak" -Force
        Copy-Item -LiteralPath $From -Destination $To -Force
        Say ("  ~ {0}  (previous version saved as .bak)" -f $Label) 'Yellow'
    }
    else {
        Copy-Item -LiteralPath $From -Destination $To -Force
        Say ("  + {0}" -f $Label) 'Green'
    }
}

function Install-Tree {
    param([string]$From, [string]$To, [string]$Label)
    # Compare relative paths + hashes, so a re-run can report "unchanged" honestly.
    $fingerprint = {
        (Get-ChildItem $To -Recurse -File | Sort-Object FullName | Get-FileHash |
            ForEach-Object { $_.Path.Substring($To.Length) + ':' + $_.Hash }) -join "`n"
    }

    $existed = Test-Path -LiteralPath $To
    if (-not $existed) { New-Item -ItemType Directory -Force -Path $To | Out-Null }
    $before = if ($existed) { & $fingerprint } else { $null }

    # Copy the CONTENTS. `Copy-Item -Recurse -Destination <existing dir>` would nest
    # the source inside it ($To\godot_mcp\godot_mcp), which duplicated the whole tree.
    Copy-Item -Path (Join-Path $From '*') -Destination $To -Recurse -Force

    if (-not $existed) { Say ("  + {0}" -f $Label) 'Green'; return }
    if ($before -eq (& $fingerprint)) { Say ("  = {0}" -f $Label); return }
    Say ("  ~ {0}  (updated in place)" -f $Label) 'Yellow'
}

# ---------------------------------------------------------------- preflight

Say ''
Say 'opencode-godot installer' 'Cyan'
Say ("  source : {0}" -f $repo)
Say ("  target : {0}" -f $ConfigRoot)
Say ''

$serverExe = $env:GODOT_MCP_SERVER_EXE
if (-not $serverExe) {
    $cmd = Get-Command 'godot-editor-mcp' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { $serverExe = $cmd.Source }
    elseif (Test-Path -LiteralPath (Join-Path $env:USERPROFILE '.local\bin\godot-editor-mcp.exe')) {
        $serverExe = Join-Path $env:USERPROFILE '.local\bin\godot-editor-mcp.exe'
    }
}

if ($serverExe) {
    Say ("  mcp server : {0}" -f $serverExe) 'Green'
}
else {
    Say '  mcp server : NOT FOUND' 'Yellow'
    Say '               install it first:  uv tool install godot-editor-mcp' 'Yellow'
    Say '               (the workflow can be installed now and started later)' 'DarkGray'
}

$addonSrc = Join-Path $repo 'addon\godot_mcp'
if (-not (Test-Path -LiteralPath (Join-Path $addonSrc 'plugin.cfg'))) {
    throw "addon/ is missing or incomplete - is this a full checkout? (looked for $addonSrc\plugin.cfg)"
}

# ---------------------------------------------------------------- files

Say 'Files' 'Cyan'

foreach ($s in @(
        'godot-ensure.ps1',
        'godot-new-project.ps1',
        'godot-journal.ps1',
        'godot-mcp-service.cmd',
        'godot-mcp-probe.mjs'
    )) {
    Install-File -From (Join-Path $repo "scripts\$s") -To (Join-Path $ConfigRoot "scripts\$s") -Label "scripts\$s"
}

Install-File -From (Join-Path $repo 'skill\godot-game-by-prompt\SKILL.md') `
    -To (Join-Path $ConfigRoot 'skills\godot-game-by-prompt\SKILL.md') `
    -Label 'skills\godot-game-by-prompt\SKILL.md'

Install-File -From (Join-Path $repo 'command\game.md') `
    -To (Join-Path $ConfigRoot 'commands\game.md') `
    -Label 'commands\game.md'

Install-Tree -From $addonSrc -To (Join-Path $ConfigRoot 'godot-mcp-addon\godot_mcp') -Label 'godot-mcp-addon\godot_mcp'

# ---------------------------------------------------------------- autostart

if ($NoAutostart) {
    Say ''
    Say 'Autostart: skipped (-NoAutostart)' 'DarkGray'
}
else {
    $startup = [Environment]::GetFolderPath('Startup')
    $vbs = Join-Path $startup 'godot-mcp-service.vbs'
    $cmdPath = Join-Path $ConfigRoot 'scripts\godot-mcp-service.cmd'
    $body = "' Auto-started at logon: one long-lived Godot Editor MCP service.`r`n"
    $body += "' Created by opencode-godot/install.ps1. Delete this file to stop autostart.`r`n"
    $body += "Set sh = CreateObject(""WScript.Shell"")`r`n"
    # VBS escapes a quote inside a string as "". So the source line needs exactly
    # three quotes around the path: one to open the string, two for a quote.
    $body += ('sh.Run """{0}""", 0, False' -f $cmdPath) + "`r`n"

    Set-Content -LiteralPath $vbs -Value $body -Encoding ASCII -NoNewline
    Say ''
    Say ("Autostart: {0}" -f $vbs) 'Green'
    Say '           (starts the service at logon, hidden)' 'DarkGray'
}

# ---------------------------------------------------------------- service

if ($NoService) {
    Say 'Service : not started (-NoService)' 'DarkGray'
}
elseif (-not $serverExe) {
    Say 'Service : skipped - godot-editor-mcp is not installed' 'Yellow'
}
else {
    Say ''
    Say 'Service' 'Cyan'
    $port = if ($env:GODOT_MCP_HTTP_PORT) { [int]$env:GODOT_MCP_HTTP_PORT } else { 9090 }
    if (Test-Port -Port $port) {
        Say ("  = already listening on {0}" -f $port)
    }
    else {
        $svc = Join-Path $ConfigRoot 'scripts\godot-mcp-service.cmd'
        Start-Process -FilePath 'cmd.exe' -ArgumentList "/c `"$svc`"" -WindowStyle Hidden | Out-Null
        $deadline = (Get-Date).AddSeconds(40)
        while ((Get-Date) -lt $deadline -and -not (Test-Port -Port $port)) { Start-Sleep -Milliseconds 400 }
        if (Test-Port -Port $port) {
            Say ("  + listening on {0}" -f $port) 'Green'
        }
        else {
            Say ("  ! did not come up on {0} - check %LOCALAPPDATA%\godot-mcp\service-starts.log" -f $port) 'Red'
        }
    }
}

# ---------------------------------------------------------------- opencode.json

$cfg = Join-Path $ConfigRoot 'opencode.json'
$svcPort = if ($env:GODOT_MCP_HTTP_PORT) { $env:GODOT_MCP_HTTP_PORT } else { '9090' }
$snippet = @"
  "mcp": {
    "godot": { "type": "remote", "url": "http://127.0.0.1:$svcPort/mcp" }
  }
"@

if (-not (Test-Path -LiteralPath $cfg)) {
    Say ''
    Say 'opencode.json : not found here - add this to your config:' 'Yellow'
    Say $snippet 'DarkGray'
}
else {
    $raw = Get-Content -LiteralPath $cfg -Raw
    if ($raw -match '"godot"\s*:') {
        Say ''
        Say 'opencode.json : already has a "godot" MCP server' 'Green'
    }
    elseif ($PatchOpencode) {
        $marker = '"mcp"\s*:\s*\{'
        if ($raw -notmatch $marker) {
            Say ''
            Say 'opencode.json : no "mcp" block - add this by hand:' 'Yellow'
            Say $snippet 'DarkGray'
        }
        else {
            Copy-Item -LiteralPath $cfg -Destination "$cfg.bak-opencode-godot" -Force

            $entry = '"godot": { "type": "remote", "url": "http://127.0.0.1:9090/mcp" }'
            $parsedBefore = $null
            try { $parsedBefore = $raw | ConvertFrom-Json } catch { }

            if ([regex]::IsMatch($raw, '"mcp"\s*:\s*\{\s*\}')) {
                # `"mcp": {}` - no trailing comma allowed
                $raw = [regex]::Replace($raw, '"mcp"\s*:\s*\{\s*\}', ('"mcp": {' + "`r`n    " + $entry + "`r`n  }"), 1)
            }
            else {
                $evaluator = [System.Text.RegularExpressions.MatchEvaluator] {
                    param($m)
                    $m.Value + "`r`n    " + $entry + ','
                }
                $raw = [regex]::Replace($raw, $marker, $evaluator, 1)
            }

            # If the config was valid JSON before the edit, it must still be valid after.
            $ok = $true
            if ($parsedBefore) {
                try { $null = $raw | ConvertFrom-Json } catch { $ok = $false }
            }
            if (-not $ok) {
                Copy-Item -LiteralPath "$cfg.bak-opencode-godot" -Destination $cfg -Force
                Say ''
                Say 'opencode.json : patch would have produced invalid JSON - restored, edit by hand:' 'Red'
                Say $snippet 'DarkGray'
            }
            else {
                [System.IO.File]::WriteAllText($cfg, $raw, (New-Object System.Text.UTF8Encoding($false)))
                Say ''
                Say 'opencode.json : added the "godot" remote server  (backup: .bak-opencode-godot)' 'Green'
            }
        }
    }
    else {
        Say ''
        Say 'opencode.json : add this under "mcp" (or re-run with -PatchOpencode):' 'Yellow'
        Say $snippet 'DarkGray'
    }
}

# ---------------------------------------------------------------- verify

if ($Verify) {
    Say ''
    Say 'Verify' 'Cyan'
    $probe = Join-Path $ConfigRoot 'scripts\godot-mcp-probe.mjs'
    if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
        Say '  ! node not found - cannot run the probe' 'Yellow'
    }
    else {
        & node $probe --tools
        if ($LASTEXITCODE -ne 0) { Say '  ! service unreachable' 'Red' }
    }
}

Say ''
Say 'Done.' 'Cyan'
Say '  next: open your Godot project, then ask opencode for a game.' 'Gray'
Say '        first time in a project:  scripts\godot-ensure.ps1 -ProjectPath <dir> -Restart' 'Gray'
Say ''
