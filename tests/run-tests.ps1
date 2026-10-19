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
      * A stub MCP service (Start-FakeMcpServer) on a private port, answering the
        two requests the doctor makes, so READY / ALMOST are reachable without a
        real service or a real editor.
      * Renamed copies of powershell.exe, launched with Godot-like command lines,
        to exercise the process detector against real Win32_Process data. They
        are not Godot: no editor, no bridge, no project.

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

function Get-ShaLf {
    # SHA-256 of the content with CRLF normalised to LF.
    #
    # The vendored addon is LF in the index, but GitHub's Windows runners check
    # out with core.autocrlf=true, which materialises *.gd with CRLF - so a raw
    # byte hash of the working file is a property of the *checkout*, and a guard
    # built on it passes locally and fails in CI (which is exactly what happened
    # on 9043890). Normalising keeps the guard about content, which is what a
    # patch is cut from.
    param([string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $out = New-Object 'System.Collections.Generic.List[byte]'
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        if ($bytes[$i] -eq 0x0D -and ($i + 1) -lt $bytes.Length -and $bytes[$i + 1] -eq 0x0A) { continue }
        $out.Add($bytes[$i])
    }
    $alg = [System.Security.Cryptography.SHA256]::Create()
    try { return (($alg.ComputeHash($out.ToArray()) | ForEach-Object { $_.ToString('x2') }) -join '').ToUpperInvariant() }
    finally { $alg.Dispose() }
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
        [switch]$ViaCmd,
        # Run the child under another PowerShell host (e.g. pwsh), so a check can
        # be run under both 5.1 and 7 without changing this helper.
        [string]$HostPath = ''
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
            $exe = if ($HostPath) { $HostPath } else { Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe' }
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

<#
    Lift named functions out of a shipped script without running it.

    The scripts are top-level programs - dot-sourcing godot-ensure.ps1 would
    prepare a project - so the function bodies are taken from the AST and defined
    in this session. That keeps the code under test the REAL code instead of a
    copy pasted into the suite, where it could drift from the scripts.
#>
function Import-ScriptFunction {
    param([string]$Path, [string[]]$Name)

    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
    $defs = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))
    $loaded = @()
    foreach ($fn in $defs) {
        if ($Name -notcontains $fn.Name) { continue }
        # Body.Extent.Text keeps the outer braces, and a scriptblock built from
        # "{ ... }" evaluates to a nested ScriptBlock instead of running the body.
        $body = $fn.Body.Extent.Text
        if ($body.StartsWith('{') -and $body.EndsWith('}')) {
            $body = $body.Substring(1, $body.Length - 2)
        }
        Set-Item -Path ("function:global:{0}" -f $fn.Name) -Value ([scriptblock]::Create($body))
        $loaded += $fn.Name
    }
    foreach ($want in $Name) {
        if ($loaded -notcontains $want) { Fail ("no function {0} in {1}" -f $want, $Path) }
    }
}

function Wait-PortState {
    param([int]$Port, [bool]$Listening, [int]$TimeoutSec = 20)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $hit = [bool](Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)
        if ($hit -eq $Listening) { return $true }
        Start-Sleep -Milliseconds 200
    }
    return $false
}

<#
    A stub MCP service: it answers exactly the two requests godot-doctor.ps1 makes
    (initialize, then tools/call godot_health_check), so the READY / ALMOST
    verdicts can be exercised with no real service and no real editor.

    A raw TcpListener rather than HttpListener: HttpListener wants a URL ACL that
    a non-admin cannot grant, a TcpListener needs nothing. It runs in a job
    because it has to stay alive while the doctor runs as a child process, and it
    accepts with Pending() polling rather than a blocking AcceptTcpClient so that
    Stop-Job can always end it. After MaxRequests it exits on its own.
#>
function Start-FakeMcpServer {
    param([int]$Port, [bool]$BridgeConnected, [int]$MaxRequests = 4)

    Start-Job -ArgumentList $Port, $BridgeConnected, $MaxRequests -ScriptBlock {
        param($Port, $BridgeConnected, $MaxRequests)

        $healthJson = '{"bridge_connected":' + $(if ($BridgeConnected) { 'true' } else { 'false' }) +
            ',"addon_version":"' + $(if ($BridgeConnected) { '2026.10.15' } else { '' }) + '"}'
        $init = '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05","capabilities":{},"serverInfo":{"name":"godot-editor-mcp","version":"stub"}}}'
        $tool = (@{ jsonrpc = '2.0'; id = 2; result = @{ content = @(@{ type = 'text'; text = $healthJson }) } } |
            ConvertTo-Json -Depth 8 -Compress) -replace "`r?`n", ''

        # A previous stub's port may still be closing; retry the bind.
        $listener = $null
        for ($attempt = 0; $attempt -lt 40 -and -not $listener; $attempt++) {
            try {
                $candidate = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $Port)
                $candidate.Start()
                $listener = $candidate
            }
            catch { Start-Sleep -Milliseconds 250 }
        }
        if (-not $listener) { throw "the stub could not bind 127.0.0.1:$Port" }

        try {
            $served = 0
            $deadline = (Get-Date).AddSeconds(120)
            while ($served -lt $MaxRequests -and (Get-Date) -lt $deadline) {
                if (-not $listener.Pending()) { Start-Sleep -Milliseconds 50; continue }
                $client = $listener.AcceptTcpClient()
                try {
                    $stream = $client.GetStream()
                    $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::ASCII)
                    $length = 0
                    while ($true) {
                        $line = $reader.ReadLine()
                        if ($null -eq $line -or $line -eq '') { break }
                        if ($line -match '(?i)^Content-Length:\s*(\d+)') { $length = [int]$Matches[1] }
                    }
                    $body = ''
                    if ($length -gt 0) {
                        $chars = New-Object char[] $length
                        $read = 0
                        while ($read -lt $length) {
                            $n = $reader.Read($chars, $read, $length - $read)
                            if ($n -le 0) { break }
                            $read += $n
                        }
                        if ($read -gt 0) { $body = -join $chars[0..($read - 1)] }
                    }
                    $payload = if ($body -match 'tools/call') { 'data: ' + $tool } else { 'data: ' + $init }
                    $bytes = [System.Text.Encoding]::ASCII.GetBytes($payload)
                    $head = "HTTP/1.1 200 OK`r`nContent-Type: text/event-stream`r`nmcp-session-id: stub-session`r`nContent-Length: $($bytes.Length)`r`nConnection: close`r`n`r`n"
                    $headBytes = [System.Text.Encoding]::ASCII.GetBytes($head)
                    $stream.Write($headBytes, 0, $headBytes.Length)
                    $stream.Write($bytes, 0, $bytes.Length)
                    $stream.Flush()
                    $served++
                }
                finally { $client.Close() }
            }
        }
        finally { $listener.Stop() }
    }
}

function Stop-FakeMcpServer {
    param($Job)
    if (-not $Job) { return }
    Stop-Job -Job $Job -ErrorAction SilentlyContinue
    Remove-Job -Job $Job -Force -ErrorAction SilentlyContinue
}

<#
    Backstop for the process test: kill anything whose command line carries this
    test's unique marker, so a failed run cannot leave a fake "Godot" behind on
    the machine for later tests to trip over.
#>
function Stop-MarkedProcess {
    param([string]$Marker)
    foreach ($p in @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)) {
        if ($p.CommandLine -and $p.CommandLine.Contains($Marker)) {
            Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
        }
    }
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
    # Current shape: mcp.servers.<name>. The flat mcp.<name> form is deprecated
    # in opencode's schema, so a config this installer creates must not use it.
    Assert-Equal 'remote' $json.mcp.servers.godot.type 'the godot entry is not a remote server'
    Assert-Equal 'http://127.0.0.1:9599/mcp' $json.mcp.servers.godot.url 'the godot url did not follow GODOT_MCP_HTTP_PORT'
    Assert-Equal 1 (@($json.mcp.PSObject.Properties)).Count 'the created mcp block should hold only "servers"'
    Assert-Equal 'servers' (@($json.mcp.PSObject.Properties))[0].Name 'a new config must use the current mcp.servers shape'
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

