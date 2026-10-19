<#
.SYNOPSIS
    Make a Godot project ready for prompt-driven authoring, end to end, and prove it.

.DESCRIPTION
    The Godot MCP chain has four links, and any missing one looks identical from
    inside opencode ("godot tools missing" or BRIDGE_DISCONNECTED):

      1. the HTTP service on 127.0.0.1:9090   (long-lived, autostarted at logon)
      2. the addon files inside the project    (addons/godot_mcp)
      3. the plugin enabled in project.godot   ([editor_plugins] enabled=...)
      4. a RUNNING EDITOR on THAT project      (the addon dials out to :9080)

    godot-new-project.ps1 fixes 2 and 3 for one project. This script wraps it and
    also fixes 1 and 4, then polls the bridge until the addon is actually
    connected. That last step is the point: "the editor is running" and "the
    bridge is connected" are not the same thing, and assuming they are is what
    makes a fresh project look broken.

    Idempotent. Safe to run every session.

.PARAMETER ProjectPath
    Project directory. Omit to use the remembered project, then the project of a
    running editor.

.PARAMETER Restart
    Restart the editor if the addon/plugin had to be added. Godot only reads
    [editor_plugins] at startup, so a newly provisioned project cannot connect
    without a reload. Only use this when the project has no unsaved work.

.PARAMETER Create
    Create the project directory and a minimal project.godot first. Use this
    instead of creating a project through the Godot project manager, so the
    addon is present from the very first launch and the plugin is never missing.

.PARAMETER TimeoutSec
    How long to wait for the bridge to connect (editor start-up is 13-22 s).

.PARAMETER NoLaunch
    Prepare the project only: do not start, restart or close any editor and do not
    wait for the bridge. Use to provision a project you are not ready to open, or
    when another project's editor must keep ownership of the bridge.

.EXAMPLE
    & "$env:USERPROFILE\.config\opencode\scripts\godot-ensure.ps1" -ProjectPath "C:\games\my-game" -Create

.EXAMPLE
    & "$env:USERPROFILE\.config\opencode\scripts\godot-ensure.ps1" -Restart
#>
[CmdletBinding()]
param(
    [string]$ProjectPath,
    [switch]$Restart,
    [switch]$Create,
    [switch]$NoLaunch,
    [int]$TimeoutSec = 75,
    [string]$AddonSource,
    [string]$GodotExe
)

$ErrorActionPreference = 'Stop'

# The canonical addon copy ships beside this script (..\addon\godot_mcp). Fall back
# to the installed location so an existing setup keeps working after an upgrade.
if (-not $AddonSource) {
    $candidates = @(
        (Join-Path $PSScriptRoot '..\addon\godot_mcp'),
        (Join-Path $PSScriptRoot '..\godot-mcp-addon\godot_mcp'),
        (Join-Path $env:USERPROFILE '.config\opencode\godot-mcp-addon\godot_mcp')
    )
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath (Join-Path $c 'plugin.cfg')) {
            $AddonSource = (Resolve-Path -LiteralPath $c).Path
            break
        }
    }
}

$stateDir = Join-Path $env:LOCALAPPDATA 'godot-mcp'
$lastFile = Join-Path $stateDir 'last-project.txt'
$servicePort = if ($env:GODOT_MCP_HTTP_PORT) { [int]$env:GODOT_MCP_HTTP_PORT } else { 9090 }
$bridgePort = if ($env:GODOT_MCP_BRIDGE_PORT) { [int]$env:GODOT_MCP_BRIDGE_PORT } else { 9080 }

function Write-Step { param([string]$Message)
    Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $Message)
}

# A beginner should never see a PowerShell stack trace. Print the reason, the fix,
# and a documented exit code instead.
function Fail {
    param([string]$Message, [string[]]$Hints = @(), [int]$Code = 1)
    Write-Host ''
    Write-Step "ERROR: $Message"
    foreach ($h in $Hints) { Write-Host "         $h" }
    Write-Host ''
    exit $Code
}

function Test-PortListening {
    param([int]$Port)
    $c = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    return ($null -ne $c -and @($c).Count -gt 0)
}

