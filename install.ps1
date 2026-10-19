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
    [switch]$Verify,
    [switch]$InstallServer
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

function Save-Backup {
    # Preserve the current contents of a file before it is overwritten, under a
    # name that does not already exist: .bak, then .bak.1, .bak.2, ...
    #
    # Two rules, both learned the hard way:
    #   * Never reuse a name. A plain `Copy-Item -Force` onto a fixed ".bak"
    #     silently replaces the first backup on the next install - and after a
    #     user has edited a file twice, the first backup is the only copy of the
    #     original they have left.
    #   * Copy to a ".partial" name and only then move it into place, so an
    #     interrupted copy can never leave a truncated file that LOOKS like a
    #     complete backup. If the copy fails, nothing of the user's is lost: the
    #     destination has not been touched yet and the earlier backups are intact.
    param([string]$Path)

    $candidate = "$Path.bak"
    $n = 0
    while (Test-Path -LiteralPath $candidate) {
        $n++
        $candidate = "$Path.bak.$n"
    }
    $temp = "$candidate.partial"
    try {
        Copy-Item -LiteralPath $Path -Destination $temp -Force
        Move-Item -LiteralPath $temp -Destination $candidate -Force
    }
    catch {
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        throw
    }
    return $candidate
}

function Install-File {
    param([string]$From, [string]$To, [string]$Label)
    $dir = Split-Path -Parent $To
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    if (Test-Path -LiteralPath $To) {
        $same = (Get-FileHash -LiteralPath $From).Hash -eq (Get-FileHash -LiteralPath $To).Hash
        if ($same) { Say ("  = {0}" -f $Label); return }
        $backup = Save-Backup -Path $To
        Copy-Item -LiteralPath $From -Destination $To -Force
        Say ("  ~ {0}  (previous version saved as {1})" -f $Label, (Split-Path -Leaf $backup)) 'Yellow'
    }
    else {
        Copy-Item -LiteralPath $From -Destination $To -Force
        Say ("  + {0}" -f $Label) 'Green'
    }
}

function Install-Tree {
    param([string]$From, [string]$To, [string]$Label)

    $existed = Test-Path -LiteralPath $To
    if (-not $existed) { New-Item -ItemType Directory -Force -Path $To | Out-Null }

    # Compare relative paths + SHA-256 and copy only what is missing or differs.
    # Copy-Item -Force over an identical file still rewrites it, which makes a
    # running Godot editor rescan the whole addon for nothing - so "unchanged"
    # has to mean untouched, not merely "same hash afterwards".
    #
    # A file that differs is the user's, or an older upstream, and either way it is
    # backed up before it is replaced. This used to overwrite in place with no
    # backup at all - the one path where an upgrade could destroy a hand-edited
    # handler permanently.
    #
    # Stale files are left alone, deliberately. A file that no longer exists
    # upstream may be a handler the user added, and this function cannot tell an
    # integration-owned file from a user file - both are plain .gd files in one
    # tree. Deleting them needs an explicit manifest and its own tested decision,
    # not a silent delete here.
    $copied = 0
    $kept = 0
    $backups = 0
    foreach ($source in Get-ChildItem -LiteralPath $From -Recurse -File) {
        $rel = $source.FullName.Substring($From.Length).TrimStart('\')
        $dest = Join-Path $To $rel
        $destDir = Split-Path -Parent $dest
        if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Force -Path $destDir | Out-Null }

        if (Test-Path -LiteralPath $dest) {
            if ((Get-FileHash -LiteralPath $source.FullName).Hash -eq (Get-FileHash -LiteralPath $dest).Hash) {
                $kept++
                continue
            }
            $null = Save-Backup -Path $dest
            $backups++
            Copy-Item -LiteralPath $source.FullName -Destination $dest -Force
            $copied++
        }
        else {
            Copy-Item -LiteralPath $source.FullName -Destination $dest -Force
            $copied++
        }
    }

    if (-not $existed) { Say ("  + {0}" -f $Label) 'Green'; return }
    if ($copied -eq 0) { Say ("  = {0}" -f $Label); return }
    $detail = "{0} file(s) updated, {1} unchanged" -f $copied, $kept
    if ($backups -gt 0) { $detail += ", {0} backed up as .bak" -f $backups }
    Say ("  ~ {0}  ({1})" -f $Label, $detail) 'Yellow'
}

# ---------------------------------------------------------------- preflight

Say ''
Say 'opencode-godot installer' 'Cyan'
Say ("  source : {0}" -f $repo)
Say ("  target : {0}" -f $ConfigRoot)
Say ''

