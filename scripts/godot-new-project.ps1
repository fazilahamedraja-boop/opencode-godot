<#
.SYNOPSIS
    Prepare a Godot project for prompt-driven authoring through the Godot Editor MCP.

.DESCRIPTION
    New Godot projects need three things before any Godot MCP tool can do work:
    the addon files, the plugin enabled in project.godot, and the MCPRuntimeProbe
    autoload registered. By hand that is a copy, a manual tick in Project Settings,
    and two edits -- per project. This does all three in one command.

    Idempotent: running it again on an already-prepared project changes nothing.

    Upgrading: an addon file in the project that differs from the canonical copy
    is the user's, and is backed up as <name>.bak (then .bak.1, ...) before it is
    replaced, so a hand-edited handler is never lost. Only files that differ are
    rewritten -- a running editor rescans the addon otherwise. Files that no
    longer exist upstream are left alone: without a manifest this script cannot
    tell a user's file from an obsolete one.

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

function Get-Sha256 {
    # Deliberately NOT Get-FileHash. A PowerShell 7 session hands its PSModulePath
    # to the Windows PowerShell 5.1 child this often runs in; 5.1 then resolves
    # Microsoft.PowerShell.Utility from PS7's directory first, that Core assembly
    # does not load, and Get-FileHash disappears from the session - which killed
    # the addon comparison outright. The .NET hash API imports nothing and
    # returns the same uppercase hex. See install.ps1 for the full note.
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

function Save-Backup {
    # Preserve the current contents of a file before it is overwritten, under a
    # name that does not already exist: .bak, then .bak.1, .bak.2, ...
    #
    # Same contract as install.ps1's helper, duplicated on purpose: these scripts
    # ship standalone, so there is no module to share it from.
    #   * Never reuse a name, or the second upgrade silently replaces the first
    #     backup - and after a file has been edited twice the first backup is the
    #     only copy of the original left.
    #   * Copy to a ".partial" name and only then move it into place, so an
    #     interrupted copy cannot leave a truncated file that looks complete.
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
        $srcHash = Get-Sha256 -Path (Join-Path $AddonSource $rel)
        $dstHash = Get-Sha256 -Path $destFile
        if ($srcHash -ne $dstHash) { $inSync = $false; break }
    }
}

if ($inSync) {
    Write-Host "addon   : up to date ($($addonSourceFiles.Count) files) -> addons\godot_mcp"
}
else {
    New-Item -ItemType Directory -Force -Path $dest | Out-Null

    # Per file, not a whole-tree Copy-Item -Force. Two reasons:
    #   * A file that differs is the user's edit or an older upstream, and it is
    #     backed up before it is replaced. The bulk copy destroyed it instead.
    #   * Copy-Item -Force rewrites every file, so one damaged handler used to
    #     rewrite all of them under a running editor and trigger a full rescan.
    # Stale files (present here, gone upstream) are left alone, as in install.ps1:
    # without a manifest a user's own handler is indistinguishable from an obsolete
    # integration file.
    $backedUp = 0
    foreach ($rel in $addonSourceFiles) {
        $sourceFile = Join-Path $AddonSource $rel
        $destFile = Join-Path $dest $rel
        $destDir = Split-Path -Parent $destFile
        if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Force -Path $destDir | Out-Null }

        if (Test-Path -LiteralPath $destFile) {
            $srcHash = Get-Sha256 -Path $sourceFile
            $dstHash = Get-Sha256 -Path $destFile
            if ($srcHash -eq $dstHash) { continue }
            $null = Save-Backup -Path $destFile
            $backedUp++
        }
        Copy-Item -LiteralPath $sourceFile -Destination $destFile -Force
    }

    # Count only real addon files, so backups are not reported as provisioned code.
    $fileCount = @(
        Get-ChildItem -LiteralPath $dest -Recurse -File |
            Where-Object { $_.Name -notmatch '\.bak(\.\d+)?$' -and $_.Name -notmatch '\.partial$' }
    ).Count
    Write-Host "addon   : copied $fileCount files -> addons\godot_mcp"
    if ($backedUp -gt 0) {
        Write-Host "addon   : $backedUp replaced file(s) backed up as .bak"
    }
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
