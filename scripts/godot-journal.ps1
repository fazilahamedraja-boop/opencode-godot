<#
.SYNOPSIS
    Read or append the game-build journal, so game work survives sessions.

.DESCRIPTION
    Godot game work has no memory of its own: a new session knows nothing about
    which games exist, where they live, what the controls are, or what was left
    half-done. This is a plain append-only markdown file, deliberately not an LLM
    or a database, so reading it is free and deterministic.

        %USERPROFILE%\.config\opencode\games\journal.md

    Run with no arguments (or -Read) at the START of game work; pass -Append at
    the END. One entry per build/edit, newest last.

.PARAMETER Read
    Print the most recent entries. This is the default action.

.PARAMETER Tail
    How many entries to print with -Read (default 10).

.PARAMETER Append
    Append one entry. Requires -Game; the rest are optional.

.PARAMETER Project
    Absolute project directory.

.PARAMETER Game
    Short game name, e.g. "Gem Rush".

.PARAMETER Scene
    Scene the game lives in, e.g. "res://gem_rush.tscn".

.PARAMETER Controls
    Input the player uses.

.PARAMETER Status
    Free text, e.g. "built, not play-tested".

.PARAMETER Next
    What to do next time.

.EXAMPLE
    & "$env:USERPROFILE\.config\opencode\scripts\godot-journal.ps1"

.EXAMPLE
    & "$env:USERPROFILE\.config\opencode\scripts\godot-journal.ps1" -Append -Game "Gem Rush" `
        -Project "C:\games\gem" -Scene "res://gem_rush.tscn" -Controls "ui_*" -Status "built" -Next "add a timer"
#>
[CmdletBinding(DefaultParameterSetName = 'Read')]
param(
    [Parameter(ParameterSetName = 'Read')]
    [switch]$Read,

    [Parameter(ParameterSetName = 'Read')]
    [int]$Tail = 10,

    [Parameter(ParameterSetName = 'Append', Mandatory = $true)]
    [switch]$Append,

    [Parameter(ParameterSetName = 'Append')]
    [string]$Project,

    [Parameter(ParameterSetName = 'Append', Mandatory = $true)]
    [string]$Game,

    [Parameter(ParameterSetName = 'Append')]
    [string]$Scene,

    [Parameter(ParameterSetName = 'Append')]
    [string]$Controls,

    [Parameter(ParameterSetName = 'Append')]
    [string]$Status = 'built',

    [Parameter(ParameterSetName = 'Append')]
    [string]$Next
)

$ErrorActionPreference = 'Stop'

$dir = if ($env:OPENCODE_GAMES_DIR) {
    $env:OPENCODE_GAMES_DIR
} else {
    Join-Path $env:USERPROFILE '.config\opencode\games'
}
$file = Join-Path $dir 'journal.md'

if ($Append) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null

    if (-not (Test-Path -LiteralPath $file)) {
        $header = @(
            '# Game journal'
            ''
            'One entry per build or edit, newest last. Written by godot-journal.ps1.'
            ''
        ) -join "`r`n"
        [System.IO.File]::WriteAllText($file, $header, (New-Object System.Text.UTF8Encoding($false)))
    }

    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm'
    $block = New-Object System.Collections.Generic.List[string]
    $block.Add("")
    $block.Add("## $stamp - $Game")
    if ($Project) { $block.Add("- project: $Project") }
    if ($Scene) { $block.Add("- scene: $Scene") }
    if ($Controls) { $block.Add("- controls: $Controls") }
    $block.Add("- status: $Status")
    if ($Next) { $block.Add("- next: $Next") }

    Add-Content -LiteralPath $file -Value ($block -join "`r`n") -Encoding UTF8
    Write-Host "journal: appended '$Game'"
    exit 0
}

if (-not (Test-Path -LiteralPath $file)) {
    Write-Host "journal: empty (no game has been recorded yet)"
    Write-Host "         file will be created at $file"
    exit 0
}

$raw = [System.IO.File]::ReadAllText($file)
$entries = @([regex]::Split($raw, '(?m)^## ') | Where-Object { $_.Trim() -ne '' })
$preamble = $entries[0]
$body = @($entries | Select-Object -Skip 1)
$take = [Math]::Min($Tail, $body.Count)

if ($take -eq 0) {
    Write-Host "journal: no entries yet ($file)"
    exit 0
}

Write-Host "journal: $($body.Count) entries, showing the last $take"
foreach ($e in @($body | Select-Object -Last $take)) { Write-Host ""; Write-Host ("## " + $e.TrimEnd()) }
exit 0
