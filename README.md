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

| | |
|---|---|
| OS | **Windows 10/11** (v1 — see [Platform support](#platform-support)) |
| Godot | 4.4+ (developed and verified on **4.7.2**) |
| Python | 3.10+ with [`uv`](https://docs.astral.sh/uv/) on `PATH` |
| opencode | V2 (verified on 2.0.32) |
| Node | 18+ (only for the health probe) |

```powershell
uv tool install godot-editor-mcp      # the MCP server (pinned 2026.10.15 in addon/VERSION)
```

## Install

```powershell
git clone https://github.com/fazilahamedraja-boop/opencode-godot
cd opencode-godot
.\install.ps1 -PatchOpencode -Verify
```

`-PatchOpencode` adds the remote server to your `opencode.json` (backing it up
first). Without it, the installer only prints the snippet it would have added.

What lands where (default `%USERPROFILE%\.config\opencode`):

```
scripts\godot-ensure.ps1          four-link readiness, one command
scripts\godot-new-project.ps1     addon + [editor_plugins] + runtime probe
scripts\godot-journal.ps1         -Tail N  /  -Append
scripts\godot-mcp-service.cmd     the one long-lived HTTP service
scripts\godot-mcp-probe.mjs       shell-level health check, no AI client
skills\godot-game-by-prompt\      the authoring recipe (auto-loads on "make a game")
commands\game.md                  /game, a thin wrapper over the skill
godot-mcp-addon\godot_mcp\        pinned addon copy used for new projects
```

Re-running the installer is safe: identical files are left alone, changed ones are
backed up to `.bak` first. `.\uninstall.ps1` reverses it and keeps your journal.

## Use

**1. Open a project in the Godot editor.** Or create one already provisioned —
never the Project Manager, or you get an empty project with no addon:

```powershell
.\scripts\godot-ensure.ps1 -ProjectPath C:\games\my-game -Create -Restart
```

For an existing project, `-Restart` relaunches the editor after the addon is
copied in (Godot reads `[editor_plugins]` only at startup).

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
| `godot tools missing` in opencode | the `godot` MCP entry is missing or the client cached a dead server | `opencode reload`; check `opencode.json` has the remote URL |
| `bridge_bind_error 10048` | two servers racing for `:9080` | use the remote service, never a stdio `local` entry |
| MCP dock missing after setup | `[editor_plugins]` written while the editor was open | `godot-ensure.ps1 -Restart` |
| Tools work, then stop | the service restarted | re-enable toolsets (they are in-memory) |
| `VALIDATION_ERROR ... expected -35, got -34.999996` | the write succeeded; vector read-back compares exactly | see [docs/gotchas.md](docs/gotchas.md#1-a-false-validation_error-after-a-vector-write-succeeds) |
| Second editor has no tools | the bridge is single-connection | close the other editor |

## Platform support

**Windows 10/11 only in v1.** Not an accident: the readiness chain, the service
launcher and the installer are PowerShell/batch, and they were verified end to end
here — including a full cold start with no service and no editor running. A
cross-platform port is mostly `godot-ensure` (process discovery, ports, logon
autostart) and is very welcome as a PR.

The parts that are already portable: the skill, the command, the journal format,
the probe (`node`), and the opencode config snippet.

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