function Find-Uv {
    $cmd = Get-Command 'uv' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    $fallback = Join-Path $env:USERPROFILE '.local\bin\uv.exe'
    if (Test-Path -LiteralPath $fallback) { return $fallback }
    return $null
}

function Find-Server {
    if ($env:GODOT_MCP_SERVER_EXE -and (Test-Path -LiteralPath $env:GODOT_MCP_SERVER_EXE)) { return $env:GODOT_MCP_SERVER_EXE }
    $cmd = Get-Command 'godot-editor-mcp' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    $fallback = Join-Path $env:USERPROFILE '.local\bin\godot-editor-mcp.exe'
    if (Test-Path -LiteralPath $fallback) { return $fallback }
    return $null
}

$uv = Find-Uv
$serverExe = Find-Server

if (-not $serverExe -and $InstallServer) {
    if (-not $uv) {
        Say ''
        Say '  ! -InstallServer needs uv, and uv is not installed.' 'Red'
        Say '    install uv first, then re-run this command:' 'Gray'
        Say '      winget install --id=astral-sh.uv -e' 'DarkGray'
        Say '      (or: powershell -c "irm https://astral.sh/uv/install.ps1 | iex")' 'DarkGray'
        exit 1
    }
    Say ''
    Say 'Server' 'Cyan'
    Say '  installing godot-editor-mcp with uv ...'
    # uv writes its progress to stderr. Under $ErrorActionPreference='Stop',
    # PowerShell 5.1 turns a native command's stderr into a terminating
    # NativeCommandError - so relax it for exactly this call and read the code.
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & $uv tool install godot-editor-mcp 2>&1 | ForEach-Object { "    $_" }
    $installCode = $LASTEXITCODE
    $ErrorActionPreference = $prevEap

    $serverExe = Find-Server
    if ($installCode -ne 0) {
        Say ("  ! uv tool install failed (exit {0}) - see the output above" -f $installCode) 'Red'
        Say '    if a previous attempt was interrupted, repair it with:' 'Gray'
        Say '        uv tool uninstall godot-editor-mcp' 'DarkGray'
        Say '    then re-run this installer.' 'Gray'
        exit 1
    }
    if ($serverExe) { Say ("  + {0}" -f $serverExe) 'Green' }
    else {
        Say '  ! uv ran but godot-editor-mcp is still not found - check the output above' 'Red'
        exit 1
    }
}

if ($serverExe) {
    Say ("  mcp server : {0}" -f $serverExe) 'Green'
}
else {
    Say '  mcp server : NOT INSTALLED' 'Red'
    if ($uv) {
        Say '               run this, then re-run the installer:' 'Gray'
        Say '                   uv tool install godot-editor-mcp' 'DarkGray'
        Say '               or use -InstallServer to do it here.' 'DarkGray'
    }
    else {
        # The usual first-run wall: no Python toolchain at all. Give the exact
        # commands in order, not the one command that cannot work yet.
        Say '               you need uv (a small Python tool runner) first:' 'Gray'
        Say '                   1) winget install --id=astral-sh.uv -e' 'DarkGray'
        Say '                   2) uv tool install godot-editor-mcp' 'DarkGray'
        Say '               or: powershell -c "irm https://astral.sh/uv/install.ps1 | iex"' 'DarkGray'
        Say '               then re-run this installer (or use -InstallServer after step 1).' 'Gray'
    }
    Say '               the workflow files are installed anyway; the service needs the server.' 'DarkGray'
}

$addonSrc = Join-Path $repo 'addon\godot_mcp'
if (-not (Test-Path -LiteralPath (Join-Path $addonSrc 'plugin.cfg'))) {
    throw "addon/ is missing or incomplete - is this a full checkout? (looked for $addonSrc\plugin.cfg)"
}

# ---------------------------------------------------------------- files

Say 'Files' 'Cyan'

