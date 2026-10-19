<#
.SYNOPSIS
    Remove the opencode -> Godot workflow installed by install.ps1.

.DESCRIPTION
    Deletes the scripts, skill, command and addon copy that install.ps1 placed in
    the opencode config, plus the logon shortcut. It does NOT touch:

      - your game journal (games\journal.md) - that is your work
      - addons copied into your own Godot projects (remove those from the project)
      - the godot-editor-mcp PyPI package (uv tool uninstall godot-editor-mcp)
      - the "godot" entry in opencode.json - printed instead, since editing your
        config on the way out is a good way to break it

.PARAMETER ConfigRoot
    Same value you installed with. Defaults to %USERPROFILE%\.config\opencode.

.PARAMETER KeepAddon
    Leave the installed addon copy in place (e.g. another project still uses it).

.EXAMPLE
    .\uninstall.ps1
#>
[CmdletBinding()]
param(
    [string]$ConfigRoot = (Join-Path $env:USERPROFILE '.config\opencode'),
    [switch]$KeepAddon
)

$ErrorActionPreference = 'Stop'

function Say { param([string]$Text, [string]$Color = 'Gray') Write-Host $Text -ForegroundColor $Color }

function Remove-Target {
    param([string]$Path, [string]$Label)
    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Recurse -Force
        Say ("  - {0}" -f $Label) 'Yellow'
    }
    else { Say ("  = {0} (not installed)" -f $Label) }
}

Say ''
Say 'opencode-godot uninstall' 'Cyan'
Say ("  target : {0}" -f $ConfigRoot)
Say ''

function Remove-EmptyDir {
    param([string]$Path)
    if ((Test-Path -LiteralPath $Path) -and -not (Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue)) {
        Remove-Item -LiteralPath $Path -Force
        Say ("  - {0}\ (empty)" -f (Split-Path -Leaf $Path)) 'DarkGray'
    }
}

Say 'Files' 'Cyan'
foreach ($s in @(
        'godot-ensure.ps1',
        'godot-new-project.ps1',
        'godot-journal.ps1',
        'godot-mcp-service.cmd',
        'godot-mcp-service.vbs',
        'godot-mcp-probe.mjs'
    )) {
    Remove-Target -Path (Join-Path $ConfigRoot "scripts\$s") -Label "scripts\$s"
}
Remove-Target -Path (Join-Path $ConfigRoot 'skills\godot-game-by-prompt') -Label 'skills\godot-game-by-prompt'
Remove-Target -Path (Join-Path $ConfigRoot 'commands\game.md') -Label 'commands\game.md'
if (-not $KeepAddon) {
    Remove-Target -Path (Join-Path $ConfigRoot 'godot-mcp-addon') -Label 'godot-mcp-addon'
}
Remove-EmptyDir -Path (Join-Path $ConfigRoot 'scripts')

# Only remove the logon shortcut if it points at THIS install. Deleting another
# install's autostart because you uninstalled a test copy is not acceptable.
$vbs = Join-Path ([Environment]::GetFolderPath('Startup')) 'godot-mcp-service.vbs'
if (Test-Path -LiteralPath $vbs) {
    $content = Get-Content -LiteralPath $vbs -Raw
    if ($content -like "*$ConfigRoot*") {
        Remove-Target -Path $vbs -Label 'Startup\godot-mcp-service.vbs'
    }
    else {
        Say '  = Startup\godot-mcp-service.vbs (points at another install - left alone)'
    }
}

Say ''
Say 'Kept on purpose' 'Cyan'
Say ("  journal      : {0}" -f (Join-Path $ConfigRoot 'games\journal.md')) 'DarkGray'
Say '  project addons: remove addons\godot_mcp from each Godot project if you want them gone' 'DarkGray'
Say '  service exe  : uv tool uninstall godot-editor-mcp' 'DarkGray'
Say ''
Say 'In opencode.json, delete this entry if you added it:' 'Yellow'
Say '    "godot": { "type": "remote", "url": "http://127.0.0.1:9090/mcp" }' 'DarkGray'
Say ''