Test-Case 'a current-shape config (mcp.servers) is patched where opencode reads it' {
    param($dir)

    $fakeHome = Join-Path $dir 'home'
    New-Item -ItemType Directory -Force -Path $fakeHome | Out-Null
    $cfg = Join-Path $dir 'cfg'
    New-Item -ItemType Directory -Force -Path $cfg | Out-Null

    # opencode's current schema keeps servers under mcp.servers. A config in that
    # shape must not be reported as unreadable, and the port fix has to land in
    # the entry opencode actually reads - an extra entry under the deprecated
    # flat key would be a silent duplicate.
    $cfgFile = Join-Path $cfg 'opencode.json'
    $original = @'
{
  "$schema": "https://opencode.ai/config.json",
  "theme": "tokyonight",
  "mcp": {
    "servers": {
      "github": { "type": "remote", "url": "https://api.githubcopilot.com/mcp/" },
      "godot": { "type": "remote", "url": "http://127.0.0.1:9090/mcp" }
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
    Assert-Match 'updated "godot" -> http://127\.0\.0\.1:9599/mcp' $r.Output 'the port fix was not reported'
    Assert-NotMatch 'cannot read' $r.Output 'a current-shape config was reported as unreadable'

    $json = ConvertFrom-JsonFile $cfgFile
    Assert-Equal 'http://127.0.0.1:9599/mcp' $json.mcp.servers.godot.url 'the nested godot url was not corrected'
    Assert-Equal 'https://api.githubcopilot.com/mcp/' $json.mcp.servers.github.url 'the github server was damaged'
    Assert-Equal 2 (@($json.mcp.servers.PSObject.Properties)).Count 'a duplicate server entry appeared under servers'
    Assert-Equal 1 (@($json.mcp.PSObject.Properties)).Count 'a deprecated flat entry was created next to "servers"'
    Assert-Equal 'tokyonight' $json.theme 'theme was not preserved'
    Assert-NotMatch '9090' (Get-Content -LiteralPath $cfgFile -Raw) 'the old port is still in the config'

    $backup = "$cfgFile.bak-opencode-godot"
    Assert-Exists $backup 'the original config was not backed up'
    Assert-Equal $before (Get-Sha $backup) 'the backup is not byte-identical to the original'
}

Test-Case 'a current-shape config without a godot entry gains one inside mcp.servers' {
    param($dir)

    $fakeHome = Join-Path $dir 'home'
    New-Item -ItemType Directory -Force -Path $fakeHome | Out-Null
    $cfg = Join-Path $dir 'cfg'
    New-Item -ItemType Directory -Force -Path $cfg | Out-Null

    $cfgFile = Join-Path $cfg 'opencode.json'
    $original = @'
{
  "$schema": "https://opencode.ai/config.json",
  "mcp": {
    "servers": {
      "github": { "type": "remote", "url": "https://api.githubcopilot.com/mcp/" }
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
    Assert-Match 'added the "godot" remote server' $r.Output 'the entry was not added'

    $json = ConvertFrom-JsonFile $cfgFile
    Assert-Equal 'http://127.0.0.1:9599/mcp' $json.mcp.servers.godot.url 'the entry did not land inside mcp.servers'
    Assert-Equal 'https://api.githubcopilot.com/mcp/' $json.mcp.servers.github.url 'the github server was damaged'
    Assert-Equal 2 (@($json.mcp.servers.PSObject.Properties)).Count 'the servers block should now hold two entries'
    Assert-Equal 1 (@($json.mcp.PSObject.Properties)).Count 'a deprecated flat entry was created next to "servers"'
    Assert-Equal $before (Get-Sha "$cfgFile.bak-opencode-godot") 'the backup is not byte-identical to the original'
}

Test-Case 'a mcp block holding only options gains a servers object' {
    param($dir)

    $fakeHome = Join-Path $dir 'home'
    New-Item -ItemType Directory -Force -Path $fakeHome | Out-Null
    $cfg = Join-Path $dir 'cfg'
    New-Item -ItemType Directory -Force -Path $cfg | Out-Null

    # The block is not empty (it carries the per-mcp timeout), so the entry has
    # to be added as a new "servers" object beside it - not as a flat server,
    # which the schema deprecates.
    $cfgFile = Join-Path $cfg 'opencode.json'
    $original = @'
{
  "mcp": {
    "timeout": { "startup": 10000 }
  }
}
'@
    [System.IO.File]::WriteAllText($cfgFile, $original, (New-Object System.Text.UTF8Encoding($false)))

    $r = Invoke-Og -Path (Join-Path $RepoRoot 'install.ps1') `
        -Arguments @('-ConfigRoot', $cfg, '-PatchOpencode', '-NoService', '-NoAutostart') `
        -Environment (Get-InstallEnv -UserHome $fakeHome -ServerExe (New-StubServer -Dir $dir))

    Assert-Equal 0 $r.ExitCode ("installer exited {0}: {1}" -f $r.ExitCode, (Get-Tail $r.Output))
    Assert-Match 'added the "godot" remote server' $r.Output 'the entry was not added'

    $json = ConvertFrom-JsonFile $cfgFile
    Assert-Equal 10000 $json.mcp.timeout.startup 'the existing mcp option was damaged'
    Assert-Equal 'http://127.0.0.1:9599/mcp' $json.mcp.servers.godot.url 'the entry did not land under mcp.servers'
    Assert-Equal 2 (@($json.mcp.PSObject.Properties)).Count 'mcp should hold "timeout" and "servers"'
    Assert-NotMatch ',\s*\}' (Get-Content -LiteralPath $cfgFile -Raw) 'a trailing comma would break strict JSON parsers'
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

Test-Case 'install records what it installed so drift can be spotted' {
    param($dir)

    $fakeHome = Join-Path $dir 'home'
    New-Item -ItemType Directory -Force -Path $fakeHome | Out-Null
    $cfg = Join-Path $dir 'cfg'
    $envMap = Get-InstallEnv -UserHome $fakeHome -ServerExe (New-StubServer -Dir $dir)
    $install = Join-Path $RepoRoot 'install.ps1'
    $args = @('-ConfigRoot', $cfg, '-NoService', '-NoAutostart')

    $first = Invoke-Og -Path $install -Arguments $args -Environment $envMap
    Assert-Equal 0 $first.ExitCode ("install exited {0}: {1}" -f $first.ExitCode, (Get-Tail $first.Output))

    $record = Join-Path $cfg 'scripts\.install-source.json'
    Assert-Exists $record 'the install record was not written'

    $j = ConvertFrom-JsonFile $record
    Assert-Equal $RepoRoot $j.repo 'the record does not name the checkout it came from'
    # Read the raw text rather than the parsed value: PowerShell 7's
    # ConvertFrom-Json turns an ISO-8601 string into a DateTime, so the parsed
    # shape is host-dependent while the file is not.
    Assert-Match '"installedAt"\s*:\s*"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ"' (Get-Content -LiteralPath $record -Raw) `
        'installedAt is not a UTC stamp'

    # Every recorded hash has to be the hash of the file that is really installed,
    # or the doctor's drift check would report noise on a clean install.
    $names = @($j.files.PSObject.Properties | ForEach-Object { $_.Name })
    Assert-True ($names.Count -ge 8) ("the record lists too few files: {0}" -f ($names -join ', '))
    foreach ($prop in $j.files.PSObject.Properties) {
        $target = Join-Path $cfg ($prop.Name -replace '/', '\')
        Assert-Exists $target ("the record names a file that is not installed: {0}" -f $prop.Name)
        Assert-Equal ([string]$prop.Value.sha) (Get-Sha $target) ("the recorded hash is wrong for {0}" -f $prop.Name)

        # The recorded source is what the doctor hashes to notice a checkout that
        # has moved on, and the installed layout is not the checkout layout (skill\
        # installs to skills\, command\ to commands\). Assuming the installed path
        # could be joined back onto the repo made the doctor call two files drifted
        # forever, so the contract is asserted here rather than assumed.
        $src = Join-Path $RepoRoot ([string]$prop.Value.src -replace '/', '\')
        Assert-Exists $src ("{0} records a source that is not in the checkout: {1}" -f $prop.Name, $prop.Value.src)
        Assert-Equal ([string]$prop.Value.sha) (Get-Sha $src) ("{0} records a source whose content is not what was installed" -f $prop.Name)
    }
    Assert-True ($names -contains 'scripts/godot-doctor.ps1') 'the doctor is not in the record'
    Assert-True ($names -contains 'commands/game.md') 'the command is not in the record'
    # The addon tree is a pinned vendor copy: recording it would make a hand-added
    # handler look like drift on every run.
    Assert-True (-not ($names -contains 'godot-mcp-addon/godot_mcp/plugin.cfg')) 'the addon tree was recorded'

    # A second, identical install must leave the record alone: installedAt is the
    # answer to "when was this content put here?".
    $stamp = (Get-Item -LiteralPath $record).LastWriteTimeUtc
    $second = Invoke-Og -Path $install -Arguments $args -Environment $envMap
    Assert-Equal 0 $second.ExitCode ("second install exited {0}: {1}" -f $second.ExitCode, (Get-Tail $second.Output))
    Assert-Equal $stamp (Get-Item -LiteralPath $record).LastWriteTimeUtc 'the record was rewritten although nothing changed'
    Assert-Match '(?m)^  = scripts\\\.install-source\.json' $second.Output 'the unchanged record was not reported as unchanged'

    # Uninstall must take it away, or a later install would inherit a stale record.
    $r = Invoke-Og -Path (Join-Path $RepoRoot 'uninstall.ps1') -Arguments @('-ConfigRoot', $cfg)
    Assert-Equal 0 $r.ExitCode ("uninstall exited {0}: {1}" -f $r.ExitCode, (Get-Tail $r.Output))
    Assert-Missing $record 'uninstall left the install record behind'
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

Test-Case 'addon provisioning backs up a hand-edited file instead of overwriting it' {
    param($dir)

    $proj = Join-Path $dir 'proj'
    New-Item -ItemType Directory -Force -Path $proj | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $proj 'project.godot'),
        "config_version=5`r`n`r`n[application]`r`n`r`nconfig/name=`"test`"`r`n")

    $addon = Join-Path $RepoRoot 'addon\godot_mcp'
    $sourceCount = @(Get-ChildItem -LiteralPath $addon -Recurse -File).Count
    $provision = Join-Path $RepoRoot 'scripts\godot-new-project.ps1'
    $args = @('-ProjectPath', $proj, '-AddonSource', $addon)
    $dest = Join-Path $proj 'addons\godot_mcp'

    $first = Invoke-Og -Path $provision -Arguments $args
    Assert-Equal 0 $first.ExitCode ("provisioning exited {0}: {1}" -f $first.ExitCode, (Get-Tail $first.Output))
    Assert-Equal 0 (@(Get-ChildItem -LiteralPath $dest -Recurse -File -Filter '*.bak*')).Count `
        'the first provisioning backed something up'

    # A hand edit to a shipped handler, plus the user's own handler. The first is an
    # upgrade of a file provisioning owns; the second upstream does not ship at all.
    $edited = Join-Path $dest 'handlers\batch.gd'
    $edit1 = "# user edit 1`n"
    [System.IO.File]::WriteAllText($edited, $edit1)

    $stray = Join-Path $dest 'handlers\user-added.gd'
    [System.IO.File]::WriteAllText($stray, 'user file')

    $neighbour = Join-Path $dest 'type_coerce.gd'
    # Read the stamp back after setting it: [datetime]'...Z' carries a Kind the
    # property does not preserve, and the raw comparison then reports a change
    # that never happened (the same trick the addon-upgrade test uses).
    (Get-Item -LiteralPath $neighbour).LastWriteTimeUtc = $script:Sentinel
    $neighbourStamp = (Get-Item -LiteralPath $neighbour).LastWriteTimeUtc

    $second = Invoke-Og -Path $provision -Arguments $args
    Assert-Equal 0 $second.ExitCode ("the repair exited {0}: {1}" -f $second.ExitCode, (Get-Tail $second.Output))
    # The reported count is what the destination holds afterwards - the upstream
    # files plus the user's own handler - with backups deliberately excluded from it.
    Assert-Match ([regex]::Escape("copied $($sourceCount + 1) files")) $second.Output 'the addon file count is wrong'
    Assert-Match '1 replaced file\(s\) backed up as \.bak' $second.Output 'the provisioning did not report the backup'
    Assert-Equal (Get-Sha (Join-Path $addon 'handlers\batch.gd')) (Get-Sha $edited) 'the edited addon file was not restored'
    Assert-Exists "$edited.bak" 'the edited addon file was replaced with no backup'
    Assert-Equal $edit1 ([System.IO.File]::ReadAllText("$edited.bak")) 'the backup does not hold the previous contents'
    Assert-Equal $neighbourStamp (Get-Item -LiteralPath $neighbour).LastWriteTimeUtc 'an unchanged addon file was rewritten'
    Assert-Equal 'user file' ([System.IO.File]::ReadAllText($stray)) 'provisioning deleted a file upstream does not ship'
    Assert-Missing "$stray.bak" 'a file upstream does not ship was backed up as if it had been replaced'

    # A second edit must not clobber the first backup: after two upgrades it is the
    # only copy of what the file originally was.
    $edit2 = "# user edit 2`n"
    [System.IO.File]::WriteAllText($edited, $edit2)
    $third = Invoke-Og -Path $provision -Arguments $args
    Assert-Equal 0 $third.ExitCode ("the second repair exited {0}: {1}" -f $third.ExitCode, (Get-Tail $third.Output))
    Assert-Equal (Get-Sha (Join-Path $addon 'handlers\batch.gd')) (Get-Sha $edited) 'the second edit was not restored'
    Assert-Equal $edit1 ([System.IO.File]::ReadAllText("$edited.bak")) 'a later provisioning overwrote the earlier backup'
    Assert-Equal $edit2 ([System.IO.File]::ReadAllText("$edited.bak.1")) 'the second edit was not backed up'
    Assert-Equal 0 (@(Get-ChildItem -LiteralPath $dest -Recurse -File -Filter '*.partial')).Count 'a partial-copy artifact was left behind'
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
            'scripts\.install-source.json',
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
    Assert-Equal 'http://127.0.0.1:9599/mcp' $json.mcp.servers.godot.url 'the default install points somewhere else'

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
    Assert-Equal 'http://127.0.0.1:9599/mcp' $json.mcp.servers.godot.url 'the godot entry is missing'
    Assert-Equal 1 (@($json.mcp.PSObject.Properties)).Count 'the empty mcp block gained more than one key'
    Assert-Equal 'servers' (@($json.mcp.PSObject.Properties))[0].Name 'an empty mcp block should be filled with the current shape'
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
        # Compare by identity, not by string: a CI runner's %TEMP% is the 8.3
        # form (RUNNER~1), so the same file legitimately prints two ways.
        $reported = [regex]::Match($r.Output, 'godot: (.+\.exe)').Groups[1].Value
        Assert-Match 'godot: .*\\Downloads\\Godot 4\.7\.2\\Godot_v4\.7\.2-stable_win64_console\.exe' $r.Output 'the exe unpacked in Downloads was not reported'
        Assert-Exists $reported 'the reported path does not exist'
        Assert-Equal (Get-Sha $fakeGodot) (Get-Sha $reported) 'the reported path is not the copy in Downloads'
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
    # Leaf only: %TEMP% is the 8.3 form on a runner, so the same path prints
    # with RUNNER~1 in one place and the full user name in another.
    Assert-Equal $name (Split-Path -Leaf (Get-Item -LiteralPath $cfg).FullName) 'the config directory name was mangled'

    $nested = 'handlers\batch.gd'
    $installedNested = Join-Path $cfg "godot-mcp-addon\godot_mcp\$nested"
    Assert-Exists $installedNested 'a nested addon file is missing'
    Assert-Equal (Get-Sha (Join-Path $RepoRoot "addon\godot_mcp\$nested")) (Get-Sha $installedNested) 'a nested addon file was copied incorrectly'

    $json = ConvertFrom-JsonFile (Join-Path $cfg 'opencode.json')
    Assert-Equal 'http://127.0.0.1:9599/mcp' $json.mcp.servers.godot.url 'the url is wrong in that path'

    # A second run must still recognise the addon as unchanged there.
    $again = Invoke-Og -Path (Join-Path $RepoRoot 'install.ps1') `
        -Arguments @('-ConfigRoot', $cfg, '-PatchOpencode', '-NoService', '-NoAutostart') -Environment $envMap
    Assert-Equal 0 $again.ExitCode ("second install exited {0}: {1}" -f $again.ExitCode, (Get-Tail $again.Output))
    Assert-Match '= godot-mcp-addon\\godot_mcp' $again.Output 'the addon was not recognised as unchanged in that path'
}

# ================================================================== editor detection

Test-Case 'editor detection: -e, -editor, --editor, and games that are not editors' {
    param($dir)

    Import-ScriptFunction -Path (Join-Path $RepoRoot 'scripts\godot-ensure.ps1') `
        -Name @('Split-GodotCommandLine', 'ConvertFrom-GodotCommandLine')

    # Command lines shaped like the ones Godot produces: the executable first,
    # --path in either quoting, the editor flag at the end.
    $runs = @(
        @{ Line = '"C:\Godot\godot.exe" --path "C:\My Games\proj" -e';        Editor = $true;  Path = 'C:\My Games\proj' },
        @{ Line = 'godot.exe --path C:\proj -e';                              Editor = $true;  Path = 'C:\proj' },
        @{ Line = '"C:\Program Files\Godot\godot.exe" --path C:\proj -editor'; Editor = $true; Path = 'C:\proj' },
        @{ Line = 'godot.exe --path "C:\My Games\proj" --editor';             Editor = $true;  Path = 'C:\My Games\proj' },
        @{ Line = '"C:\Godot\godot.exe" --path "C:\My Games\proj"';           Editor = $false; Path = 'C:\My Games\proj' },
        @{ Line = 'godot.exe --path C:\proj';                                 Editor = $false; Path = 'C:\proj' },
        @{ Line = 'godot.exe --path C:\proj --verbose --fullscreen';           Editor = $false; Path = 'C:\proj' },
        # A path is data, never a flag. These two were read as editors before,
        # which is what made a running game look like the editor.
        @{ Line = 'godot.exe --path "C:\my -e games\proj"';                    Editor = $false; Path = 'C:\my -e games\proj' },
        @{ Line = 'godot.exe --path "C:\a --editor b\proj"';                   Editor = $false; Path = 'C:\a --editor b\proj' },
        # Separator handling is unchanged.
        @{ Line = 'godot.exe --path C:/games/proj -e';                         Editor = $true;  Path = 'C:\games\proj' },
        @{ Line = 'godot.exe --path "C:\games\proj\" -e';                      Editor = $true;  Path = 'C:\games\proj' }
    )
    foreach ($run in $runs) {
        $parsed = ConvertFrom-GodotCommandLine -CommandLine $run.Line
        Assert-True ($null -ne $parsed) ("not recognised as a Godot run: {0}" -f $run.Line)
        Assert-Equal $run.Path $parsed.ProjectPath ("wrong project path for: {0}" -f $run.Line)
        Assert-Equal $run.Editor $parsed.IsEditor ("wrong editor flag for: {0}" -f $run.Line)
    }

    # Not a --path run at all: the process is skipped, never guessed at.
    foreach ($line in @(
            'godot.exe --editor',
            'godot.exe --path=C:\proj -e',   # the equals form was never supported
            'notepad.exe C:\notes.txt',
            ''
        )) {
        Assert-True ($null -eq (ConvertFrom-GodotCommandLine -CommandLine $line)) ("should not classify: '{0}'" -f $line)
    }
}

Test-Case 'editor detection: a console launcher is dropped, its child is kept' {
    param($dir)

    Import-ScriptFunction -Path (Join-Path $RepoRoot 'scripts\godot-ensure.ps1') -Name @('Select-GodotHostProcess')

    # A console-build launch is two processes: the launcher, and the child that
    # actually owns the bridge. One window must not count as two.
    $table = @(
        [pscustomobject]@{ Name = 'Godot_v4.7.2-stable_win64_console.exe'; ProcessId = 100; ParentProcessId = 1 },
        [pscustomobject]@{ Name = 'Godot_v4.7.2-stable_win64.exe';         ProcessId = 101; ParentProcessId = 100 },
        [pscustomobject]@{ Name = 'Godot_v4.7.2-stable_win64_console.exe'; ProcessId = 102; ParentProcessId = 1 }
    )
    $kept = @(Select-GodotHostProcess -Processes $table)
    Assert-Equal 2 $kept.Count 'a console launcher that has a child was not dropped'
    Assert-True ($kept.ProcessId -contains 101) 'the launcher child was dropped too'
    Assert-True ($kept.ProcessId -contains 102) 'a childless console build was dropped'
    Assert-True ($kept.ProcessId -notcontains 100) 'the launcher was kept'

    # The F5 game is a child of the editor, and a console build of a game has no
    # children: being a child is not a reason to drop a process, being a launcher is.
    $gameTree = @(
        [pscustomobject]@{ Name = 'Godot_v4.7.2-stable_win64.exe';         ProcessId = 200; ParentProcessId = 1 },
        [pscustomobject]@{ Name = 'Godot_v4.7.2-stable_win64_console.exe'; ProcessId = 201; ParentProcessId = 200 }
    )
    $keptGame = @(Select-GodotHostProcess -Processes $gameTree)
    Assert-Equal 2 $keptGame.Count 'a childless console build of a game was dropped'
}

Test-Case 'editor detection: real processes, and a running game is not an editor' {
    param($dir)

    Import-ScriptFunction -Path (Join-Path $RepoRoot 'scripts\godot-ensure.ps1') `
        -Name @('Split-GodotCommandLine', 'ConvertFrom-GodotCommandLine', 'Select-GodotHostProcess', 'Get-GodotEditors')

    # The detector filters on the process NAME and reads the real command line, so
    # a renamed copy of the Windows PowerShell host is indistinguishable from
    # Godot to it. This drives Win32_Process, the actual command line and the real
    # parent/child tree - not a simulated table. It is still not a real Godot: no
    # editor, no bridge, no project.
    $tools = Join-Path $dir 'tools'
    New-Item -ItemType Directory -Force -Path $tools | Out-Null
    $hostExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $editorExe = Join-Path $tools 'Godot_v4.7.2-stable_win64.exe'
    $launcherExe = Join-Path $tools 'Godot_v4.7.2-stable_win64_console.exe'
    Copy-Item -LiteralPath $hostExe -Destination $editorExe
    Copy-Item -LiteralPath $hostExe -Destination $launcherExe

    $sleeper = Join-Path $tools 'sleep.ps1'
    [System.IO.File]::WriteAllText($sleeper, 'Start-Sleep -Seconds 90')

    $token = 'C:\og-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $editorProj = "$token editor proj"
    $gameProj = "$token game proj"
    $launchProj = "$token launcher proj"

    # The launcher starts the real editor as its child and then stays alive, which
    # is what godot_console.exe does.
    $launchTemplate = @'
$child = Join-Path $PSScriptRoot 'Godot_v4.7.2-stable_win64.exe'
$sleeper = Join-Path $PSScriptRoot 'sleep.ps1'
$childArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', ('"' + $sleeper + '"'), '--path', ('__PROJ__'), '-e')
Start-Process -FilePath $child -WindowStyle Hidden -ArgumentList $childArgs
Start-Sleep -Seconds 90
'@
    $launchScript = Join-Path $tools 'launch.ps1'
    [System.IO.File]::WriteAllText($launchScript, $launchTemplate.Replace('__PROJ__', '"' + $launchProj + '"'))

    $commonArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden')
    $launcher = $null
    try {
        $editor = Start-Process -FilePath $editorExe -WindowStyle Hidden -PassThru -ArgumentList `
            ($commonArgs + @('-File', ('"' + $sleeper + '"'), '--path', ('"' + $editorProj + '"'), '-e'))
        $game = Start-Process -FilePath $editorExe -WindowStyle Hidden -PassThru -ArgumentList `
            ($commonArgs + @('-File', ('"' + $sleeper + '"'), '--path', ('"' + $gameProj + '"')))
        $launcher = Start-Process -FilePath $launcherExe -WindowStyle Hidden -PassThru -ArgumentList `
            ($commonArgs + @('-File', ('"' + $launchScript + '"'), '--path', ('"' + $launchProj + '"'), '-e'))

        # Wait for the launcher's child, then for the detector to name the child
        # rather than the launcher: a childless *_console process IS kept, so the
        # launcher is briefly the answer until the child exists.
        $deadline = (Get-Date).AddSeconds(30)
        $childPid = 0
        while ((Get-Date) -lt $deadline -and $childPid -eq 0) {
            $kids = @(Get-CimInstance Win32_Process -Filter "Name LIKE 'Godot%'" |
                Where-Object { $_.ParentProcessId -eq $launcher.Id })
            if ($kids.Count -gt 0) { $childPid = $kids[0].ProcessId }
            Start-Sleep -Milliseconds 300
        }
        Assert-True ($childPid -ne 0) 'the fake console launcher never started its child'

        $reported = @()
        while ((Get-Date) -lt $deadline) {
            $reported = @(Get-GodotEditors | Where-Object { $_.ProjectPath -like "$token*" })
            $mine = @($reported | Where-Object { $_.ProjectPath -eq $launchProj })
            if ($reported.Count -ge 3 -and $mine.Count -eq 1 -and $mine[0].OwnerPid -eq $childPid) { break }
            Start-Sleep -Milliseconds 300
        }

        $editorRow = @($reported | Where-Object { $_.ProjectPath -eq $editorProj })
        Assert-Equal 1 $editorRow.Count 'the editor was not reported exactly once'
        Assert-Equal $editor.Id $editorRow[0].OwnerPid 'the editor pid was misreported'
        Assert-True $editorRow[0].IsEditor 'the editor was not classified as an editor'

        $gameRow = @($reported | Where-Object { $_.ProjectPath -eq $gameProj })
        Assert-Equal 1 $gameRow.Count 'the game was not reported exactly once'
        Assert-Equal $game.Id $gameRow[0].OwnerPid 'the game pid was misreported'
        Assert-True (-not $gameRow[0].IsEditor) 'a running game was classified as an editor'

        $launchRow = @($reported | Where-Object { $_.ProjectPath -eq $launchProj })
        Assert-Equal 1 $launchRow.Count 'the launcher pair was not reported as exactly one window'
        Assert-Equal $childPid $launchRow[0].OwnerPid 'the console launcher was reported instead of its child'
        Assert-True $launchRow[0].IsEditor 'the launched editor was not classified as an editor'
    }
    finally {
        Stop-MarkedProcess -Marker $dir
    }
}

# ================================================================== addon upgrade

Test-Case 'addon upgrade: an edited file is backed up, an unchanged one is not' {
    param($dir)

    $fakeHome = Join-Path $dir 'home'
    New-Item -ItemType Directory -Force -Path $fakeHome | Out-Null
    $cfg = Join-Path $dir 'cfg'
    $envMap = Get-InstallEnv -UserHome $fakeHome -ServerExe (New-StubServer -Dir $dir)
    $install = Join-Path $RepoRoot 'install.ps1'
    $installArgs = @('-ConfigRoot', $cfg, '-NoService', '-NoAutostart')

    $first = Invoke-Og -Path $install -Arguments $installArgs -Environment $envMap
    Assert-Equal 0 $first.ExitCode ("first install exited {0}: {1}" -f $first.ExitCode, (Get-Tail $first.Output))

    $addon = Join-Path $cfg 'godot-mcp-addon\godot_mcp'
    $edited = Join-Path $addon 'plugin.cfg'
    $untouched = Join-Path $addon 'handlers\batch.gd'
    Assert-Exists $edited 'the addon was not installed at all'

    # 1. Nothing changed: files must not be rewritten, and no backup appears.
    (Get-Item -LiteralPath $edited).LastWriteTimeUtc = $script:Sentinel
    $editedStamp = (Get-Item -LiteralPath $edited).LastWriteTimeUtc
    (Get-Item -LiteralPath $untouched).LastWriteTimeUtc = $script:Sentinel
    $untouchedStamp = (Get-Item -LiteralPath $untouched).LastWriteTimeUtc

    $second = Invoke-Og -Path $install -Arguments $installArgs -Environment $envMap
    Assert-Equal 0 $second.ExitCode ("second install exited {0}: {1}" -f $second.ExitCode, (Get-Tail $second.Output))
    Assert-Equal $editedStamp (Get-Item -LiteralPath $edited).LastWriteTimeUtc 'an unchanged addon file was rewritten'
    Assert-Equal $untouchedStamp (Get-Item -LiteralPath $untouched).LastWriteTimeUtc 'an unchanged addon file was rewritten'
    Assert-Missing "$edited.bak" 'a backup was written although nothing changed'
    Assert-Match '= godot-mcp-addon\\godot_mcp' $second.Output 'the addon was not reported as unchanged'

    # 2. A file missing from the destination is new, not an upgrade: it is copied
    #    and not backed up. A file upstream no longer ships is left alone - there
    #    is no manifest, so it could equally be the user's own handler.
    $stray = Join-Path $addon 'handlers\user-added.gd'
    [System.IO.File]::WriteAllText($stray, 'user file')
    Remove-Item -LiteralPath $untouched -Force

    $third = Invoke-Og -Path $install -Arguments $installArgs -Environment $envMap
    Assert-Equal 0 $third.ExitCode ("third install exited {0}: {1}" -f $third.ExitCode, (Get-Tail $third.Output))
    Assert-Equal (Get-Sha (Join-Path $RepoRoot 'addon\godot_mcp\handlers\batch.gd')) (Get-Sha $untouched) 'a file missing from the destination was not restored'
    Assert-Missing "$untouched.bak" 'a newly installed file was backed up as if it had been replaced'
    Assert-Equal 'user file' ([System.IO.File]::ReadAllText($stray)) 'a file upstream does not ship was deleted by the installer'

    # 3. A modified addon file is replaced AND its previous contents survive: the
    #    backup holds what was there BEFORE the upgrade, not the new contents.
    $userEdit = "user edit 1`n"
    [System.IO.File]::WriteAllText($edited, $userEdit)
    $fourth = Invoke-Og -Path $install -Arguments $installArgs -Environment $envMap
    Assert-Equal 0 $fourth.ExitCode ("fourth install exited {0}: {1}" -f $fourth.ExitCode, (Get-Tail $fourth.Output))
    Assert-Equal (Get-Sha (Join-Path $RepoRoot 'addon\godot_mcp\plugin.cfg')) (Get-Sha $edited) 'the edited addon file was not restored to the upstream copy'
    Assert-Exists "$edited.bak" 'the edited addon file was replaced with no backup'
    Assert-Equal $userEdit ([System.IO.File]::ReadAllText("$edited.bak")) 'the backup does not hold the previous contents'
    Assert-Match 'backed up as \.bak' $fourth.Output 'the installer did not report the backup'

    # 4. A second edit must not clobber the first backup: after two upgrades the
    #    first backup is the only copy of what the file originally was.
    $userEdit2 = "user edit 2`n"
    [System.IO.File]::WriteAllText($edited, $userEdit2)
    $fifth = Invoke-Og -Path $install -Arguments $installArgs -Environment $envMap
    Assert-Equal 0 $fifth.ExitCode ("fifth install exited {0}: {1}" -f $fifth.ExitCode, (Get-Tail $fifth.Output))
    Assert-Equal $userEdit ([System.IO.File]::ReadAllText("$edited.bak")) 'a later install overwrote the earlier backup'
    Assert-Equal $userEdit2 ([System.IO.File]::ReadAllText("$edited.bak.1")) 'the second edit was not backed up'
    Assert-Equal (Get-Sha (Join-Path $RepoRoot 'addon\godot_mcp\plugin.cfg')) (Get-Sha $edited) 'the addon was not restored on the second edit'
    Assert-Equal 0 (@(Get-ChildItem -LiteralPath $addon -Recurse -File -Filter '*.partial')).Count 'a partial-copy artifact was left behind'

    # 5. Single files (scripts\, skills\, commands\) take the same backup path.
    $scriptFile = Join-Path $cfg 'scripts\godot-doctor.ps1'
    $scriptEdit = "# hand edit`n"
    [System.IO.File]::WriteAllText($scriptFile, $scriptEdit)
    $sixth = Invoke-Og -Path $install -Arguments $installArgs -Environment $envMap
    Assert-Equal 0 $sixth.ExitCode ("sixth install exited {0}: {1}" -f $sixth.ExitCode, (Get-Tail $sixth.Output))
    Assert-Equal (Get-Sha (Join-Path $RepoRoot 'scripts\godot-doctor.ps1')) (Get-Sha $scriptFile) 'the edited script was not restored'
    Assert-Equal $scriptEdit ([System.IO.File]::ReadAllText("$scriptFile.bak")) 'the edited script was replaced with no backup'
    Assert-Match 'previous version saved as godot-doctor\.ps1\.bak' $sixth.Output 'the installer did not report the script backup'
}

Test-Case 'addon upgrade: a failed copy does not lose the edited file' {
    param($dir)

    $fakeHome = Join-Path $dir 'home'
    New-Item -ItemType Directory -Force -Path $fakeHome | Out-Null
    $cfg = Join-Path $dir 'cfg'
    $envMap = Get-InstallEnv -UserHome $fakeHome -ServerExe (New-StubServer -Dir $dir)
    $install = Join-Path $RepoRoot 'install.ps1'
    $installArgs = @('-ConfigRoot', $cfg, '-NoService', '-NoAutostart')

    $first = Invoke-Og -Path $install -Arguments $installArgs -Environment $envMap
    Assert-Equal 0 $first.ExitCode ("first install exited {0}: {1}" -f $first.ExitCode, (Get-Tail $first.Output))

    $addon = Join-Path $cfg 'godot-mcp-addon\godot_mcp'
    $edited = Join-Path $addon 'plugin.cfg'
    $userEdit = "user edit`n"
    [System.IO.File]::WriteAllText($edited, $userEdit)

    # Refuse writes on that one file. Hashing it and backing it up only read it,
    # so both succeed, and the overwrite that comes after is the step that fails.
    # An open with FileShare.Read would not do the job: Get-FileHash asks for a
    # narrower share than that handle allows, so the run would fail before it ever
    # reached the backup.
    $acl = Get-Acl -LiteralPath $edited
    $deny = New-Object System.Security.AccessControl.FileSystemAccessRule(
        [System.Security.Principal.WindowsIdentity]::GetCurrent().Name, 'Write', 'Deny')
    $null = $acl.AddAccessRule($deny)
    try {
        Set-Acl -LiteralPath $edited -AclObject $acl
        $failed = Invoke-Og -Path $install -Arguments $installArgs -Environment $envMap
    }
    finally {
        $restore = Get-Acl -LiteralPath $edited
        $null = $restore.RemoveAccessRule($deny)
        Set-Acl -LiteralPath $edited -AclObject $restore
    }

    Assert-True ($failed.ExitCode -ne 0) 'the installer reported success although it could not replace the addon file'
    Assert-Equal $userEdit ([System.IO.File]::ReadAllText($edited)) 'the failed run damaged the edited file'
    Assert-Exists "$edited.bak" 'the failed run left the edit with no recoverable copy'
    Assert-Equal $userEdit ([System.IO.File]::ReadAllText("$edited.bak")) 'the backup is not a complete copy of the edit'
    Assert-Equal 0 (@(Get-ChildItem -LiteralPath $addon -Recurse -File -Filter '*.partial')).Count 'a partial copy was left behind where a backup should be'

    # The edit is still there afterwards, and a clean run upgrades the file.
    $again = Invoke-Og -Path $install -Arguments $installArgs -Environment $envMap
    Assert-Equal 0 $again.ExitCode ("the install after the failure exited {0}: {1}" -f $again.ExitCode, (Get-Tail $again.Output))
    Assert-Equal (Get-Sha (Join-Path $RepoRoot 'addon\godot_mcp\plugin.cfg')) (Get-Sha $edited) 'the addon was not restored after the failed run'
    Assert-Equal $userEdit ([System.IO.File]::ReadAllText("$edited.bak")) 'the edit was lost after the retry'
}

# ================================================================== doctor contract

Test-Case 'doctor: READY, ALMOST and NOT READY, with service and bridge distinct' {
    param($dir)

    $cfg = Join-Path $dir 'cfg'
    New-Item -ItemType Directory -Force -Path $cfg | Out-Null
    $homeDir = Join-Path $dir 'home'
    New-Item -ItemType Directory -Force -Path $homeDir | Out-Null

    # The doctor only looks for the uv command, and GODOT_BIN/GODOT_MCP_SERVER_EXE
    # are file paths it reports: stubs are enough, nothing is ever executed.
    $bin = Join-Path $dir 'bin'
    New-Item -ItemType Directory -Force -Path $bin | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $bin 'uv.exe'), 'stub - never executed')
    $godotStub = Join-Path $dir 'Godot_v4.7.2-stable_win64.exe'
    [System.IO.File]::WriteAllText($godotStub, 'stub - never executed')
    $serverStub = New-StubServer -Dir $dir

    # The bridge port only has to be LISTENING for the doctor's row: a bare
    # listener is the whole requirement, no addon involved.
    $bridgePort = 9587
    $bridgeListener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $bridgePort)
    $bridgeListener.Start()

    $doctor = Join-Path $RepoRoot 'scripts\godot-doctor.ps1'
    $job = $null
    try {
        # Each case gets its own stub on its own port, so the URL the doctor
        # validates and the service it talks to are the same thing. The Shape
        # field alternates the config layout: opencode's current mcp.servers and
        # the older flat mcp.<name>, which the schema deprecates but still parses.
        $cases = @(
            @{ Port = 9597; Attached = $false; Uv = $true;  Shape = 'servers'; Verdict = 'ALMOST';    Exit = 0 },
            @{ Port = 9596; Attached = $true;  Uv = $true;  Shape = 'flat';    Verdict = 'READY';     Exit = 0 },
            @{ Port = 9595; Attached = $true;  Uv = $false; Shape = 'servers'; Verdict = 'NOT READY'; Exit = 1 }
        )
        foreach ($case in $cases) {
            $label = ("port {0}, editor attached {1}, uv present {2}, {3} shape" -f $case.Port, $case.Attached, $case.Uv, $case.Shape)

            $godot = @{ type = 'remote'; url = "http://127.0.0.1:$($case.Port)/mcp" }
            $json = if ($case.Shape -eq 'servers') { @{ mcp = @{ servers = @{ godot = $godot } } } }
                    else { @{ mcp = @{ godot = $godot } } }
            [System.IO.File]::WriteAllText((Join-Path $cfg 'opencode.json'),
                ($json | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))

            Stop-FakeMcpServer -Job $job
            $job = Start-FakeMcpServer -Port $case.Port -BridgeConnected $case.Attached
            Assert-True (Wait-PortState -Port $case.Port -Listening $true) ("the stub service never listened on port {0}" -f $case.Port)

            $envMap = @{
                USERPROFILE           = $homeDir
                OPENCODE_GODOT_CONFIG = $cfg
                GODOT_MCP_HTTP_PORT   = "$($case.Port)"
                GODOT_MCP_BRIDGE_PORT = "$bridgePort"
                GODOT_MCP_SERVER_EXE  = $serverStub
                GODOT_BIN             = $godotStub
                PATH                  = $(if ($case.Uv) { "$bin;$(Get-MinimalPath)" } else { Get-MinimalPath })
            }

            $r = Invoke-Og -Path $doctor -Arguments @('-TimeoutSec', '5') -Environment $envMap
            Assert-Equal $case.Exit $r.ExitCode ("the doctor exited {0} for {1}: {2}" -f $r.ExitCode, $label, (Get-Tail $r.Output))
            Assert-Match ("(?m)^  {0}" -f [regex]::Escape($case.Verdict)) $r.Output ("the verdict for {0} was not {1}" -f $label, $case.Verdict)
            Assert-NotMatch 'At line:|CategoryInfo' $r.Output ("the doctor crashed for {0}" -f $label)

            # The service being available and the editor being attached are two
            # different facts, and the report has to keep them apart.
            Assert-Match ("service {0}\s+listening" -f $case.Port) $r.Output ("the service row is wrong for {0}" -f $label)
            Assert-Match ("bridge {0}\s+listening" -f $bridgePort) $r.Output ("the bridge-port row is wrong for {0}" -f $label)
            # Both config shapes must be found, and a matching port must not be
            # reported as a mismatch. Reading only the flat form reported
            # "godot entry: MISSING" - and NOT READY - on a current config.
            Assert-NotMatch 'godot entry: MISSING' $r.Output ("the godot entry was not found for {0}" -f $label)
            Assert-Match ("-> http://127\.0\.0\.1:{0}/mcp" -f $case.Port) $r.Output ("the config url row is wrong for {0}" -f $label)
            Assert-NotMatch '(?m)^\s+config port' $r.Output ("a matching port was reported as a mismatch for {0}" -f $label)
            Assert-Match 'server\s+godot-editor-mcp stub' $r.Output ("the MCP handshake did not happen for {0}" -f $label)
            if ($case.Attached) {
                Assert-Match 'CONNECTED \(addon 2026\.10\.15\)' $r.Output ("the attached editor was not reported for {0}" -f $label)
                # Anchored: the test's own temp directory carries the verdict
                # words in its name, and the doctor prints paths inside it.
                Assert-NotMatch '(?m)^  ALMOST' $r.Output ("an attached editor was reported as ALMOST for {0}" -f $label)
            }
            else {
                Assert-Match 'no editor attached' $r.Output ("the missing editor was not explained for {0}" -f $label)
                Assert-NotMatch '(?m)^  NOT READY' $r.Output ("an installed box with no editor was reported as broken for {0}" -f $label)
            }
            if (-not $case.Uv) {
                Assert-Match 'uv\s+MISSING' $r.Output ("the missing prerequisite was not reported for {0}" -f $label)
            }

            # PowerShell 7 ignores -UseBasicParsing and answers the response
            # differently, and nothing else in the suite reaches that path there.
            if ($PSVersionTable.PSVersion.Major -ge 7) {
                $currentHost = (Get-Process -Id $PID).Path
                Assert-Equal 'pwsh.exe' (Split-Path -Leaf $currentHost) 'the extra run was not made with pwsh'
                $again = Invoke-Og -Path $doctor -Arguments @('-TimeoutSec', '5') -Environment $envMap -HostPath $currentHost
                Assert-Equal $case.Exit $again.ExitCode ("the same check under pwsh exited {0} for {1}: {2}" -f $again.ExitCode, $label, (Get-Tail $again.Output))
                Assert-Match ("(?m)^  {0}" -f [regex]::Escape($case.Verdict)) $again.Output ("the verdict under pwsh was not {0} for {1}" -f $case.Verdict, $label)
                Assert-NotMatch 'At line:|CategoryInfo' $again.Output ("the doctor crashed under pwsh for {0}" -f $label)
            }
        }
    }
    finally {
        Stop-FakeMcpServer -Job $job
        $bridgeListener.Stop()
    }
}

# ================================================================== doctor drift

Test-Case 'doctor: an install record is checked, and drift never fails the box' {
    param($dir)

    $cfg = Join-Path $dir 'cfg'
    New-Item -ItemType Directory -Force -Path (Join-Path $cfg 'scripts') | Out-Null
    $homeDir = Join-Path $dir 'home'
    New-Item -ItemType Directory -Force -Path $homeDir | Out-Null

    $port = 9594
    $bridgePort = 9586
    [System.IO.File]::WriteAllText((Join-Path $cfg 'opencode.json'),
        (@{ mcp = @{ servers = @{ godot = @{ type = 'remote'; url = "http://127.0.0.1:$port/mcp" } } } } | ConvertTo-Json -Depth 6),
        (New-Object System.Text.UTF8Encoding($false)))

    $bin = Join-Path $dir 'bin'
    New-Item -ItemType Directory -Force -Path $bin | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $bin 'uv.exe'), 'stub - never executed')
    $godotStub = Join-Path $dir 'Godot_v4.7.2-stable_win64.exe'
    [System.IO.File]::WriteAllText($godotStub, 'stub - never executed')

    # The checkout the record points at holds real files, so the hash comparison
    # under test is a real comparison rather than a mock of one.
    $checkout = Join-Path $dir 'checkout'
    New-Item -ItemType Directory -Force -Path (Join-Path $checkout 'scripts') | Out-Null
    $installedFile = Join-Path $cfg 'scripts\godot-ensure.ps1'
    $checkoutFile = Join-Path $checkout 'scripts\godot-ensure.ps1'
    [System.IO.File]::WriteAllText($installedFile, "installed copy`n")
    [System.IO.File]::WriteAllText($checkoutFile, "installed copy`n")

    $record = Join-Path $cfg 'scripts\.install-source.json'
    $bridgeListener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $bridgePort)
    $bridgeListener.Start()
    $job = Start-FakeMcpServer -Port $port -BridgeConnected $false -MaxRequests 24
    Assert-True (Wait-PortState -Port $port -Listening $true) 'the stub service never listened'

    $doctor = Join-Path $RepoRoot 'scripts\godot-doctor.ps1'
    $envMap = @{
        USERPROFILE           = $homeDir
        OPENCODE_GODOT_CONFIG = $cfg
        GODOT_MCP_HTTP_PORT   = "$port"
        GODOT_MCP_BRIDGE_PORT = "$bridgePort"
        GODOT_MCP_SERVER_EXE  = (New-StubServer -Dir $dir)
        GODOT_BIN             = $godotStub
        PATH                  = "$bin;$(Get-MinimalPath)"
    }

    try {
        # 1. No record yet (any install made before this feature): a hint, not a
        #    failure. Counting it would mark every older install NOT READY.
        Assert-Missing $record 'the test started with a stale record'
        $r = Invoke-Og -Path $doctor -Arguments @('-TimeoutSec', '5') -Environment $envMap
        Assert-Equal 0 $r.ExitCode ("the doctor exited {0}: {1}" -f $r.ExitCode, (Get-Tail $r.Output))
        Assert-Match '(?m)^  ALMOST' $r.Output 'an install without a record is not ALMOST'
        Assert-Match 'no install record' $r.Output 'the missing record was not mentioned'

        # 2. In sync: reported, with no drift hint. Each entry carries the source
        #    path in the checkout, which is what the second half hashes.
        @{ repo = $checkout; installedAt = '2026-01-01T00:00:00Z'
           files = @{ 'scripts/godot-ensure.ps1' = @{ sha = (Get-Sha $installedFile); src = 'scripts/godot-ensure.ps1' } } } |
            ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $record -Encoding ASCII
        $r = Invoke-Og -Path $doctor -Arguments @('-TimeoutSec', '5') -Environment $envMap
        Assert-Equal 0 $r.ExitCode ("the doctor exited {0}: {1}" -f $r.ExitCode, (Get-Tail $r.Output))
        Assert-Match ("install\s+" + [regex]::Escape($checkout)) $r.Output 'the recorded checkout was not reported'
        Assert-Match 'all files as installed' $r.Output 'an in-sync install was not recognised'
        Assert-NotMatch '(?m)^\s+drift' $r.Output 'drift was reported on an in-sync install'
        Assert-Match '(?m)^  ALMOST' $r.Output 'an in-sync install is not ALMOST'

        # 2b. A record from before source paths were kept holds a bare hash, so the
        #     checkout half cannot be checked. Saying nothing would hide it and
        #     calling it drift would be a lie, so it is reported as neither.
        @{ repo = $checkout; installedAt = '2026-01-01T00:00:00Z'; files = @{ 'scripts/godot-ensure.ps1' = (Get-Sha $installedFile) } } |
            ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $record -Encoding ASCII
        $r = Invoke-Og -Path $doctor -Arguments @('-TimeoutSec', '5') -Environment $envMap
        Assert-Equal 0 $r.ExitCode ("the doctor exited {0}: {1}" -f $r.ExitCode, (Get-Tail $r.Output))
        Assert-Match 'predate recorded source paths' $r.Output 'a legacy record was silently skipped'
        Assert-NotMatch 'run install\.cmd to update' $r.Output 'a legacy record was reported as checkout drift'
        #    ...then back to the current shape, because the cases below build on it.
        @{ repo = $checkout; installedAt = '2026-01-01T00:00:00Z'
           files = @{ 'scripts/godot-ensure.ps1' = @{ sha = (Get-Sha $installedFile); src = 'scripts/godot-ensure.ps1' } } } |
            ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $record -Encoding ASCII

        # 3. The installed file was edited here: reported, and still not a failure.
        [System.IO.File]::AppendAllText($installedFile, "# local edit`n")
        $r = Invoke-Og -Path $doctor -Arguments @('-TimeoutSec', '5') -Environment $envMap
        Assert-Equal 0 $r.ExitCode ("an edited install must not fail the box, got {0}: {1}" -f $r.ExitCode, (Get-Tail $r.Output))
        Assert-Match '1 edited here' $r.Output 'a locally edited file was not reported'
        Assert-Match '(?m)^  ALMOST' $r.Output 'a locally edited install is not ALMOST'

        # 4. The checkout has moved on as well: the update hint appears.
        [System.IO.File]::AppendAllText($checkoutFile, "# newer in the checkout`n")
        $r = Invoke-Og -Path $doctor -Arguments @('-TimeoutSec', '5') -Environment $envMap
        Assert-Equal 0 $r.ExitCode ("a moved-on checkout must not fail the box, got {0}: {1}" -f $r.ExitCode, (Get-Tail $r.Output))
        Assert-Match 'run install\.cmd to update' $r.Output 'the update hint was not printed'
        Assert-Match '1 edited here' $r.Output 'the local edit stopped being reported'
        Assert-Match '(?m)^  ALMOST' $r.Output 'a moved-on checkout is not ALMOST'

        # 5. The installed layout is not the checkout layout: skill\ installs to
        #    skills\ and command\ to commands\, so a checkout path cannot be built
        #    by joining the installed path. Assuming it could made the doctor call
        #    those files drifted forever, on a clean install.
        New-Item -ItemType Directory -Force -Path (Join-Path $cfg 'commands'), (Join-Path $checkout 'command') | Out-Null
        $installedCmd = Join-Path $cfg 'commands\game.md'
        $checkoutCmd = Join-Path $checkout 'command\game.md'
        [System.IO.File]::WriteAllText($installedCmd, "installed copy`n")
        [System.IO.File]::WriteAllText($checkoutCmd, "installed copy`n")
        @{ repo = $checkout; installedAt = '2026-01-01T00:00:00Z'
           files = @{ 'commands/game.md' = @{ sha = (Get-Sha $installedCmd); src = 'command/game.md' } } } |
            ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $record -Encoding ASCII
        $r = Invoke-Og -Path $doctor -Arguments @('-TimeoutSec', '5') -Environment $envMap
        Assert-Equal 0 $r.ExitCode ("the doctor exited {0}: {1}" -f $r.ExitCode, (Get-Tail $r.Output))
        Assert-NotMatch '(?m)^\s+drift' $r.Output 'a file whose checkout path differs from its installed path was called drift'
        Assert-Match 'all files as installed' $r.Output 'the mapped file was not recognised as in sync'

        # ...and a real change to that same file is still caught - and named, since
        #    a bare count is what made this bug invisible in the first place.
        [System.IO.File]::AppendAllText($checkoutCmd, "# newer in the checkout`n")
        $r = Invoke-Og -Path $doctor -Arguments @('-TimeoutSec', '5') -Environment $envMap
        Assert-Match 'run install\.cmd to update' $r.Output 'a moved-on checkout stopped being reported'
        Assert-Match 'commands/game\.md' $r.Output 'the drifting file was not named'

        # 6. A recorded checkout that is gone: explained, not a crash (the repo a
        #    user installed from can be moved or deleted without breaking the box).
        @{ repo = (Join-Path $dir 'gone'); installedAt = '2026-01-01T00:00:00Z'; files = @{ 'scripts/godot-ensure.ps1' = (Get-Sha $installedFile) } } |
            ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $record -Encoding ASCII
        $r = Invoke-Og -Path $doctor -Arguments @('-TimeoutSec', '5') -Environment $envMap
        Assert-Equal 0 $r.ExitCode ("a missing checkout must not fail the box, got {0}: {1}" -f $r.ExitCode, (Get-Tail $r.Output))
        Assert-Match 'not there any more' $r.Output 'a missing checkout was not explained'
        Assert-NotMatch 'At line:|CategoryInfo' $r.Output 'the doctor crashed on a missing checkout'

        # 7. A corrupt record: reported, still not a crash, still not a failure.
        [System.IO.File]::WriteAllText($record, '{ this is not json')
        $r = Invoke-Og -Path $doctor -Arguments @('-TimeoutSec', '5') -Environment $envMap
        Assert-Equal 0 $r.ExitCode ("a corrupt record must not fail the box, got {0}: {1}" -f $r.ExitCode, (Get-Tail $r.Output))
        Assert-Match 'UNREADABLE' $r.Output 'a corrupt record was not reported'
        Assert-NotMatch 'At line:|CategoryInfo' $r.Output 'the doctor crashed on a corrupt record'
    }
    finally {
        Stop-FakeMcpServer -Job $job
        $bridgeListener.Stop()
    }
}

