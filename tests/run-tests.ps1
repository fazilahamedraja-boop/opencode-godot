<#
.SYNOPSIS
    Regression suite for the installer, the opencode.json patcher, addon
    provisioning and the uninstaller.

.DESCRIPTION
    Runs the REAL scripts, each test in its own throwaway directory, and asserts
    on the files written, the JSON produced, the exit code and the output.

    Nothing outside the temp tree is written; the run ends with an isolation
    audit that compares the real integration-owned files and the bridge ports
    before and after.

    Faked external dependencies (never the behaviour under test):
      * GODOT_MCP_SERVER_EXE -> a dummy file. The installer only Test-Path's it
        and, with -NoService, never executes it.
      * GODOT_MCP_HTTP_PORT  -> a port number that is never bound, because every
        install runs with -NoService.

    Written for Windows PowerShell 5.1 (the version users have) and also runs
    under PowerShell 7. No Pester dependency.

.PARAMETER RepoRoot
    Checkout to test. Defaults to the parent of tests\, or $env:OG_REPO_ROOT.

.PARAMETER Filter
    Only run tests whose name matches this wildcard, e.g. '*uninstall*'.

.PARAMETER KeepArtifacts
    Keep the temp tree instead of deleting it.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-tests.ps1

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-tests.ps1 -Filter '*addon*'
#>
[CmdletBinding()]
param(
    [string]$RepoRoot,
    [string]$Filter = '*',
    [switch]$KeepArtifacts
)

$ErrorActionPreference = 'Stop'

if (-not $RepoRoot) {
    $RepoRoot = if ($env:OG_REPO_ROOT) { $env:OG_REPO_ROOT } else { Split-Path -Parent $PSScriptRoot }
}
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path

foreach ($required in @(
        'install.ps1', 'install.cmd', 'uninstall.ps1', 'uninstall.cmd',
        'scripts\godot-new-project.ps1', 'addon\godot_mcp\plugin.cfg')) {
    if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot $required))) {
        throw "Not a full checkout of opencode-godot: missing $required under $RepoRoot"
    }
}

$script:Root = Join-Path $env:TEMP ('og-tests-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $script:Root | Out-Null

$script:Index = 0
$script:Passed = 0
$script:Failures = New-Object System.Collections.ArrayList
$script:Sentinel = [datetime]'2001-01-01T00:00:00Z'

# ------------------------------------------------------------------ helpers

function Get-Sha {
    param([string]$Path)
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Get-Tail {
    param([string]$Text, [int]$Lines = 15)
    if (-not $Text) { return '<no output>' }
    $all = @($Text -split "`r?`n" | Where-Object { $_ -ne '' })
    if ($all.Count -le $Lines) { return ($all -join ' | ') }
    return (($all | Select-Object -Last $Lines) -join ' | ')
}

function Fail {
    param([string]$Message)
    throw $Message
}

function Assert-True {
    param($Condition, [string]$Message)
    if (-not $Condition) { Fail $Message }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ($Expected -ne $Actual) {
        Fail ("{0}`n      expected: {1}`n      actual  : {2}" -f $Message, $Expected, $Actual)
    }
}

function Assert-Match {
    param([string]$Pattern, [string]$Text, [string]$Message)
    if (-not ($Text -match $Pattern)) {
        Fail ("{0}`n      pattern not found: {1}`n      output: {2}" -f $Message, $Pattern, (Get-Tail $Text))
    }
}

function Assert-NotMatch {
    param([string]$Pattern, [string]$Text, [string]$Message)
    if ($Text -match $Pattern) {
        Fail ("{0}`n      unexpected match: {1}`n      output: {2}" -f $Message, $Pattern, (Get-Tail $Text))
    }
}

function Assert-Exists {
    param([string]$Path, [string]$Message)
    if (-not (Test-Path -LiteralPath $Path)) { Fail ("{0}`n      missing: {1}" -f $Message, $Path) }
}

function Assert-Missing {
    param([string]$Path, [string]$Message)
    if (Test-Path -LiteralPath $Path) { Fail ("{0}`n      still there: {1}" -f $Message, $Path) }
}

function ConvertFrom-JsonFile {
    param([string]$Path)
    $raw = Get-Content -LiteralPath $Path -Raw
    try { return ($raw | ConvertFrom-Json) }
    catch { Fail ("{0} is not valid JSON: {1}" -f $Path, $_.Exception.Message) }
}

<#
    Run a script as a child process so its exit code is real and its output is
    captured. Environment values are applied for this call only and always
    restored, including removal of variables that were absent before.
#>
function Invoke-Og {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string[]]$Arguments = @(),
        [hashtable]$Environment = @{},
        [switch]$ViaCmd
    )

    $saved = @{}
    foreach ($key in $Environment.Keys) {
        $saved[$key] = [Environment]::GetEnvironmentVariable($key, 'Process')
        [Environment]::SetEnvironmentVariable($key, [string]$Environment[$key], 'Process')
    }
    $previousPreference = $ErrorActionPreference
    $code = $null
    $output = ''
    try {
        if ($ViaCmd) {
            $exe = Join-Path $env:WINDIR 'System32\cmd.exe'
            $argv = @('/c', $Path) + $Arguments
        }
        else {
            $exe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
            if (-not (Test-Path -LiteralPath $exe)) { Fail "Windows PowerShell not found at $exe" }
            $argv = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Path) + $Arguments
        }
        # A child that writes to stderr must not abort the harness: under
        # ErrorActionPreference=Stop, PS 5.1 turns redirected native stderr into
        # a terminating NativeCommandError. Capture it and read the exit code.
        $ErrorActionPreference = 'Continue'
        $output = (& $exe @argv 2>&1 | Out-String)
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousPreference
        foreach ($key in $Environment.Keys) {
            [Environment]::SetEnvironmentVariable($key, $saved[$key], 'Process')
        }
    }
    [pscustomobject]@{ ExitCode = $code; Output = $output }
}

function New-StubServer {
    param([string]$Dir)
    $path = Join-Path $Dir 'tools\godot-editor-mcp.exe'
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
    [System.IO.File]::WriteAllText($path, 'stub - never executed')
    $path
}

<#
    Every install gets the same isolation: a private HOME for the uv/server
    fallback lookups, a fixed port that is never bound, and the stub server.
#>
function Get-InstallEnv {
    param([string]$UserHome, [string]$ServerExe)
    if (-not $ServerExe) { $ServerExe = '' }
    @{
        USERPROFILE          = $UserHome
        GODOT_MCP_HTTP_PORT  = '9599'
        GODOT_MCP_SERVER_EXE = $ServerExe
    }
}

function Get-MinimalPath {
    @(
        (Join-Path $env:WINDIR 'System32'),
        (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0'),
        (Join-Path $env:WINDIR 'System32\Wbem')
    ) -join ';'
}

function Get-TreeHashes {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @('__missing__') }
    @(Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue |
        Sort-Object FullName |
        ForEach-Object { $_.FullName.Substring($Path.Length) + '|' + (Get-Sha $_.FullName) })
}