function Split-GodotCommandLine {
    # Split a Windows command line into tokens, keeping a quoted run together.
    # Not a full CommandLineToArgvW: no backslash-escape processing, which Godot's
    # own flags never need. Returns objects so a caller can tell a quoted argument
    # (data) from a bare one (a flag or a value).
    param([string]$CommandLine)
    $tokens = @()
    if (-not $CommandLine) { return $tokens }
    foreach ($m in [regex]::Matches($CommandLine, '"([^"]*)"|(\S+)')) {
        if ($m.Groups[1].Success) {
            $tokens += [pscustomobject]@{ Value = $m.Groups[1].Value; Quoted = $true }
        }
        else {
            $tokens += [pscustomobject]@{ Value = $m.Groups[2].Value; Quoted = $false }
        }
    }
    return $tokens
}

function ConvertFrom-GodotCommandLine {
    # Classify ONE command line. Returns $null when it is not a Godot run with
    # --path at all, so the caller skips the process.
    #
    # Whole tokens, not substrings. The previous version matched '-e(ditor)?'
    # after any whitespace, which had two consequences in opposite directions:
    # a real editor started with '--editor' was NOT detected (the '-' before the
    # 'e' is not whitespace), and a project path that merely contained ' -e '
    # made a GAME look like an editor.
    param([string]$CommandLine)

    $tokens = Split-GodotCommandLine -CommandLine $CommandLine
    if ($tokens.Count -eq 0) { return $null }

    # --path <dir>, quoted or not. A quoted argument is one token, so a path with
    # spaces stays a single value instead of being cut at the first space.
    # '--path=<dir>' is deliberately not accepted: Godot takes the space form, and
    # the old code did not accept the equals form either.
    $projectPath = $null
    for ($i = 0; $i -lt $tokens.Count; $i++) {
        if ($tokens[$i].Quoted) { continue }
        if ($tokens[$i].Value -eq '--path' -and ($i + 1) -lt $tokens.Count) {
            $projectPath = $tokens[$i + 1].Value
            break
        }
    }
    if ([string]::IsNullOrEmpty($projectPath)) { return $null }

    # The three spellings Godot accepts, as standalone tokens. Quoted arguments
    # are skipped so that text inside a path is never read as a flag.
    $isEditor = $false
    foreach ($t in $tokens) {
        if ($t.Quoted) { continue }
        if ($t.Value -eq '-e' -or $t.Value -eq '-editor' -or $t.Value -eq '--editor') {
            $isEditor = $true
            break
        }
    }

    [pscustomobject]@{
        ProjectPath = ($projectPath -replace '/', '\').TrimEnd('\')
        IsEditor    = $isEditor
    }
}

function Select-GodotHostProcess {
    # Drop the launcher half of a console-build launch.
    #
    # Godot's *_console.exe is a launcher: it starts the real editor as its own
    # child, so ONE window shows up as two processes. Dropping the launcher keeps
    # the child, which is the process that owns the bridge socket. Matching on the
    # name AND on having a child is what stops a normal (childless) console build,
    # or the child of an F5 game run, from being mistaken for a launcher.
    param([object[]]$Processes)
    $kept = @()
    foreach ($p in $Processes) {
        if ($p.Name -match '_console') {
            $children = @($Processes | Where-Object { $_.ParentProcessId -eq $p.ProcessId })
            if ($children.Count -gt 0) { continue }
        }
        $kept += $p
    }
    return $kept
}

function Get-GodotEditors {
    # Every Godot process launched with --path, flagged as editor or game.
    $result = @()
    $procs = @(Get-CimInstance Win32_Process -Filter "Name LIKE 'Godot%'" -ErrorAction SilentlyContinue)
    foreach ($p in (Select-GodotHostProcess -Processes $procs)) {
        $parsed = ConvertFrom-GodotCommandLine -CommandLine $p.CommandLine
        if (-not $parsed) { continue }
        $result += [pscustomobject]@{
            OwnerPid    = $p.ProcessId
            ProjectPath = $parsed.ProjectPath
            IsEditor    = $parsed.IsEditor
        }
    }
    return $result
}

function Find-GodotExe {
    # Returns a path, or $null when nothing matches. Never fails: -NoLaunch uses
    # this to report readiness up front, instead of letting a fresh machine find
    # out on the next run - after the addon has already been copied.
    if ($GodotExe) {
        if (Test-Path -LiteralPath $GodotExe) { return $GodotExe }
        return $null
    }
    if ($env:GODOT_BIN) {
        if (Test-Path -LiteralPath $env:GODOT_BIN) { return $env:GODOT_BIN }
        return $null
    }

    # 1. on PATH (the console build prints CLI output, so prefer it)
    foreach ($name in @('godot_console', 'godot')) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cmd) { return $cmd.Source }
    }

    # 2. where a beginner actually leaves it: the ZIP unpacked in Downloads or on
    #    the Desktop, then the usual manual-install places. Shallow-but-wide beats
    #    a deep search of the whole profile.
    $dirs = @(
        (Join-Path $env:USERPROFILE 'Downloads'),
        (Join-Path $env:USERPROFILE 'Desktop'),
        (Join-Path $env:USERPROFILE 'godot'),
        (Join-Path $env:LOCALAPPDATA 'Programs'),
        (Join-Path ${env:ProgramFiles} 'Godot'),
        (Join-Path ${env:ProgramFiles} 'Godot Engine')
    )
    foreach ($dir in $dirs) {
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        $hit = Get-ChildItem $dir -Filter 'Godot_v*-stable_win64*.exe' -Recurse -Depth 2 -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending | Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }

    return $null
}