# ================================================================== hashing

Test-Case 'the scripts hash files without relying on module autoloading' {
    param($dir)

    # Get-FileHash is only as reliable as the child session's PSModulePath. When a
    # PowerShell 7 parent hands its PSModulePath to the Windows PowerShell 5.1
    # child that install.cmd starts, 5.1 resolves Microsoft.PowerShell.Utility
    # from PS7's directory first, that Core assembly fails to load, and the cmdlet
    # is gone from the session - which killed an install.cmd upgrade from a pwsh
    # terminal with "Get-FileHash is not recognized" after files had been copied.
    # Hashing therefore goes through each script's own .NET helper.
    foreach ($file in @('install.ps1', 'scripts\godot-new-project.ps1', 'scripts\godot-doctor.ps1')) {
        $path = Join-Path $RepoRoot $file
        # AST, not a text search: the notes explaining this bug name the cmdlet,
        # and a comment must not be able to satisfy - or trip - the check.
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$null)
        $calls = @($ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.CommandAst] -and
                    $node.GetCommandName() -eq 'Get-FileHash'
                }, $true))
        Assert-Equal 0 $calls.Count ("{0} still hashes through module autoloading" -f $file)
        Assert-Match 'function Get-Sha256' (Get-Content -LiteralPath $path -Raw) ("{0} has no self-contained hash helper" -f $file)
    }

    # The helper has to return what Get-FileHash returned (uppercase hex), or a
    # hash recorded by one host would read as drift under another.
    Import-ScriptFunction -Path (Join-Path $RepoRoot 'scripts\godot-doctor.ps1') -Name @('Get-Sha256')
    $sample = Join-Path $dir 'sample.txt'
    [System.IO.File]::WriteAllText($sample, "hello world`n")
    Assert-Equal (Get-Sha $sample) (Get-Sha256 -Path $sample) 'the helper disagrees with Get-FileHash'
}

