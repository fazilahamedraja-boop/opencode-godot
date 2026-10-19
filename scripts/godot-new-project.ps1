<#
.SYNOPSIS
    Prepare a Godot project for prompt-driven authoring through the Godot Editor MCP.

.DESCRIPTION
    New Godot projects need three things before any Godot MCP tool can do work:
    the addon files, the plugin enabled in project.godot, and the MCPRuntimeProbe
    autoload registered. By hand that is a copy, a manual tick in Project Settings,
    and two edits -- per project. This does all three in one command.

    Idempotent: running it again on an already-prepared project changes nothing.

.PARAMETER ProjectPath
    Directory containing project.godot.

.PARAMETER AddonSource
    Canonical addon copy (must contain plugin.cfg and mcp_runtime_probe.gd).

.EXAMPLE
    & "$env:USERPROFILE\.config\opencode\scripts\godot-new-project.ps1" -ProjectPath "C:\Users\me\games\my-new-game"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$ProjectPath,

    [string]$AddonSource
)

$ErrorActionPreference = 'Stop'

# The canonical addon copy ships beside this script (..\addon\godot_mcp).
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
if (-not $AddonSource) {
    throw "Addon source not found. Pass -AddonSource <path to godot_mcp> (it must contain plugin.cfg)."
}

function Get-SectionBounds {
    # Returns the [start, end) line span of a "[Header]" section, or $null.
    param([string[]]$Lines, [string]$Header)
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i].Trim() -eq $Header) {
            $end = $Lines.Count
            for ($j = $i + 1; $j -lt $Lines.Count; $j++) {
                if ($Lines[$j].TrimStart().StartsWith('[')) { $end = $j; break }
            }
            return @{ Start = $i; End = $end }
        }
    }
    return $null
}

function Add-ProjectEntry {
    # Inserts "Key=..." under [Section], creating the section if needed.
    param([string]$Text, [string]$Section, [string]$Key, [string]$Entry)

    if ($Text -match ('(?m)^\s*' + [regex]::Escape($Key) + '\s*=')) {
        return $Text   # already present
    }

    $lines = @($Text -split "`r?`n")
    $bounds = Get-SectionBounds -Lines $lines -Header "[$Section]"

    if ($bounds -ne $null) {
        $head = @($lines[0..$bounds.Start])
        $tail = @()
        if ($bounds.End -lt $lines.Count) { $tail = @($lines[$bounds.End..($lines.Count - 1)]) }
        $lines = @($head) + @($Entry) + $tail
    }
    else {
        if ($lines.Count -gt 0 -and $lines[$lines.Count - 1].Trim() -ne '') { $lines += '' }
        $lines += "[$Section]"
        $lines += $Entry
    }
    return ($lines -join "`r`n")
}

function Enable-EditorPlugin {
    # Appends our path to an existing enabled=PackedStringArray(...) or creates one.
    param([string]$Text, [string]$PluginPath)

    if ($Text -match [regex]::Escape($PluginPath)) { return $Text }

    $pattern = '(?m)^(\s*enabled\s*=\s*PackedStringArray\()([^)]*)(\))'
    $m = [regex]::Match($Text, $pattern)
    if ($m.Success) {
        $inner = $m.Groups[2].Value.Trim()
        $sep = ''
        if ($inner.Length -gt 0) { $sep = ', ' }
        $replacement = '${1}' + $inner + $sep + '"' + $PluginPath + '"' + '${3}'
        return ([regex]::new($pattern)).Replace($Text, $replacement, 1)
    }
    return Add-ProjectEntry -Text $Text -Section 'editor_plugins' -Key 'enabled' `
        -Entry ('enabled=PackedStringArray("' + $PluginPath + '")')
}

# ---------------------------------------------------------------- main

$projectPath = (Resolve-Path -LiteralPath $ProjectPath).Path
$projectFile = Join-Path $projectPath 'project.godot'

if (-not (Test-Path -LiteralPath $projectFile)) {
    throw "No project.godot in '$projectPath'."
}
if (-not (Test-Path -LiteralPath (Join-Path $AddonSource 'plugin.cfg'))) {
    throw "Addon source has no plugin.cfg: $AddonSource"
}
if (-not (Test-Path -LiteralPath (Join-Path $AddonSource 'mcp_runtime_probe.gd'))) {
    throw "Addon source has no mcp_runtime_probe.gd: $AddonSource"
}

Write-Host "project : $projectPath"
Write-Host "addon   : $AddonSource"

# 1. addon files
#    Skipped when the destination already matches, because godot-ensure.ps1 runs
#    this every session -- potentially against a project whose editor is OPEN.
#    Rewriting 107 files under a live editor triggers a rescan for no reason.
$dest = Join-Path $projectPath 'addons\godot_mcp'

$addonSourceFiles = @(
    Get-ChildItem -LiteralPath $AddonSource -Recurse -File |
        ForEach-Object { $_.FullName.Substring($AddonSource.Length).TrimStart('\') }
)

$inSync = Test-Path -LiteralPath $dest
if ($inSync) {
    foreach ($rel in $addonSourceFiles) {
        $destFile = Join-Path $dest $rel
        if (-not (Test-Path -LiteralPath $destFile)) { $inSync = $false; break }
        $srcHash = (Get-FileHash -LiteralPath (Join-Path $AddonSource $rel) -Algorithm SHA256).Hash
        $dstHash = (Get-FileHash -LiteralPath $destFile -Algorithm SHA256).Hash
        if ($srcHash -ne $dstHash) { $inSync = $false; break }
    }
}

if ($inSync) {
    Write-Host "addon   : up to date ($($addonSourceFiles.Count) files) -> addons\godot_mcp"
}
else {
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    Copy-Item -Path (Join-Path $AddonSource '*') -Destination $dest -Recurse -Force
    $fileCount = (Get-ChildItem -LiteralPath $dest -Recurse -File).Count
    Write-Host "addon   : copied $fileCount files -> addons\godot_mcp"
}

# 2. project.godot
$text = [System.IO.File]::ReadAllText($projectFile)
$before = $text

$text = Enable-EditorPlugin -Text $text -PluginPath 'res://addons/godot_mcp/plugin.cfg'
$text = Add-ProjectEntry -Text $text -Section 'autoload' -Key 'MCPRuntimeProbe' `
    -Entry 'MCPRuntimeProbe="*res://addons/godot_mcp/mcp_runtime_probe.gd"'

if ($text -ne $before) {
    $backup = "$projectFile.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Copy-Item -LiteralPath $projectFile -Destination $backup -Force
    [System.IO.File]::WriteAllText($projectFile, $text, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "config  : project.godot updated (backup: $(Split-Path $backup -Leaf))"
}
else {
    Write-Host "config  : project.godot already prepared"
}

Write-Host ""
Write-Host "Done. Addon, plugin and MCPRuntimeProbe are in place (idempotent)."
