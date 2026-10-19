# opencode-godot

Prompt a playable Godot game from [opencode](https://opencode.ai) — one command to
install, one prompt to build.

```text
you:  make me a top-down 2D arena survival game — dodge falling spikes, score ticks up

agent: res://spike_dodge.tscn  ·  67 commands in one batch  ·  ok_all: true  ·  press F5
```

No checklists, no "click this in the editor". The agent provisions the project,
enables the plugin, writes the scenes and scripts, and saves. You press **F5**.

## What it actually is

A thin, opinionated layer over [Godot Editor MCP](https://github.com/hybridindie/godot-mcp)
that removes the three things that make it fail for new users:

1. **A readiness script.** `godot-ensure.ps1` walks the whole chain — service up,
   addon in the project, plugin enabled, editor open on *that* project — then
   polls until the addon is really attached. Four links, one command.
2. **A long-lived service instead of a spawned one.** The editor bridge is a
   single connection. When the MCP client spawns duplicate servers, the losing
   copies get `bridge_bind_error 10048` and every tool dies while the server
   looks healthy. One shared HTTP service removes the race.
3. **A game journal.** `journal.md` records each build (project, scene, controls,
   status, next) so "add a double jump to the platformer" still works tomorrow.

Plus the skill and `/game` command that carry the authoring recipe.

> **Scope:** the agent builds games, you test them. No input injection, no
> screenshots, no assertions — that is your part, and it is the expensive part.

## Requirements

| | | |
|---|---|---|
| OS | **Windows 10/11** (v1 — see [Platform support](#platform-support)) | no admin needed |
| Godot | 4.4+ (developed and verified on **4.7.2**) | [download](https://godotengine.org/download/windows/), unzip anywhere |
| [uv](https://docs.astral.sh/uv/) | the only real prerequisite | it brings its own Python; you do **not** need to install Python |
| [opencode](https://opencode.ai) | V2 (verified on 2.0.32) | |
| Node | 18+ | optional, only for `-Verify` and the probe |

### First-time setup, in order

A fresh Windows box needs four things and nothing else. No admin rights.

```powershell
# 1. uv (a small Python tool runner - no Python install required)
winget install --id=astral-sh.uv -e
#    no winget?  powershell -c "irm https://astral.sh/uv/install.ps1 | iex"

# 2. open a NEW terminal so PATH picks uv up, then install the MCP server
uv tool install godot-editor-mcp

# 3. Godot: download the Windows .zip from godotengine.org and unzip it somewhere
#    normal (Downloads is fine - the scripts look there, or pass -GodotExe).

# 4. opencode: install it, then come back here
```

If you skip something, the installer or `godot-ensure.ps1` says what is missing and
prints the exact command — it does not fail silently or dump a stack trace.

## Install

The beginner path is the `.cmd` wrapper. A fresh Windows profile refuses to run
`.ps1` files ("running scripts is disabled on this system"), and files downloaded
from the internet are blocked as well; `install.cmd` runs PowerShell with a
per-process `-ExecutionPolicy Bypass`, which touches **no** machine policy.

```text
download the ZIP from GitHub, unzip it, double-click install.cmd
```

Or from a shell:

```powershell
git clone https://github.com/fazilahamedraja-boop/opencode-godot
cd opencode-godot
.\install.cmd -PatchOpencode -InstallServer -Verify
```

| flag | what it does |
|---|---|
| `-PatchOpencode` | adds the remote server to `opencode.json` (creates the file if you have none, backs up an existing one, and follows the shape your file uses: `mcp.servers.godot`, or the older flat `mcp.godot`) |
| `-InstallServer` | runs `uv tool install godot-editor-mcp` for you |
| `-Verify` | probes the service and prints its version, tool count and bridge state |
| `-NoAutostart` / `-NoService` | skip the logon shortcut / skip starting the service |

Scripted or advanced use can call `install.ps1` directly; `install.cmd` only adds
the execution-policy bypass and passes every argument through.

What lands where (default `%USERPROFILE%\.config\opencode`):

```
scripts\godot-ensure.ps1          four-link readiness, one command
scripts\godot-doctor.ps1          one-block environment report (good for bug reports)
scripts\godot-new-project.ps1     addon + [editor_plugins] + runtime probe
scripts\godot-journal.ps1         -Tail N  /  -Append
scripts\godot-mcp-service.cmd     the one long-lived HTTP service
scripts\godot-mcp-probe.mjs       shell-level health check, no AI client
scripts\.install-source.json      install record: what was installed, for drift checks
skills\godot-game-by-prompt\      the authoring recipe (auto-loads on "make a game")
commands\game.md                  /game, a thin wrapper over the skill
godot-mcp-addon\godot_mcp\        pinned addon copy used for new projects
```

Re-running the installer is safe: identical files are left alone, and a file that
differs is backed up before it is replaced — `.bak`, then `.bak.1`, `.bak.2`, … as
those names fill up, so a later upgrade never overwrites an earlier backup. Backups
are written to a temporary name and moved into place, so an interrupted copy cannot
leave a truncated file that looks complete. Files that upstream no longer ships are
left where they are: the installer keeps no manifest, so it cannot tell an outdated
integration file from a handler you added yourself.
`.\uninstall.cmd` reverses the install and keeps your journal.

### Checking another machine

On a second PC (or a fresh VM) the whole readiness question is one block:

```powershell
git clone https://github.com/fazilahamedraja-boop/opencode-godot
cd opencode-godot
.\install.cmd -InstallServer -PatchOpencode -Verify
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\godot-doctor.ps1
```

`godot-doctor.ps1` needs no Node and changes nothing: it reports the OS, the
persistent execution-policy scopes, whether uv / the server / Godot / Node are
present, whether `opencode.json` points at the port the service is actually on,
the service and bridge state, and the addon version. It ends in one of three
verdicts, and the exit code matches the verdict:

| Verdict | Exit | Meaning |
|---|---|---|
| `READY` | 0 | every prerequisite is present and an editor is attached |
| `ALMOST` | 0 | the tools are installed, but no editor is attached yet |
| `NOT READY` | 1 | something is missing or broken (the count is on the line) |

The service row and the bridge row are deliberately separate. A healthy service on
the port with no editor attached is `ALMOST`, not a failure: the service is a local
HTTP server that can be up on its own, while the bridge is the *addon's* outbound
connection from the running editor, so a listening port alone says nothing about
whether Godot is connected. Paste the whole block into an issue if anything is off.

It also prints an `install` row: `install.ps1` leaves `scripts\.install-source.json`
naming the checkout it installed from and a SHA-256 per installed file, so the
doctor can tell you that your installed copies were edited here, or that the
checkout has gained a fix you never installed. Drift is information, not a
failure — it never changes the verdict or the exit code, because a working box
with hand-edited scripts is not a broken box. The addon tree is not recorded: it
is a pinned vendor copy, and a difference there is normal.

## Use

**1. Open a project in the Godot editor.** Or create one already provisioned —
never the Project Manager, or you get an empty project with no addon:

```powershell
.\scripts\godot-ensure.ps1 -ProjectPath C:\games\my-game -Create -Restart
```

For an existing project, `-Restart` relaunches the editor after the addon is
copied in (Godot reads `[editor_plugins]` only at startup).

Provisioning an already-prepared project changes nothing. On an upgrade it copies
only the addon files that actually differ, and backs up a file it is about to
replace the same way the installer does (`.bak`, `.bak.1`, …) — a handler you edited
by hand is restored to the pinned copy only after its previous contents are saved.
Files upstream no longer ships are left alone, because without a manifest there is
no way to tell them from files you added.

It prints `BRIDGE CONNECTED` and exits `0` when the chain is live. Exit codes:

| Code | Meaning |
|---|---|
| 0 | ready |
| 2 | addon installed, but the editor needs a manual reload |
| 3 | the bridge never connected |
| 4 | another project's editor owns the bridge |

**2. Ask for a game.** The `godot-game-by-prompt` skill loads on its own; `/game`
forces it.

```text
make me a platformer: run and jump, 3 coins, a goal that unlocks when you have them all
```

**3. Press F5.** That is the handover point.

## Verify it yourself

```powershell
node "$env:USERPROFILE\.config\opencode\scripts\godot-mcp-probe.mjs" --tools
```

Real output from a running service (tool count is low until you enable toolsets —
they are in-memory, so a fresh service starts at `core` + `inspection`):

```text
endpoint     : http://127.0.0.1:9090/mcp
initialize   : godot-mcp 4.1.0
session id   : assigned
tools/list   : 24 tools
health       : {"bridge_connected":true,"addon_version":"2026.10.15","transport":"http"}
godot tools  : 24
elapsed      : 120 ms
```

`bridge_connected: false` means the server is fine and Godot is not — open the
project and check the addon. Exit codes: `0` reachable, `2` service down, `3` no
bridge (with `--require-bridge`).

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `running scripts is disabled on this system` | default Windows execution policy, or a downloaded file carrying Mark-of-the-Web | use `install.cmd`, or call the script as `powershell -NoProfile -ExecutionPolicy Bypass -File <script>` |
| `NOT READY - the godot-editor-mcp server is missing` | step 2 of setup was skipped | `uv tool install godot-editor-mcp` (no uv: `winget install --id=astral-sh.uv -e`) |
| `Godot is not installed, or it is somewhere this script cannot guess` | the ZIP was unpacked somewhere unusual | `-GodotExe "<path>\Godot_v4.x-stable_win64_console.exe"`, or set `GODOT_BIN` |
| `godot tools missing` in opencode | the `godot` MCP entry is missing or the client cached a dead server | `opencode reload`; check `opencode.json` has the remote URL |
| `bridge_bind_error 10048` | two servers racing for `:9080` | use the remote service, never a stdio `local` entry |
| MCP dock missing after setup | `[editor_plugins]` written while the editor was open | `godot-ensure.ps1 -Restart` |
| Tools work, then stop | the service restarted | re-enable toolsets (they are in-memory) |
| `VALIDATION_ERROR ... expected -35, got -34.999996` | the write succeeded; vector read-back compares exactly | see [docs/gotchas.md](docs/gotchas.md#1-a-false-validation_error-after-a-vector-write-succeeds) |
| Second editor has no tools | the bridge is single-connection | close the other editor |
| anything else | — | run `godot-doctor.ps1` and paste its one block |

## Platform support

**Windows 10/11 only in v1.** Not an accident: the readiness chain, the service
launcher and the installer are PowerShell/batch, and they were verified end to end
here — including a full cold start with no service and no editor running. A
cross-platform port is mostly `godot-ensure` (process discovery, ports, logon
autostart) and is very welcome as a PR.

The parts that are already portable: the skill, the command, the journal format,
the probe (`node`), and the opencode config snippet.

### What is actually verified

Measured on a redirected profile with no prerequisites on `PATH`, installing from
a clean clone of this repository on freshly chosen ports:

| step | result |
|---|---|
| `install.cmd -InstallServer` (83 packages, no Python pre-installed) | 36.7 s, exit 0 |
| `godot-ensure.ps1 -Create` with Godot only in `Downloads` | 14.5 s, `BRIDGE CONNECTED` |
| `godot-doctor.ps1` | `READY`, addon `2026.10.15` |
| real MCP authoring batch (5 commands) | `ok_all: true`, 601 ms |
| `install.cmd -PatchOpencode` on a config with a theme + another server | valid JSON, both preserved |
| install → uninstall | 115 files in, 0 out, exit 0 |

Reproduced first and fixed in the same pass: default-policy refusal
(`running scripts is disabled`), missing `uv` with a one-step hint that cannot
work, a cheerful `Done.` on a setup with no server, a stack trace instead of a
message when Godot is absent, and an MCP entry left pointing at a stale port.

**Not verified here:** a second physical machine, Windows 10 or 11 on a
different build, a real reboot firing the logon autostart, and macOS/Linux.
`godot-doctor.ps1` exists to make that verification one command.

## Tests

The installer, the `opencode.json` handling, addon provisioning, the addon upgrade
path (in the installer and again inside a project), editor-process detection and the
uninstaller have a regression suite that runs the real scripts in throwaway
directories:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-tests.ps1
```

No Godot editor and no real MCP service take part. Two fakes stand in where the real
thing is not needed: a stub MCP service on private ports (9587 and 9595–9597) that
answers exactly the two requests `godot-doctor.ps1` makes, and renamed copies of
`powershell.exe` launched with Godot-shaped command lines so the process detector is
driven by real `Win32_Process` data. Neither is the behaviour under test; they are
what lets it run with no Godot installed.

It ends with an isolation audit: if anything under your real
`~\.config\opencode`, the Startup entry, or the 9090/9080 listeners changed,
the run fails (the stubs use private ports, which the audit does not watch). CI
runs the same 30 tests on two clean Windows images (`windows-2022` and
`windows-2025`), under both Windows PowerShell 5.1 and PowerShell 7.

Two of those tests are worth knowing about. One drives the doctor with and
without an install record, with an edited install, with a checkout that has moved
on, with a recorded checkout that is gone and with a corrupt record — asserting
every time that drift is reported and the verdict does not move. The other pins
hashed-anywhere behaviour: by AST, no runtime script may call `Get-FileHash`
(gotcha 12).

## Docs

- [docs/architecture.md](docs/architecture.md) — the four links, and why each
  design choice is what it is
- [docs/gotchas.md](docs/gotchas.md) — the traps, with symptoms and workarounds
- [addon/VERSION](addon/VERSION) — exactly which upstream addon is vendored

## Credits and licence

MIT — see [LICENSE](LICENSE).

The addon in `addon/godot_mcp/` is an unmodified copy of
[Godot Editor MCP](https://github.com/hybridindie/godot-mcp) at `2026.10.15`,
also MIT. The server is installed from PyPI rather than vendored. See
[NOTICE](NOTICE).