Test-Case 'the addon patch is still cut from the vendored addon' {
    param($dir)

    # addon/patches/*.patch holds an upstream proposal that is deliberately NOT
    # applied here: addon/VERSION promises the vendored tree is an unmodified
    # upstream copy, and install.ps1 copies it verbatim. Each patch therefore
    # records the file it was cut from and that file's sha256 - a patch that no
    # longer matches is worse than no patch, because `git apply` fails partway
    # through and reads as "the fix is broken". A vendored bump has to refresh
    # the patch, and this test is what says so.
    $patchDir = Join-Path $RepoRoot 'addon\patches'
    $patches = @(Get-ChildItem -LiteralPath $patchDir -Filter '*.patch' -File -ErrorAction SilentlyContinue)
    Assert-True ($patches.Count -ge 1) 'addon\patches holds no patch'

    foreach ($patch in $patches) {
        $text = Get-Content -LiteralPath $patch.FullName -Raw
        $target = [regex]::Match($text, '(?m)^#\s*target:\s*(\S+)\s*$')
        $sha = [regex]::Match($text, '(?m)^#\s*sha256:\s*([0-9a-fA-F]{64})\s*$')
        Assert-True $target.Success ('{0}: no "# target:" line' -f $patch.Name)
        Assert-True $sha.Success ('{0}: no "# sha256:" line' -f $patch.Name)

        $rel = $target.Groups[1].Value
        $file = Join-Path $RepoRoot ($rel -replace '/', '\')
        Assert-Exists $file ('{0} names a file that is not in this repo' -f $patch.Name)
        Assert-Match ('(?m)^diff --git a/{0} b/{0}$' -f [regex]::Escape($rel)) $text `
            ('{0}: carries no diff for its own target' -f $patch.Name)
        # Content, not the checkout's line-ending policy - see Get-ShaLf.
        Assert-Equal ($sha.Groups[1].Value.ToUpperInvariant()) (Get-ShaLf $file) `
            ('{0}: {1} has changed since the patch was cut - refresh the patch and its sha256' -f $patch.Name, $rel)
    }

    # The patches are for a user's installed copy, never for the repo's tree:
    # install.ps1 has to keep copying addon/godot_mcp verbatim.
    Assert-NotMatch 'git apply' (Get-Content -LiteralPath (Join-Path $RepoRoot 'install.ps1') -Raw) `
        'install.ps1 applies a patch; the vendored tree must stay pristine'
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