foreach ($s in @(
        'godot-ensure.ps1',
        'godot-doctor.ps1',
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
    # Redirected or roaming AppData can make this return an empty string, and
    # Join-Path on '' throws a cryptic binding error mid-install. Autostart is a
    # convenience, not a requirement: say so and carry on.
    $startup = [Environment]::GetFolderPath('Startup')
    if (-not $startup) {
        Say ''
        Say 'Autostart: skipped - the Startup folder could not be resolved' 'Yellow'
        Say '           start the service by hand, or add the .cmd to your own startup:' 'DarkGray'
        Say ("           {0}" -f (Join-Path $ConfigRoot 'scripts\godot-mcp-service.cmd')) 'DarkGray'
        $startup = $null
    }
}
if ($startup -and -not $NoAutostart) {
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
    if ($PatchOpencode) {
        # A fresh opencode install usually has no opencode.json yet (it is created on
        # demand), so "patch" has to mean "create" here or the flag silently no-ops
        # for exactly the people it is meant for.
        $body = "{`r`n  `"mcp`": {`r`n    `"godot`": { `"type`": `"remote`", `"url`": `"http://127.0.0.1:$svcPort/mcp`" }`r`n  }`r`n}`r`n"
        [System.IO.File]::WriteAllText($cfg, $body, (New-Object System.Text.UTF8Encoding($false)))
        Say ''
        Say 'opencode.json : created with the "godot" remote server' 'Green'
    }
    else {
        Say ''
        Say 'opencode.json : not found here - add this to your config:' 'Yellow'
        Say $snippet 'DarkGray'
    }
}
else {
    $raw = Get-Content -LiteralPath $cfg -Raw
    if ($raw -match '"godot"\s*:') {
        # An entry that exists is not necessarily an entry that works: if the
        # port changed, opencode connects to nothing and the tools silently
        # never appear. Converge on the current port instead of no-oping.
        $target = "http://127.0.0.1:$svcPort/mcp"
        $current = $null
        try { $current = (ConvertFrom-Json $raw).mcp.godot.url } catch { }
        if ($current -eq $target) {
            Say ''
            Say 'opencode.json : already has the "godot" MCP server' 'Green'
        }
        elseif (-not $current) {
            Say ''
            Say 'opencode.json : has a "godot" entry this script cannot read - check it by hand' 'Yellow'
        }
        elseif (-not $PatchOpencode) {
            Say ''
            Say ("opencode.json : `"godot`" points at {0}, but the service is on {1}" -f $current, $target) 'Yellow'
            Say '                re-run with -PatchOpencode to update it' 'Gray'
        }
        elseif (([regex]::Matches($raw, [regex]::Escape($current))).Count -ne 1) {
            Say ''
            Say 'opencode.json : the old URL appears more than once - edit the "godot" url by hand' 'Yellow'
        }
        else {
            $updated = $raw.Replace($current, $target)
            $valid = $true
            try { $null = $updated | ConvertFrom-Json } catch { $valid = $false }
            if (-not $valid) {
                Say ''
                Say 'opencode.json : refusing to write - the result would not be valid JSON' 'Red'
            }
            else {
                Copy-Item -LiteralPath $cfg -Destination "$cfg.bak-opencode-godot" -Force
                [System.IO.File]::WriteAllText($cfg, $updated, (New-Object System.Text.UTF8Encoding($false)))
                Say ''
                Say ("opencode.json : updated `"godot`" -> {0}" -f $target) 'Green'
            }
        }
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

            $entry = '"godot": { "type": "remote", "url": "http://127.0.0.1:' + $svcPort + '/mcp" }'
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
        # Same stderr hazard as -InstallServer: a warning from node must not
        # abort the installer.
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        & node $probe --tools
        $probeCode = $LASTEXITCODE
        $ErrorActionPreference = $prevEap
        if ($probeCode -ne 0) { Say '  ! service unreachable' 'Red' }
    }
}

Say ''
if (-not $serverExe) {
    # A cheerful "Done" here is how a beginner ends up with a workflow that cannot
    # start. Say what is actually missing and make the exit code honest.
    Say 'NOT READY - the godot-editor-mcp server is missing (see above).' 'Red'
    Say '  the files are installed, so you only need to install the server:' 'Gray'
    if ($uv) { Say '      uv tool install godot-editor-mcp' 'DarkGray' }
    else {
        Say '      winget install --id=astral-sh.uv -e' 'DarkGray'
        Say '      uv tool install godot-editor-mcp' 'DarkGray'
    }
    Say '  then re-run this installer.' 'Gray'
    Say ''
    exit 1
}

Say 'Done.' 'Cyan'
Say '  next: open your Godot project, then ask opencode for a game.' 'Gray'
if (-not $NoService) {
    Say '  if opencode is already running, reload it so it picks up the MCP server:  opencode reload' 'Gray'
}
Say '        first time in a project (this form works even when .ps1 files are blocked):' 'Gray'
Say '            powershell -NoProfile -ExecutionPolicy Bypass -File scripts\godot-ensure.ps1 -ProjectPath <dir> -Restart' 'DarkGray'
Say '        not sure it works? one-block report:' 'Gray'
Say '            powershell -NoProfile -ExecutionPolicy Bypass -File scripts\godot-doctor.ps1' 'DarkGray'
Say ''