# ------------------------------------------------------------------ runner

function Test-Case {
    param([string]$Name, [scriptblock]$Body)

    if ($Name -notlike $Filter) { return }

    $script:Index++
    $slug = ($Name -replace '[^A-Za-z0-9-]+', '-').Trim('-')
    $dir = Join-Path $script:Root ('{0:d2}-{1}' -f $script:Index, $slug)
    New-Item -ItemType Directory -Force -Path $dir | Out-Null

    Write-Host ''
    Write-Host ("[{0}] {1}" -f $script:Index, $Name) -ForegroundColor Cyan
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        & $Body $dir
        $watch.Stop()
        $script:Passed++
        Write-Host ("      PASS  ({0:N2}s)" -f $watch.Elapsed.TotalSeconds) -ForegroundColor Green
    }
    catch {
        $watch.Stop()
        $message = $_.Exception.Message
        $null = $script:Failures.Add([pscustomobject]@{ Name = $Name; Message = $message })
        Write-Host ("      FAIL  ({0:N2}s)" -f $watch.Elapsed.TotalSeconds) -ForegroundColor Red
        foreach ($line in ($message -split "`r?`n")) {
            Write-Host ('        ' + $line) -ForegroundColor Red
        }
        if ($env:GITHUB_ACTIONS -eq 'true') {
            # Surface the failing test in the run summary, not just the log tail.
            $safe = $message.Replace('%', '%25').Replace("`r`n", '%0A').Replace("`n", '%0A')
            Write-Host ("::error title={0}::{1}" -f $Name, $safe)
        }
    }
    finally {
        if (-not $KeepArtifacts) {
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# ------------------------------------------------------------------ the real surface to protect

$realConfig = Join-Path $env:USERPROFILE '.config\opencode'
$startupDir = try { [Environment]::GetFolderPath('Startup') } catch { '' }
$startupVbs = if ($startupDir) { Join-Path $startupDir 'godot-mcp-service.vbs' } else { '' }

$protectedPaths = @(
    (Join-Path $realConfig 'opencode.json'),
    (Join-Path $realConfig 'scripts'),
    (Join-Path $realConfig 'skills\godot-game-by-prompt'),
    (Join-Path $realConfig 'commands\game.md'),
    (Join-Path $realConfig 'godot-mcp-addon')
) + @($startupVbs) | Where-Object { $_ }

$protectedBefore = @{}
foreach ($p in $protectedPaths) {
    if (Test-Path -LiteralPath $p -PathType Container) { $protectedBefore[$p] = (Get-TreeHashes $p) -join "`n" }
    elseif (Test-Path -LiteralPath $p) { $protectedBefore[$p] = Get-Sha $p }
    else { $protectedBefore[$p] = '__missing__' }
}

function Get-BridgeListeners {
    try {
        @(Get-NetTCPConnection -State Listen -ErrorAction Stop |
            Where-Object { $_.LocalPort -in 9090, 9080 } |
            Sort-Object LocalPort, OwningProcess |
            ForEach-Object { "$($_.LocalAddress):$($_.LocalPort)/$($_.OwningProcess)" })
    }
    catch { @() }
}
$listenersBefore = (Get-BridgeListeners) -join ';'

Write-Host ''
Write-Host 'opencode-godot regression tests' -ForegroundColor White
Write-Host ("  repo    : {0}" -f $RepoRoot)
Write-Host ("  temp    : {0}" -f $script:Root)
Write-Host ("  host    : Windows PowerShell {0}" -f $PSVersionTable.PSVersion)
Write-Host ("  filter  : {0}" -f $Filter)

# ================================================================== tests

Test-Case 'install creates opencode.json when none exists' {
    param($dir)

    $fakeHome = Join-Path $dir 'home'
    New-Item -ItemType Directory -Force -Path $fakeHome | Out-Null
    $cfg = Join-Path $dir 'cfg'

    $r = Invoke-Og -Path (Join-Path $RepoRoot 'install.ps1') `
        -Arguments @('-ConfigRoot', $cfg, '-PatchOpencode', '-NoService', '-NoAutostart') `
        -Environment (Get-InstallEnv -UserHome $fakeHome -ServerExe (New-StubServer -Dir $dir))

    Assert-Equal 0 $r.ExitCode ("installer exited {0}: {1}" -f $r.ExitCode, (Get-Tail $r.Output))

    $cfgFile = Join-Path $cfg 'opencode.json'
    Assert-Exists $cfgFile 'opencode.json was not created'
    $json = ConvertFrom-JsonFile $cfgFile
    Assert-Equal 'remote' $json.mcp.godot.type 'the godot entry is not a remote server'
    Assert-Equal 'http://127.0.0.1:9599/mcp' $json.mcp.godot.url 'the godot url did not follow GODOT_MCP_HTTP_PORT'
    Assert-Match 'created with the "godot" remote server' $r.Output 'the installer never said it created the config'
    Assert-Missing "$cfgFile.bak-opencode-godot" 'a backup was written although there was nothing to back up'
}

Test-Case 'patching keeps unrelated configuration and backs up the original' {
    param($dir)

    $fakeHome = Join-Path $dir 'home'
    New-Item -ItemType Directory -Force -Path $fakeHome | Out-Null
    $cfg = Join-Path $dir 'cfg'
    New-Item -ItemType Directory -Force -Path $cfg | Out-Null

    $cfgFile = Join-Path $cfg 'opencode.json'
    $original = @'
{
  "$schema": "https://opencode.ai/config.json",
  "theme": "tokyonight",
  "model": "anthropic/claude-sonnet-4",
  "mcp": {
    "github": { "type": "remote", "url": "https://api.githubcopilot.com/mcp/" },
    "memory": {
      "type": "local",
      "command": ["npx", "-y", "@modelcontextprotocol/server-memory"],
      "enabled": true
    }
  }
}
'@
    [System.IO.File]::WriteAllText($cfgFile, $original, (New-Object System.Text.UTF8Encoding($false)))
    $before = Get-Sha $cfgFile

    $r = Invoke-Og -Path (Join-Path $RepoRoot 'install.ps1') `
        -Arguments @('-ConfigRoot', $cfg, '-PatchOpencode', '-NoService', '-NoAutostart') `
        -Environment (Get-InstallEnv -UserHome $fakeHome -ServerExe (New-StubServer -Dir $dir))

    Assert-Equal 0 $r.ExitCode ("installer exited {0}: {1}" -f $r.ExitCode, (Get-Tail $r.Output))
    Assert-Match 'added the "godot" remote server' $r.Output 'the installer did not report adding the entry'

    $json = ConvertFrom-JsonFile $cfgFile
    Assert-Equal 'tokyonight' $json.theme 'theme was not preserved'
    Assert-Equal 'anthropic/claude-sonnet-4' $json.model 'model was not preserved'
    Assert-Equal 'https://api.githubcopilot.com/mcp/' $json.mcp.github.url 'the github server was damaged'
    Assert-Equal 3 (@($json.mcp.memory.command)).Count 'the memory command array lost entries'
    Assert-Equal '@modelcontextprotocol/server-memory' (@($json.mcp.memory.command))[2] 'the memory command array was rewritten'
    Assert-Equal $true $json.mcp.memory.enabled 'the memory server lost its enabled flag'
    Assert-Equal 'http://127.0.0.1:9599/mcp' $json.mcp.godot.url 'the godot entry is missing or has the wrong url'

    $backup = "$cfgFile.bak-opencode-godot"
    Assert-Exists $backup 'the original config was not backed up'
    Assert-Equal $before (Get-Sha $backup) 'the backup is not byte-identical to the original'
}

Test-Case 'an existing godot url on the wrong port is corrected' {
    param($dir)

    $fakeHome = Join-Path $dir 'home'
    New-Item -ItemType Directory -Force -Path $fakeHome | Out-Null
    $cfg = Join-Path $dir 'cfg'
    New-Item -ItemType Directory -Force -Path $cfg | Out-Null

    $cfgFile = Join-Path $cfg 'opencode.json'
    $original = @'
{
  "theme": "tokyonight",
  "mcp": {
    "godot": { "type": "remote", "url": "http://127.0.0.1:9090/mcp" },
    "github": { "type": "remote", "url": "https://api.githubcopilot.com/mcp/" }
  }
}
'@
    [System.IO.File]::WriteAllText($cfgFile, $original, (New-Object System.Text.UTF8Encoding($false)))
    $before = Get-Sha $cfgFile

    $r = Invoke-Og -Path (Join-Path $RepoRoot 'install.ps1') `
        -Arguments @('-ConfigRoot', $cfg, '-PatchOpencode', '-NoService', '-NoAutostart') `
        -Environment (Get-InstallEnv -UserHome $fakeHome -ServerExe (New-StubServer -Dir $dir))

    Assert-Equal 0 $r.ExitCode ("installer exited {0}: {1}" -f $r.ExitCode, (Get-Tail $r.Output))
    Assert-Match 'updated "godot" -> http://127\.0\.0\.1:9599/mcp' $r.Output 'the installer did not report the port fix'

    $json = ConvertFrom-JsonFile $cfgFile
    Assert-Equal 'http://127.0.0.1:9599/mcp' $json.mcp.godot.url 'the url still points at the old port'
    Assert-Equal 'https://api.githubcopilot.com/mcp/' $json.mcp.github.url 'the github server was damaged'
    Assert-Equal 'tokyonight' $json.theme 'theme was not preserved'
    Assert-NotMatch '9090' (Get-Content -LiteralPath $cfgFile -Raw) 'the old port is still in the config'

    $backup = "$cfgFile.bak-opencode-godot"
    Assert-Exists $backup 'the original config was not backed up'
    Assert-Equal $before (Get-Sha $backup) 'the backup is not byte-identical to the original'
}

Test-Case 'without -PatchOpencode a wrong-port url is reported, not rewritten' {
    param($dir)

    $fakeHome = Join-Path $dir 'home'
    New-Item -ItemType Directory -Force -Path $fakeHome | Out-Null
    $cfg = Join-Path $dir 'cfg'
    New-Item -ItemType Directory -Force -Path $cfg | Out-Null

    $cfgFile = Join-Path $cfg 'opencode.json'
    $original = @'
{
  "mcp": {
    "godot": { "type": "remote", "url": "http://127.0.0.1:9090/mcp" }
  }
}
'@
    [System.IO.File]::WriteAllText($cfgFile, $original, (New-Object System.Text.UTF8Encoding($false)))
    $before = Get-Sha $cfgFile

    $r = Invoke-Og -Path (Join-Path $RepoRoot 'install.ps1') `
        -Arguments @('-ConfigRoot', $cfg, '-NoService', '-NoAutostart') `
        -Environment (Get-InstallEnv -UserHome $fakeHome -ServerExe (New-StubServer -Dir $dir))

    Assert-Equal 0 $r.ExitCode ("installer exited {0}: {1}" -f $r.ExitCode, (Get-Tail $r.Output))
    Assert-Match 'points at http://127\.0\.0\.1:9090/mcp, but the service is on http://127\.0\.0\.1:9599/mcp' $r.Output 'the mismatch was not reported'
    Assert-Match 're-run with -PatchOpencode' $r.Output 'the user was not told how to fix it'
    Assert-Equal $before (Get-Sha $cfgFile) 'the config was rewritten without -PatchOpencode'
    Assert-Missing "$cfgFile.bak-opencode-godot" 'a backup was written although nothing changed'
}

Test-Case 'a missing server fails honestly instead of pretending to succeed' {
    param($dir)

    $fakeHome = Join-Path $dir 'home'
    New-Item -ItemType Directory -Force -Path $fakeHome | Out-Null
    $cfg = Join-Path $dir 'cfg'

    $envMap = @{
        USERPROFILE          = $fakeHome
        GODOT_MCP_SERVER_EXE = ''
        GODOT_MCP_HTTP_PORT  = '9599'
        PATH                 = (Get-MinimalPath)
    }

    $r = Invoke-Og -Path (Join-Path $RepoRoot 'install.ps1') `
        -Arguments @('-ConfigRoot', $cfg, '-NoService', '-NoAutostart') `
        -Environment $envMap

    Assert-Equal 1 $r.ExitCode ("a missing server must exit 1, got {0}: {1}" -f $r.ExitCode, (Get-Tail $r.Output))
    Assert-Match 'mcp server : NOT INSTALLED' $r.Output 'the missing server was not named up front'
    Assert-Match 'winget install --id=astral-sh\.uv -e' $r.Output 'uv was not offered as the first step'
    Assert-Match 'NOT READY' $r.Output 'the run did not end with NOT READY'
    Assert-NotMatch 'Done\.' $r.Output 'the installer claimed success while the server is missing'
    Assert-NotMatch '(?m)^At line:|CategoryInfo' $r.Output 'the run crashed with a stack trace'

    # Files are installed anyway - only the service is missing.
    Assert-Exists (Join-Path $cfg 'scripts\godot-ensure.ps1') 'the workflow files were not installed'
    # The redirected HOME was only used for lookups; no file may be written there.
    # (powershell.exe creates %USERPROFILE%\AppData\Roaming on startup, so only
    # files count as evidence.)
    Assert-Equal 0 (@(Get-ChildItem -LiteralPath $fakeHome -Recurse -Force -File)).Count 'the installer wrote files into the fake HOME'
}

Test-Case 'a second install leaves identical files untouched' {
    param($dir)

    $fakeHome = Join-Path $dir 'home'
    New-Item -ItemType Directory -Force -Path $fakeHome | Out-Null
    $cfg = Join-Path $dir 'cfg'
    $envMap = Get-InstallEnv -UserHome $fakeHome -ServerExe (New-StubServer -Dir $dir)
    $install = Join-Path $RepoRoot 'install.ps1'
    $args = @('-ConfigRoot', $cfg, '-NoService', '-NoAutostart')

    $first = Invoke-Og -Path $install -Arguments $args -Environment $envMap
    Assert-Equal 0 $first.ExitCode ("first install exited {0}: {1}" -f $first.ExitCode, (Get-Tail $first.Output))

    # One file from each install path, including a nested addon file.
    $watched = @(
        (Join-Path $cfg 'scripts\godot-ensure.ps1'),
        (Join-Path $cfg 'skills\godot-game-by-prompt\SKILL.md'),
        (Join-Path $cfg 'godot-mcp-addon\godot_mcp\plugin.cfg'),
        (Join-Path $cfg 'godot-mcp-addon\godot_mcp\handlers\batch.gd')
    )
    $hashes = @{}
    foreach ($file in $watched) {
        Assert-Exists $file 'an expected installed file is missing'
        (Get-Item -LiteralPath $file).LastWriteTimeUtc = $script:Sentinel
        $hashes[$file] = Get-Sha $file
    }

    $second = Invoke-Og -Path $install -Arguments $args -Environment $envMap
    Assert-Equal 0 $second.ExitCode ("second install exited {0}: {1}" -f $second.ExitCode, (Get-Tail $second.Output))

    foreach ($file in $watched) {
        Assert-Equal $hashes[$file] (Get-Sha $file) "content changed on the second install: $file"
        $stamp = (Get-Item -LiteralPath $file).LastWriteTimeUtc.ToString('yyyy-MM-ddTHH:mm:ssZ')
        Assert-Equal '2001-01-01T00:00:00Z' $stamp "an identical file was rewritten: $file"
    }
    Assert-Match '(?m)^  = godot-mcp-addon\\godot_mcp' $second.Output 'the addon tree was not reported as unchanged'
    Assert-NotMatch '(?m)^  [+~] (scripts|skills|commands|godot-mcp-addon)\\' $second.Output 'the second install changed something'

    # A tampered addon file must be repaired, and only that file rewritten.
    $victim = Join-Path $cfg 'godot-mcp-addon\godot_mcp\type_coerce.gd'
    [System.IO.File]::AppendAllText($victim, "`n# tampered`n")
    $source = Join-Path $RepoRoot 'addon\godot_mcp\type_coerce.gd'

    $third = Invoke-Og -Path $install -Arguments $args -Environment $envMap
    Assert-Equal 0 $third.ExitCode ("repair install exited {0}: {1}" -f $third.ExitCode, (Get-Tail $third.Output))
    Assert-Equal (Get-Sha $source) (Get-Sha $victim) 'a modified addon file was not restored'
    Assert-Match '(?m)^  ~ godot-mcp-addon\\godot_mcp' $third.Output 'the addon repair was not reported'
    Assert-Equal '2001-01-01T00:00:00Z' (Get-Item -LiteralPath $watched[3]).LastWriteTimeUtc.ToString('yyyy-MM-ddTHH:mm:ssZ') `
        'the repair rewrote untouched neighbours'
}

Test-Case 'addon provisioning detects missing and modified files by hash' {
    param($dir)

    $proj = Join-Path $dir 'proj'
    New-Item -ItemType Directory -Force -Path $proj | Out-Null
    $projectFile = Join-Path $proj 'project.godot'
    [System.IO.File]::WriteAllText($projectFile, "config_version=5`r`n`r`n[application]`r`n`r`nconfig/name=`"test`"`r`n")

    $scene = Join-Path $proj 'scenes\main.tscn'
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $scene) | Out-Null
    [System.IO.File]::WriteAllText($scene, "[gd_scene format=3]`r`n")

    $addon = Join-Path $RepoRoot 'addon\godot_mcp'
    $sourceCount = @(Get-ChildItem -LiteralPath $addon -Recurse -File).Count
    $provision = Join-Path $RepoRoot 'scripts\godot-new-project.ps1'
    $args = @('-ProjectPath', $proj, '-AddonSource', $addon)

    $first = Invoke-Og -Path $provision -Arguments $args
    Assert-Equal 0 $first.ExitCode ("provisioning exited {0}: {1}" -f $first.ExitCode, (Get-Tail $first.Output))
    Assert-Match ([regex]::Escape("copied $sourceCount files")) $first.Output 'the addon was not copied'
    Assert-Equal $sourceCount (@(Get-ChildItem -LiteralPath (Join-Path $proj 'addons\godot_mcp') -Recurse -File)).Count 'wrong addon file count'

    $text = Get-Content -LiteralPath $projectFile -Raw
    Assert-Match 'enabled=PackedStringArray\("res://addons/godot_mcp/plugin\.cfg"\)' $text 'the plugin was not enabled'
    Assert-Match 'MCPRuntimeProbe="\*res://addons/godot_mcp/mcp_runtime_probe\.gd"' $text 'the runtime probe autoload was not registered'
    Assert-Exists $scene 'an unrelated project file was removed'
    Assert-Equal 1 (@(Get-ChildItem -LiteralPath $proj -Filter 'project.godot.bak-*')).Count 'the first run did not back up project.godot'

    $projectHash = Get-Sha $projectFile
    $plugin = Join-Path $proj 'addons\godot_mcp\plugin.cfg'
    $pluginStamp = (Get-Item -LiteralPath $plugin).LastWriteTimeUtc

    $second = Invoke-Og -Path $provision -Arguments $args
    Assert-Equal 0 $second.ExitCode ("second provisioning exited {0}: {1}" -f $second.ExitCode, (Get-Tail $second.Output))
    Assert-Match ([regex]::Escape("up to date ($sourceCount files)")) $second.Output 'the unchanged addon was not recognised'
    Assert-Match 'project.godot already prepared' $second.Output 'project.godot was edited again'
    Assert-Equal $pluginStamp (Get-Item -LiteralPath $plugin).LastWriteTimeUtc 'an unchanged addon file was rewritten'
    Assert-Equal 1 (@(Get-ChildItem -LiteralPath $proj -Filter 'project.godot.bak-*')).Count 'a second backup was written'

    # Damage one nested file and one top-level file.
    $nestedRel = 'addons\godot_mcp\handlers\batch.gd'
    $nested = Join-Path $proj $nestedRel
    Remove-Item -LiteralPath $nested -Force
    $tamperedRel = 'addons\godot_mcp\type_coerce.gd'
    $tampered = Join-Path $proj $tamperedRel
    [System.IO.File]::AppendAllText($tampered, "`n# tampered`n")

    $third = Invoke-Og -Path $provision -Arguments $args
    Assert-Equal 0 $third.ExitCode ("repair exited {0}: {1}" -f $third.ExitCode, (Get-Tail $third.Output))
    Assert-Match ([regex]::Escape("copied $sourceCount files")) $third.Output 'the damage was not detected'
    Assert-Equal (Get-Sha (Join-Path $addon 'handlers\batch.gd')) (Get-Sha $nested) 'the missing nested file was not restored'
    Assert-Equal (Get-Sha (Join-Path $addon 'type_coerce.gd')) (Get-Sha $tampered) 'the modified file was not restored'
    Assert-Equal $projectHash (Get-Sha $projectFile) 'project.godot was rewritten during the repair'
    Assert-Equal 1 (@(Get-ChildItem -LiteralPath $proj -Filter 'project.godot.bak-*')).Count 'the repair wrote another backup'
}

Test-Case 'uninstall removes only integration-owned files' {
    param($dir)

    $fakeHome = Join-Path $dir 'home'
    New-Item -ItemType Directory -Force -Path $fakeHome | Out-Null
    $cfg = Join-Path $dir 'cfg'
    $envMap = Get-InstallEnv -UserHome $fakeHome -ServerExe (New-StubServer -Dir $dir)

    $install = Invoke-Og -Path (Join-Path $RepoRoot 'install.ps1') `
        -Arguments @('-ConfigRoot', $cfg, '-PatchOpencode', '-NoService', '-NoAutostart') -Environment $envMap
    Assert-Equal 0 $install.ExitCode ("install exited {0}: {1}" -f $install.ExitCode, (Get-Tail $install.Output))

    # Things the integration does not own.
    $unrelated = @(
        (Join-Path $cfg 'games\journal.md'),
        (Join-Path $cfg 'skills\some-other-skill\SKILL.md'),
        (Join-Path $cfg 'commands\other.md'),
        (Join-Path $cfg 'plugins\mine.ts'),
        (Join-Path $cfg 'scripts\my-own-script.ps1'),
        (Join-Path $cfg 'notes.txt')
    )
    foreach ($file in $unrelated) {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $file) | Out-Null
        [System.IO.File]::WriteAllText($file, "user content`n")
    }

    $cfgFile = Join-Path $cfg 'opencode.json'
    $cfgHash = Get-Sha $cfgFile

    $r = Invoke-Og -Path (Join-Path $RepoRoot 'uninstall.ps1') -Arguments @('-ConfigRoot', $cfg)
    Assert-Equal 0 $r.ExitCode ("uninstall exited {0}: {1}" -f $r.ExitCode, (Get-Tail $r.Output))

    foreach ($owned in @(
            'scripts\godot-ensure.ps1', 'scripts\godot-doctor.ps1', 'scripts\godot-journal.ps1',
            'scripts\godot-mcp-service.cmd', 'scripts\godot-mcp-probe.mjs',
            'skills\godot-game-by-prompt\SKILL.md', 'commands\game.md',
            'godot-mcp-addon\godot_mcp\plugin.cfg')) {
        Assert-Missing (Join-Path $cfg $owned) "uninstall left an owned file behind: $owned"
    }

    foreach ($file in $unrelated) {
        Assert-Exists $file "uninstall removed a file it does not own: $file"
    }
    Assert-Equal $cfgHash (Get-Sha $cfgFile) 'uninstall edited opencode.json'

    $again = Invoke-Og -Path (Join-Path $RepoRoot 'uninstall.ps1') -Arguments @('-ConfigRoot', $cfg)
    Assert-Equal 0 $again.ExitCode ("a second uninstall should be a clean no-op, got {0}: {1}" -f $again.ExitCode, (Get-Tail $again.Output))
}

