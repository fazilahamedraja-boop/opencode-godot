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

function Test-PortListening {
    param([int]$Port)
    $c = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    return ($null -ne $c -and @($c).Count -gt 0)
}

function Get-GodotEditors {
    # Every Godot process launched with --path, flagged as editor or game.
    $result = @()
    $procs = Get-CimInstance Win32_Process -Filter "Name LIKE 'Godot%'" -ErrorAction SilentlyContinue
    foreach ($p in $procs) {
        $cl = $p.CommandLine
        if (-not $cl) { continue }
        if ($cl -notmatch '--path\s+(?:"([^"]+)"|(\S+))') { continue }
        $path = $Matches[1]
        if ([string]::IsNullOrEmpty($path)) { $path = $Matches[2] }
        $result += [pscustomobject]@{
            OwnerPid    = $p.ProcessId
            ProjectPath = ($path -replace '/', '\').TrimEnd('\')
            IsEditor    = ($cl -match '\s-e(ditor)?(\s|$)')
        }
    }
    return $result
}

function Resolve-GodotExe {
    if ($GodotExe) { return $GodotExe }
    if ($env:GODOT_BIN) { return $env:GODOT_BIN }

    # 1. on PATH (the console build prints CLI output, so prefer it)
    foreach ($name in @('godot_console', 'godot')) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cmd) { return $cmd.Source }
    }

    # 2. the usual manual-unzip places, newest build first
    $dirs = @(
        (Join-Path $env:USERPROFILE 'godot'),
        (Join-Path $env:LOCALAPPDATA 'Programs'),
        (Join-Path ${env:ProgramFiles} 'Godot')
    )
    foreach ($dir in $dirs) {
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        $hit = Get-ChildItem $dir -Filter 'Godot_v*-stable_win64*.exe' -Recurse -Depth 1 -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending | Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }

    throw "Godot editor exe not found. Put 'godot' on PATH, set GODOT_BIN, or pass -GodotExe <path>."
}

function Start-Editor {
    param([string]$Project, [string]$Exe)
    Write-Step "launching editor: $Project"
    Start-Process -FilePath $Exe -ArgumentList ("--path `"$Project`" -e") | Out-Null
}

# ------------------------------------------------------------------ 1. project

if ($Create) {
    if (-not $ProjectPath) { throw "-Create needs -ProjectPath." }
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
    throw "No project to prepare. Pass -ProjectPath."
}
if (-not (Test-Path -LiteralPath $ProjectPath)) { throw "Project path does not exist: $ProjectPath" }
$proj = (Resolve-Path -LiteralPath $ProjectPath).Path

# -------------------------------------------------------------- 2. http service

if (Test-PortListening -Port $servicePort) {
    Write-Step "service: listening on $servicePort"
}
else {
    Write-Step "service: not listening - starting godot-mcp-service.cmd"
    $svc = Join-Path $PSScriptRoot 'godot-mcp-service.cmd'
    if (-not (Test-Path -LiteralPath $svc)) { throw "Missing $svc" }

    # Fail fast with an actionable message instead of waiting out the timeout.
    $serverFound = $env:GODOT_MCP_SERVER_EXE -or
        (Get-Command 'godot-editor-mcp' -ErrorAction SilentlyContinue) -or
        (Test-Path -LiteralPath (Join-Path $env:USERPROFILE '.local\bin\godot-editor-mcp.exe'))
    if (-not $serverFound) {
        throw "godot-editor-mcp is not installed. Install it, then re-run:`n    uv tool install godot-editor-mcp`n(or set GODOT_MCP_SERVER_EXE to its full path.)"
    }

    Start-Process -FilePath 'cmd.exe' -ArgumentList "/c `"$svc`"" -WindowStyle Hidden | Out-Null
    $deadline = (Get-Date).AddSeconds(40)
    while ((Get-Date) -lt $deadline -and -not (Test-PortListening -Port $servicePort)) {
        Start-Sleep -Milliseconds 500
    }
    if (-not (Test-PortListening -Port $servicePort)) { throw "Service did not come up on $servicePort." }
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
        # One editor owns the bridge. Launching a second gives two addons on :9080
        # and the loser is silently dead, which looks like "the plugin is missing".
        if (-not $Restart) {
            Write-Host ""
            Write-Step "BLOCKED: an editor is already open on a different project:"
            Write-Step "  $($other[0].ProjectPath)"
            Write-Step "one editor owns bridge port $bridgePort. Close it, or re-run with -Restart (loses unsaved work)."
            exit 4
        }
        foreach ($o in $other) {
            Write-Step "closing editor on $($o.ProjectPath) (pid $($o.OwnerPid))"
            Stop-Process -Id $o.OwnerPid -Force -ErrorAction SilentlyContinue
        }
        Start-Sleep -Seconds 2
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