function Resolve-GodotExe {
    $found = Find-GodotExe
    if ($found) { return $found }

    # Keep the specific diagnosis when an explicit path was configured and is
    # wrong - "not installed" would send the user looking in the wrong place.
    if ($GodotExe) { Fail "Godot exe not found at -GodotExe '$GodotExe'." @() 5 }
    if ($env:GODOT_BIN) { Fail "GODOT_BIN points at '$env:GODOT_BIN', which does not exist." @() 5 }
    Fail "Godot is not installed, or it is somewhere this script cannot guess." @(
        'download: https://godotengine.org/download/windows/  (unzip anywhere)',
        'then either:  -GodotExe "C:\path\to\Godot_v4.x-stable_win64_console.exe"',
        'or:          set GODOT_BIN to that path, or put it on PATH'
    ) 5
}

function Start-Editor {
    param([string]$Project, [string]$Exe)
    Write-Step "launching editor: $Project"
    Start-Process -FilePath $Exe -ArgumentList ("--path `"$Project`" -e") | Out-Null
}

# ------------------------------------------------------------------ 1. project

if ($Create) {
    if (-not $ProjectPath) { Fail "-Create needs -ProjectPath <dir>." @() 1 }
    if (Test-Path -LiteralPath (Join-Path $ProjectPath 'project.godot')) {
        Write-Step "project already exists, not recreating: $ProjectPath"
    }
    else {
        New-Item -ItemType Directory -Force -Path $ProjectPath | Out-Null
        $name = Split-Path -Leaf (Resolve-Path -LiteralPath $ProjectPath).Path
        # config_version=5 is Godot 4.x. No main_scene yet: the build sets it.
        $body = @"
; Engine configuration file.
; Generated by godot-ensure.ps1

config_version=5

[application]

config/name="$name"

[rendering]

renderer/rendering_method="forward_plus"
"@
        $projFile = Join-Path $ProjectPath 'project.godot'
        [System.IO.File]::WriteAllText($projFile, $body, (New-Object System.Text.UTF8Encoding($false)))
        Write-Step "created project.godot: $name"
    }
}

if (-not $ProjectPath -and (Test-Path -LiteralPath $lastFile)) {
    $ProjectPath = (Get-Content -LiteralPath $lastFile -Raw).Trim()
    if ($ProjectPath) { Write-Step "using remembered project: $ProjectPath" }
}

$editors = @(Get-GodotEditors)
if (-not $ProjectPath) {
    $open = $editors | Where-Object { $_.IsEditor } | Select-Object -First 1
    if ($open) {
        $ProjectPath = $open.ProjectPath
        Write-Step "using the open editor's project: $ProjectPath"
    }
}
if (-not $ProjectPath) {
    Fail "No project to prepare. Pass -ProjectPath <dir>." @("or run -Create -ProjectPath <dir> for a new project") 1
}
if (-not (Test-Path -LiteralPath $ProjectPath)) { Fail "Project path does not exist: $ProjectPath" @() 1 }
$proj = (Resolve-Path -LiteralPath $ProjectPath).Path

# -------------------------------------------------------------- 2. http service

if (Test-PortListening -Port $servicePort) {
    Write-Step "service: listening on $servicePort"
}
else {
    Write-Step "service: not listening - starting godot-mcp-service.cmd"
    $svc = Join-Path $PSScriptRoot 'godot-mcp-service.cmd'
    if (-not (Test-Path -LiteralPath $svc)) { Fail "Missing the launcher: $svc" @("re-run the installer so scripts\ is complete") 5 }

    # Fail fast with an actionable message instead of waiting out the timeout.
    $serverFound = $env:GODOT_MCP_SERVER_EXE -or
        (Get-Command 'godot-editor-mcp' -ErrorAction SilentlyContinue) -or
        (Test-Path -LiteralPath (Join-Path $env:USERPROFILE '.local\bin\godot-editor-mcp.exe'))
    if (-not $serverFound) {
        Fail "godot-editor-mcp is not installed." @("install it:   uv tool install godot-editor-mcp", "no uv yet?    winget install --id=astral-sh.uv -e", "or point GODOT_MCP_SERVER_EXE at the exe") 5
    }

    Start-Process -FilePath 'cmd.exe' -ArgumentList "/c `"$svc`"" -WindowStyle Hidden | Out-Null
    $deadline = (Get-Date).AddSeconds(40)
    while ((Get-Date) -lt $deadline -and -not (Test-PortListening -Port $servicePort)) {
        Start-Sleep -Milliseconds 500
    }
    if (-not (Test-PortListening -Port $servicePort)) { Fail "The service did not come up on port $servicePort." @("log: $env:LOCALAPPDATA\godot-mcp\service-starts.log", "the usual cause is a missing godot-editor-mcp or a port already in use") 5 }
    Write-Step "service: up"
}

# ------------------------------------------------------- 3. addon + plugin + probe

$addonCfg = Join-Path $proj 'addons\godot_mcp\plugin.cfg'
$projFile = Join-Path $proj 'project.godot'
$hadAddon = Test-Path -LiteralPath $addonCfg
$hadPlugin = $false
if (Test-Path -LiteralPath $projFile) {
    $hadPlugin = @(Select-String -LiteralPath $projFile -SimpleMatch 'godot_mcp/plugin.cfg').Count -gt 0
}
$needsRestart = (-not $hadAddon) -or (-not $hadPlugin)

$prep = Join-Path $PSScriptRoot 'godot-new-project.ps1'
& $prep -ProjectPath $proj -AddonSource $AddonSource | ForEach-Object { Write-Host "    $_" }

New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
[System.IO.File]::WriteAllText($lastFile, $proj, (New-Object System.Text.UTF8Encoding($false)))

if ($NoLaunch) {
    Write-Host ""
    Write-Step "PREPARED (not launched) - $proj"
    # Say now whether the editor can be found. The first run on a fresh machine
    # is often -NoLaunch, and discovering two steps later that Godot is in a
    # place this script does not look is a bad surprise.
    $detected = Find-GodotExe
    if ($detected) {
        Write-Step "godot: $detected"
    }
    else {
        Write-Step "godot: NOT FOUND - the next run cannot launch the editor"
        Write-Step "       pass -GodotExe, set GODOT_BIN, or put Godot on PATH"
    }
    exit 0
}

# ------------------------------------------------------------------ 4. an editor

$mine = $editors | Where-Object { $_.IsEditor -and ($_.ProjectPath -ieq $proj) } | Select-Object -First 1
$other = $editors | Where-Object { $_.IsEditor -and ($_.ProjectPath -ine $proj) }

$mine = @($editors | Where-Object { $_.IsEditor -and ($_.ProjectPath -ieq $proj) })
$other = @($editors | Where-Object { $_.IsEditor -and ($_.ProjectPath -ine $proj) })

if ($mine.Count -gt 1) {
    # Two windows on one project fight over the same files. Keep going, but say so.
    Write-Step "WARNING: $($mine.Count) editors are open on this project (pids $($mine.OwnerPid -join ', '))"
}

if ($mine.Count -ge 1 -and $needsRestart) {
    if (-not $Restart) {
        Write-Host ""
        Write-Step "NEEDS A RELOAD: the addon/plugin was just added, and Godot reads [editor_plugins] only at startup."
        Write-Step "re-run with -Restart (loses unsaved work), or use Project > Reload Current Project."
        exit 2
    }
    foreach ($m in $mine) {
        Write-Step "restarting editor (pid $($m.OwnerPid))"
        Stop-Process -Id $m.OwnerPid -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 2
    Start-Editor -Project $proj -Exe (Resolve-GodotExe)
}
elseif ($mine.Count -eq 0) {
    if ($other.Count -gt 0) {
        # One editor owns the bridge - but only if it is actually attached to THIS
        # bridge port. A second service on another port is a supported setup, and
        # an editor that never connected is not an owner either; blocking for those
        # claims a conflict that does not exist.
        $attached = @(
            Get-NetTCPConnection -RemotePort $bridgePort -State Established -ErrorAction SilentlyContinue |
                ForEach-Object { $_.OwningProcess }
        )
        $racing = @($other | Where-Object {
                if ($attached -contains $_.OwnerPid) { return $true }
                # A window that started seconds ago may not have dialled yet.
                $p = Get-Process -Id $_.OwnerPid -ErrorAction SilentlyContinue
                return ($p -and $p.StartTime -gt (Get-Date).AddSeconds(-20))
            })
        if ($racing.Count -gt 0) {
            if (-not $Restart) {
                Write-Host ""
                Write-Step "BLOCKED: an editor is already open on a different project:"
                Write-Step "  $($racing[0].ProjectPath)"
                Write-Step "one editor owns bridge port $bridgePort. Close it, or re-run with -Restart (loses unsaved work)."
                exit 4
            }
            foreach ($o in $racing) {
                Write-Step "closing editor on $($o.ProjectPath) (pid $($o.OwnerPid))"
                Stop-Process -Id $o.OwnerPid -Force -ErrorAction SilentlyContinue
            }
            Start-Sleep -Seconds 2
        }
        else {
            Write-Step "another editor is open but not attached to bridge port $bridgePort - continuing"
        }
    }
    Start-Editor -Project $proj -Exe (Resolve-GodotExe)
}

# ------------------------------------------------------------------ 5. wait

# Wait for ANY editor on this project to own a bridge connection, not one pinned
# PID: a freshly launched process can take a moment to appear, and a lingering
# second window would otherwise be waited on forever.
$deadline = (Get-Date).AddSeconds($TimeoutSec)
$connected = $false
while ((Get-Date) -lt $deadline) {
    $pids = @(
        Get-GodotEditors |
            Where-Object { $_.IsEditor -and ($_.ProjectPath -ieq $proj) } |
            ForEach-Object { $_.OwnerPid }
    )
    if ($pids.Count -gt 0) {
        $conns = @(Get-NetTCPConnection -RemotePort $bridgePort -State Established -ErrorAction SilentlyContinue)
        foreach ($c in $conns) {
            if ($pids -contains $c.OwningProcess) { $connected = $true; break }
        }
        if ($connected) { break }
    }
    Start-Sleep -Milliseconds 750
}

New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
[System.IO.File]::WriteAllText($lastFile, $proj, (New-Object System.Text.UTF8Encoding($false)))

Write-Host ""
if ($connected) {
    Write-Step "BRIDGE CONNECTED - $proj is ready for godot MCP tools"
    exit 0
}

Write-Step "BRIDGE NOT CONNECTED after ${TimeoutSec}s - $proj"
Write-Step "check: is the addon enabled in Project > Project Settings > Plugins, and is this project the one the editor has open?"
exit 3