Test-Case 'a failed removal exits 1 and a clean one exits 0' {
    param($dir)

    $fakeHome = Join-Path $dir 'home'
    New-Item -ItemType Directory -Force -Path $fakeHome | Out-Null
    $cfg = Join-Path $dir 'cfg'

    $install = Invoke-Og -Path (Join-Path $RepoRoot 'install.ps1') `
        -Arguments @('-ConfigRoot', $cfg, '-NoService', '-NoAutostart') `
        -Environment (Get-InstallEnv -UserHome $fakeHome -ServerExe (New-StubServer -Dir $dir))
    Assert-Equal 0 $install.ExitCode ("install exited {0}: {1}" -f $install.ExitCode, (Get-Tail $install.Output))

    $locked = Join-Path $cfg 'scripts\godot-ensure.ps1'
    Assert-Exists $locked 'the file to lock is missing'

    $handle = [System.IO.File]::Open($locked, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
    try {
        $r = Invoke-Og -Path (Join-Path $RepoRoot 'uninstall.ps1') -Arguments @('-ConfigRoot', $cfg)
        Assert-Equal 1 $r.ExitCode ("a file that cannot be removed must make the exit code 1, got {0}: {1}" -f $r.ExitCode, (Get-Tail $r.Output))
        Assert-Match 'could not be removed' $r.Output 'the failure was not reported'
        Assert-Exists $locked 'the locked file disappeared anyway'
    }
    finally {
        $handle.Dispose()
    }

    $clean = Invoke-Og -Path (Join-Path $RepoRoot 'uninstall.ps1') -Arguments @('-ConfigRoot', $cfg)
    Assert-Equal 0 $clean.ExitCode ("uninstall exited {0}: {1}" -f $clean.ExitCode, (Get-Tail $clean.Output))
    Assert-Missing $locked 'the file survived a clean uninstall'
}

Test-Case 'the .cmd wrappers propagate the real exit code' {
    param($dir)

    $fakeHome = Join-Path $dir 'home'
    New-Item -ItemType Directory -Force -Path $fakeHome | Out-Null
    $cfg = Join-Path $dir 'cfg'

    $envMap = Get-InstallEnv -UserHome $fakeHome -ServerExe (New-StubServer -Dir $dir)
    $ok = Invoke-Og -Path (Join-Path $RepoRoot 'install.cmd') `
        -Arguments @('-ConfigRoot', $cfg, '-NoService', '-NoAutostart') -Environment $envMap -ViaCmd
    Assert-Equal 0 $ok.ExitCode ("install.cmd exited {0}: {1}" -f $ok.ExitCode, (Get-Tail $ok.Output))
    Assert-Exists (Join-Path $cfg 'scripts\godot-ensure.ps1') 'install.cmd did not install the files'

    $cfgMissing = Join-Path $dir 'cfg-missing'
    $failEnv = @{
        USERPROFILE          = $fakeHome
        GODOT_MCP_SERVER_EXE = ''
        GODOT_MCP_HTTP_PORT  = '9599'
        PATH                 = (Get-MinimalPath)
    }
    $fail = Invoke-Og -Path (Join-Path $RepoRoot 'install.cmd') `
        -Arguments @('-ConfigRoot', $cfgMissing, '-NoService', '-NoAutostart') -Environment $failEnv -ViaCmd
    Assert-Equal 1 $fail.ExitCode ("install.cmd hid a failure: got {0}: {1}" -f $fail.ExitCode, (Get-Tail $fail.Output))

    $remove = Invoke-Og -Path (Join-Path $RepoRoot 'uninstall.cmd') -Arguments @('-ConfigRoot', $cfg) -ViaCmd
    Assert-Equal 0 $remove.ExitCode ("uninstall.cmd exited {0}: {1}" -f $remove.ExitCode, (Get-Tail $remove.Output))
    Assert-Missing (Join-Path $cfg 'scripts\godot-ensure.ps1') 'uninstall.cmd did not remove the files'
}

Test-Case 'a fresh profile installs to the default config root and can be cleaned' {
    param($dir)

    $fakeHome = Join-Path $dir 'home'
    New-Item -ItemType Directory -Force -Path $fakeHome | Out-Null

    # No -ConfigRoot at all: %USERPROFILE%\.config\opencode is the documented
    # default, and a machine that has never run opencode has no such directory.
    $envMap = Get-InstallEnv -UserHome $fakeHome -ServerExe (New-StubServer -Dir $dir)
    $r = Invoke-Og -Path (Join-Path $RepoRoot 'install.ps1') `
        -Arguments @('-PatchOpencode', '-NoService', '-NoAutostart') -Environment $envMap
    Assert-Equal 0 $r.ExitCode ("installer exited {0}: {1}" -f $r.ExitCode, (Get-Tail $r.Output))

    $cfg = Join-Path $fakeHome '.config\opencode'
    Assert-Exists (Join-Path $cfg 'opencode.json') 'no opencode.json at the default config root'
    Assert-Exists (Join-Path $cfg 'scripts\godot-ensure.ps1') 'the scripts were not installed'
    Assert-Exists (Join-Path $cfg 'scripts\godot-doctor.ps1') 'the doctor was not installed'
    Assert-Exists (Join-Path $cfg 'skills\godot-game-by-prompt\SKILL.md') 'the skill was not installed'
    Assert-Exists (Join-Path $cfg 'commands\game.md') 'the command was not installed'
    Assert-Exists (Join-Path $cfg 'godot-mcp-addon\godot_mcp\plugin.cfg') 'the addon was not installed'

    $json = ConvertFrom-JsonFile (Join-Path $cfg 'opencode.json')
    Assert-Equal 'http://127.0.0.1:9599/mcp' $json.mcp.godot.url 'the default install points somewhere else'

    # -NoAutostart must mean what it says, and nothing may leak into the profile.
    Assert-Missing (Join-Path $fakeHome 'godot-mcp-service.vbs') 'an autostart entry appeared despite -NoAutostart'

    # The same profile must be returnable to a clean state without -ConfigRoot.
    $u = Invoke-Og -Path (Join-Path $RepoRoot 'uninstall.ps1') -Environment $envMap
    Assert-Equal 0 $u.ExitCode ("uninstall exited {0}: {1}" -f $u.ExitCode, (Get-Tail $u.Output))
    Assert-Missing (Join-Path $cfg 'scripts\godot-ensure.ps1') 'uninstall did not remove the scripts'
    Assert-Missing (Join-Path $cfg 'godot-mcp-addon') 'uninstall did not remove the addon'
    Assert-Missing (Join-Path $cfg 'commands\game.md') 'uninstall did not remove the command'
    Assert-Missing (Join-Path $cfg 'skills\godot-game-by-prompt') 'uninstall did not remove the skill'

    $left = @(Get-ChildItem -LiteralPath $cfg -Recurse -File -Force)
    Assert-Equal 1 $left.Count 'uninstall left more than the config file behind'
    Assert-Equal 'opencode.json' $left[0].Name 'uninstall removed the config it is supposed to keep'
}

Test-Case 'an empty mcp block gains the godot entry and stays valid JSON' {
    param($dir)

    $fakeHome = Join-Path $dir 'home'
    New-Item -ItemType Directory -Force -Path $fakeHome | Out-Null
    $cfg = Join-Path $dir 'cfg'
    New-Item -ItemType Directory -Force -Path $cfg | Out-Null

    # The other common fresh shape: opencode.json exists, but no MCP server has
    # ever been added, so the block is `{}` and must not gain a trailing comma.
    $cfgFile = Join-Path $cfg 'opencode.json'
    $original = @'
{
  "$schema": "https://opencode.ai/config.json",
  "theme": "tokyonight",
  "mcp": {}
}
'@
    [System.IO.File]::WriteAllText($cfgFile, $original, (New-Object System.Text.UTF8Encoding($false)))
    $before = Get-Sha $cfgFile

    $r = Invoke-Og -Path (Join-Path $RepoRoot 'install.ps1') `
        -Arguments @('-ConfigRoot', $cfg, '-PatchOpencode', '-NoService', '-NoAutostart') `
        -Environment (Get-InstallEnv -UserHome $fakeHome -ServerExe (New-StubServer -Dir $dir))
    Assert-Equal 0 $r.ExitCode ("installer exited {0}: {1}" -f $r.ExitCode, (Get-Tail $r.Output))
    Assert-Match 'added the "godot" remote server' $r.Output 'the empty mcp block was not patched'

    $json = ConvertFrom-JsonFile $cfgFile
    Assert-Equal 'tokyonight' $json.theme 'theme was not preserved'
    Assert-Equal 'http://127.0.0.1:9599/mcp' $json.mcp.godot.url 'the godot entry is missing'
    Assert-Equal 1 (@($json.mcp.PSObject.Properties)).Count 'the empty mcp block gained more than one server'
    Assert-NotMatch ',\s*\}' (Get-Content -LiteralPath $cfgFile -Raw) 'a trailing comma would break strict JSON parsers'
    Assert-Equal $before (Get-Sha "$cfgFile.bak-opencode-godot") 'the backup is not byte-identical to the original'
}

Test-Case 'Godot is found in Downloads and -NoLaunch reports it without launching' {
    param($dir)

    $fakeHome = Join-Path $dir 'home'
    New-Item -ItemType Directory -Force -Path $fakeHome | Out-Null

    # Hold the service port so godot-ensure.ps1 takes its "already listening"
    # branch and starts nothing. If something else already owns the port the
    # effect is the same, so a failed bind is not a failure.
    $listener = $null
    try {
        $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 9599)
        $listener.Start()
    }
    catch { $listener = $null }

    try {
        # The beginner case: a ZIP unpacked two levels down in Downloads.
        $godotDir = Join-Path $fakeHome 'Downloads\Godot 4.7.2'
        New-Item -ItemType Directory -Force -Path $godotDir | Out-Null
        $fakeGodot = Join-Path $godotDir 'Godot_v4.7.2-stable_win64_console.exe'
        [IO.File]::WriteAllText($fakeGodot, 'stub - -NoLaunch never executes this')

        $proj = Join-Path $dir 'proj'
        $envMap = @{
            USERPROFILE           = $fakeHome
            LOCALAPPDATA          = (Join-Path $fakeHome 'AppData\Local')
            ProgramFiles          = (Join-Path $fakeHome 'pf')
            'ProgramFiles(x86)'   = (Join-Path $fakeHome 'pf86')
            GODOT_MCP_HTTP_PORT   = '9599'
            GODOT_MCP_BRIDGE_PORT = '9580'
            GODOT_MCP_SERVER_EXE  = (New-StubServer -Dir $dir)
            # No Godot on PATH: the point is the Downloads fallback, and PATH
            # wins over it by design.
            PATH                  = (Get-MinimalPath)
        }
        $r = Invoke-Og -Path (Join-Path $RepoRoot 'scripts\godot-ensure.ps1') `
            -Arguments @('-Create', '-NoLaunch', '-ProjectPath', $proj, '-TimeoutSec', '3') -Environment $envMap
        Assert-Equal 0 $r.ExitCode ("godot-ensure exited {0}: {1}" -f $r.ExitCode, (Get-Tail $r.Output))
        Assert-Match ([regex]::Escape("godot: $fakeGodot")) $r.Output 'the exe unpacked in Downloads was not reported'
        Assert-Exists (Join-Path $proj 'project.godot') 'the project was not created'
        Assert-Exists (Join-Path $proj 'addons\godot_mcp\plugin.cfg') 'the addon was not provisioned'

        # The same empty machine with no Godot at all: provisioning still
        # succeeds, but the run says up front that the editor cannot be launched.
        $bare = Join-Path $dir 'home-bare'
        New-Item -ItemType Directory -Force -Path $bare | Out-Null
        $bareMap = @{
            USERPROFILE           = $bare
            LOCALAPPDATA          = (Join-Path $bare 'AppData\Local')
            ProgramFiles          = (Join-Path $bare 'pf')
            'ProgramFiles(x86)'   = (Join-Path $bare 'pf86')
            GODOT_MCP_HTTP_PORT   = '9599'
            GODOT_MCP_BRIDGE_PORT = '9580'
            GODOT_MCP_SERVER_EXE  = $envMap['GODOT_MCP_SERVER_EXE']
            PATH                  = (Get-MinimalPath)
        }
        $r2 = Invoke-Og -Path (Join-Path $RepoRoot 'scripts\godot-ensure.ps1') `
            -Arguments @('-Create', '-NoLaunch', '-ProjectPath', (Join-Path $dir 'proj2'), '-TimeoutSec', '3') -Environment $bareMap
        Assert-Equal 0 $r2.ExitCode ("godot-ensure exited {0} without Godot: {1}" -f $r2.ExitCode, (Get-Tail $r2.Output))
        Assert-Match 'godot: NOT FOUND' $r2.Output 'a missing Godot was not reported'
        Assert-Match 'pass -GodotExe' $r2.Output 'the fix was not offered'
    }
    finally {
        if ($listener) { $listener.Stop() }
    }
}

Test-Case '-InstallServer without uv stops before touching the config' {
    param($dir)

    $fakeHome = Join-Path $dir 'home'
    New-Item -ItemType Directory -Force -Path $fakeHome | Out-Null
    $cfg = Join-Path $dir 'cfg'
    $envMap = @{
        USERPROFILE          = $fakeHome
        GODOT_MCP_SERVER_EXE = ''
        GODOT_MCP_HTTP_PORT  = '9599'
        PATH                 = (Get-MinimalPath)
    }

    $r = Invoke-Og -Path (Join-Path $RepoRoot 'install.ps1') `
        -Arguments @('-ConfigRoot', $cfg, '-InstallServer', '-NoService', '-NoAutostart') -Environment $envMap

    Assert-Equal 1 $r.ExitCode ("a run that cannot install the server must exit 1, got {0}: {1}" -f $r.ExitCode, (Get-Tail $r.Output))
    Assert-Match 'needs uv, and uv is not installed' $r.Output 'uv was not named'
    Assert-Match 'winget install --id=astral-sh\.uv -e' $r.Output 'the first command was not offered'
    Assert-Match 'astral\.sh/uv/install\.ps1' $r.Output 'the alternative install was not offered'
    Assert-NotMatch 'Done\.' $r.Output 'the installer claimed success'
    Assert-Missing $cfg 'the config directory was created before the run knew it could not finish'
    Assert-NotMatch 'At line:|CategoryInfo' $r.Output 'the run crashed with a stack trace'
}

Test-Case 'a GODOT_MCP_SERVER_EXE pointing nowhere is not treated as installed' {
    param($dir)

    $fakeHome = Join-Path $dir 'home'
    New-Item -ItemType Directory -Force -Path $fakeHome | Out-Null
    $cfg = Join-Path $dir 'cfg'
    $envMap = @{
        USERPROFILE          = $fakeHome
        GODOT_MCP_SERVER_EXE = (Join-Path $dir 'uninstalled\godot-editor-mcp.exe')
        GODOT_MCP_HTTP_PORT  = '9599'
        PATH                 = (Get-MinimalPath)
    }

    $r = Invoke-Og -Path (Join-Path $RepoRoot 'install.ps1') `
        -Arguments @('-ConfigRoot', $cfg, '-NoService', '-NoAutostart') -Environment $envMap

    Assert-Equal 1 $r.ExitCode ("a stale override must not pass for an installed server, got {0}: {1}" -f $r.ExitCode, (Get-Tail $r.Output))
    Assert-Match 'mcp server : NOT INSTALLED' $r.Output 'the missing server was not reported'
    Assert-Match 'NOT READY' $r.Output 'the run did not end with NOT READY'
}

Test-Case 'the doctor reports a bare machine honestly and agrees with the installer' {
    param($dir)

    $fakeHome = Join-Path $dir 'home'
    New-Item -ItemType Directory -Force -Path $fakeHome | Out-Null
    $port = 9597
    $envMap = @{
        USERPROFILE           = $fakeHome
        LOCALAPPDATA          = (Join-Path $fakeHome 'AppData\Local')
        ProgramFiles          = (Join-Path $fakeHome 'pf')
        'ProgramFiles(x86)'   = (Join-Path $fakeHome 'pf86')
        GODOT_MCP_HTTP_PORT   = "$port"
        GODOT_MCP_BRIDGE_PORT = '9587'
        PATH                  = (Get-MinimalPath)
    }

    $bare = Invoke-Og -Path (Join-Path $RepoRoot 'scripts\godot-doctor.ps1') -Arguments @('-TimeoutSec', '1') -Environment $envMap
    Assert-Equal 1 $bare.ExitCode ("the doctor must fail a bare machine, got {0}: {1}" -f $bare.ExitCode, (Get-Tail $bare.Output))
    Assert-Match '(?m)^\s*uv\s+MISSING' $bare.Output 'uv was not reported missing'
    Assert-Match '(?m)^\s*mcp server\s+MISSING' $bare.Output 'the missing server was not reported'
    Assert-Match '(?m)^\s*godot\s+MISSING' $bare.Output 'the missing Godot was not reported'
    Assert-Match 'no file at' $bare.Output 'the missing opencode.json was not reported'
    Assert-Match 'NOT READY' $bare.Output 'the verdict was not NOT READY'
    Assert-NotMatch 'At line:|CategoryInfo' $bare.Output 'the doctor crashed with a stack trace'

    # Install with the server supplied through the override, then ask again.
    $installMap = @{
        USERPROFILE          = $fakeHome
        GODOT_MCP_SERVER_EXE = (New-StubServer -Dir $dir)
        GODOT_MCP_HTTP_PORT  = "$port"
    }
    $i = Invoke-Og -Path (Join-Path $RepoRoot 'install.ps1') `
        -Arguments @('-PatchOpencode', '-NoService', '-NoAutostart') -Environment $installMap
    Assert-Equal 0 $i.ExitCode ("installer exited {0}: {1}" -f $i.ExitCode, (Get-Tail $i.Output))

    $envMap['GODOT_MCP_SERVER_EXE'] = $installMap['GODOT_MCP_SERVER_EXE']
    $after = Invoke-Og -Path (Join-Path $RepoRoot 'scripts\godot-doctor.ps1') -Arguments @('-TimeoutSec', '1') -Environment $envMap
    Assert-Match ([regex]::Escape("http://127.0.0.1:$port/mcp")) $after.Output 'the doctor did not show the configured url'
    Assert-NotMatch 'config port' $after.Output 'the doctor and the installer disagree about the port'
    Assert-NotMatch '(?m)^\s*mcp server\s+MISSING' $after.Output 'the doctor ignored a GODOT_MCP_SERVER_EXE the installer accepted'
}

Test-Case 'spaces, unicode and brackets in the config path are handled' {
    param($dir)

    $fakeHome = Join-Path $dir 'home'
    New-Item -ItemType Directory -Force -Path $fakeHome | Out-Null

    # Built from code points so this file stays pure ASCII: Windows PowerShell
    # 5.1 reads a BOM-less .ps1 as ANSI, which would corrupt a literal umlaut.
    $name = 'opencode cfg T' + [char]0x00EB + 'st ' + [char]0x65E5 + [char]0x672C + [char]0x8A9E + ' [x]'
    $cfg = Join-Path $dir $name
    $envMap = Get-InstallEnv -UserHome $fakeHome -ServerExe (New-StubServer -Dir $dir)

    $r = Invoke-Og -Path (Join-Path $RepoRoot 'install.ps1') `
        -Arguments @('-ConfigRoot', $cfg, '-PatchOpencode', '-NoService', '-NoAutostart') -Environment $envMap
    Assert-Equal 0 $r.ExitCode ("installer exited {0}: {1}" -f $r.ExitCode, (Get-Tail $r.Output))

    # The directory really carries the requested name, not a mangled version.
    Assert-Equal $cfg (Get-Item -LiteralPath $cfg).FullName 'the config directory name was mangled'

    $nested = 'handlers\batch.gd'
    $installedNested = Join-Path $cfg "godot-mcp-addon\godot_mcp\$nested"
    Assert-Exists $installedNested 'a nested addon file is missing'
    Assert-Equal (Get-Sha (Join-Path $RepoRoot "addon\godot_mcp\$nested")) (Get-Sha $installedNested) 'a nested addon file was copied incorrectly'

    $json = ConvertFrom-JsonFile (Join-Path $cfg 'opencode.json')
    Assert-Equal 'http://127.0.0.1:9599/mcp' $json.mcp.godot.url 'the url is wrong in that path'

    # A second run must still recognise the addon as unchanged there.
    $again = Invoke-Og -Path (Join-Path $RepoRoot 'install.ps1') `
        -Arguments @('-ConfigRoot', $cfg, '-PatchOpencode', '-NoService', '-NoAutostart') -Environment $envMap
    Assert-Equal 0 $again.ExitCode ("second install exited {0}: {1}" -f $again.ExitCode, (Get-Tail $again.Output))
    Assert-Match '= godot-mcp-addon\\godot_mcp' $again.Output 'the addon was not recognised as unchanged in that path'
}

# ================================================================== isolation audit

if ($script:Index -eq 0) {
    Write-Host ''
    Write-Host ("no test matched the filter '{0}'" -f $Filter) -ForegroundColor Red
    Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue
    exit 1
}

$auditProblems = New-Object System.Collections.ArrayList

foreach ($p in $protectedPaths) {
    $after = if (Test-Path -LiteralPath $p -PathType Container) { (Get-TreeHashes $p) -join "`n" }
             elseif (Test-Path -LiteralPath $p) { Get-Sha $p }
             else { '__missing__' }
    if ($after -ne $protectedBefore[$p]) { $null = $auditProblems.Add("changed: $p") }
}

$listenersAfter = (Get-BridgeListeners) -join ';'
if ($listenersAfter -ne $listenersBefore) {
    $null = $auditProblems.Add(("bridge listeners changed: '{0}' -> '{1}'" -f $listenersBefore, $listenersAfter))
}

Write-Host ''
Write-Host ("[{0}] isolation audit (real config, startup entry, bridge ports)" -f ($script:Index + 1)) -ForegroundColor Cyan
if ($auditProblems.Count -eq 0) {
    Write-Host '      PASS  (nothing outside the temp tree changed)' -ForegroundColor Green
}
else {
    Write-Host '      FAIL' -ForegroundColor Red
    foreach ($problem in $auditProblems) { Write-Host ('        ' + $problem) -ForegroundColor Red }
    $null = $script:Failures.Add([pscustomobject]@{ Name = 'isolation audit'; Message = ($auditProblems -join "`n") })
}

# ------------------------------------------------------------------ summary

if (-not $KeepArtifacts) {
    Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue
}
else {
    Write-Host ''
    Write-Host ("artifacts kept: {0}" -f $script:Root) -ForegroundColor DarkGray
}

Write-Host ''
Write-Host ('-' * 72) -ForegroundColor DarkGray
if ($script:Failures.Count -gt 0) {
    Write-Host ("FAILED  {0} passed, {1} failed" -f $script:Passed, $script:Failures.Count) -ForegroundColor Red
    foreach ($failure in $script:Failures) {
        Write-Host ''
        Write-Host ("  x {0}" -f $failure.Name) -ForegroundColor Red
        foreach ($line in ($failure.Message -split "`r?`n")) { Write-Host ('    ' + $line) -ForegroundColor Red }
    }
    exit 1
}

Write-Host ("OK  {0} tests passed" -f $script:Passed) -ForegroundColor Green
exit 0
