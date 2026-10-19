---
name: godot-game-by-prompt
description: "Use when asked to create, build, extend, or fix a playable Godot game from a plain-language description — platformer, top-down, 2D, 3D, collect-em-up, arena shooter, puzzle — by driving the LIVE Godot editor over the godot MCP server. Encodes the verified fast path (one enable call, then ONE batched authoring call), the exact run_commands sub-command names and params, the corrected authoring rules (scene creation and .tres resources both batch in the same call as the commands that use them), and the exact-compare verifier gotcha. Starts with godot-ensure.ps1, which starts the service, provisions a new project's addon and plugin, launches the editor and waits for the bridge — so it works from a cold session and after a restart — and records each build in a game journal for continuity. Build the game and stop: do NOT play-test, inject input, or verify gameplay — the user runs it themselves. Triggers: 'make a game', 'build a game in Godot', 'create a platformer/level', 'add enemies to my game', 'write a game with opencode', '/game'. Not for: shipping/exporting a build as the main task, or non-Godot engines — use the Godot MCP skills for engine-level rule lookups."
---

# Godot: a playable game by prompt, fast

Drive the **live editor** so the user can watch the game appear. Target something
that **runs, responds to input, and has a win condition** — never a static scene.

**Build it; do not test it.** The user play-tests their own games. Do not call
`play_scene`, do not inject input, do not assert, do not screenshot. Testing is
their job and it is by far the most expensive thing you could do here.

This skill is the authoritative recipe. `/game` is a thin wrapper that invokes it.

## The whole flow: readiness, 3 calls, hand off

```
# 0. readiness - ALWAYS first, and it is what makes a cold session work
#    (scripts are installed here by install.ps1; use the full path from a bare shell)
$OG = "$env:USERPROFILE\.config\opencode\scripts"
& "$OG\godot-journal.ps1" -Tail 5                # what exists, what was left next
& "$OG\godot-ensure.ps1"                         # remembered project; + addon, plugin,
                                                 # editor, and WAITS for the bridge

# 1-3. the build
godot_health_check                             # bridge_connected == true
godot_enable_toolset("<one comma list>")       # ONE call exposes everything
godot_composite_run_commands([...])            # ONE call builds the whole game

# 4. hand off
& "$OG\godot-journal.ps1" -Append -Game ... -Scene ...   # continuity for the next session
                                                         # then report; F5 is the user's step
```

Do **not** discover tool names, do **not** enable toolsets one at a time, and do
**not** create the scene in a separate call from its nodes. All three are
unnecessary steps this skill exists to skip.

## Step 0 — readiness, or "why a new project has no plugin"

The chain has four links, and a missing one looks the same from inside every time
(`godot` tools missing, or `BRIDGE_DISCONNECTED`):

| Link | What it is | Breaks when |
|---|---|---|
| 1 | HTTP service on `127.0.0.1:9090` | service died / not started |
| 2 | `addons/godot_mcp` inside the project | **new project** — never copied |
| 3 | plugin enabled in `project.godot` | **new project** — never enabled |
| 4 | a running **editor on that project** | machine restart, or a different project is open |

Links 2 and 3 are why a freshly created project has "the plugin missing": Godot
only reads `[editor_plugins]` **at startup**, so an addon added while the editor is
open does nothing until a reload. That is a chicken-and-egg only the script can
break, because the MCP tools themselves are the thing that is disconnected.

```powershell
& "$env:USERPROFILE\.config\opencode\scripts\godot-ensure.ps1" -ProjectPath "<dir>" [-Create] [-Restart]
```

It is idempotent and does all four: starts the service if 9090 is down, copies the
addon, enables the plugin, registers `MCPRuntimeProbe`, launches the editor if none
is open, **then polls the bridge until the addon is actually connected** and prints
`BRIDGE CONNECTED`. "Editor is running" is not "bridge is connected" — only an
ESTABLISHED connection owned by that Godot process proves it.

- Pass `-Create` to make a **new** project. Do this instead of creating one in the
  Godot project manager: the addon is present from the first launch, so the plugin
  is never missing and no reload is ever needed.
- Omit `-ProjectPath` to fall back to the remembered project
  (`%LOCALAPPDATA%\godot-mcp\last-project.txt`), then to whatever project a running
  editor has open. That no-argument form is the cold-session path.
- `-Restart` kills and relaunches an editor whose project just gained the addon.
  **Only with the user's consent** — it loses unsaved work. Without it the script
  exits 2 and says a reload is needed.
- Exit codes: `0` ready, `2` needs a manual reload, `3` bridge never connected,
  `4` another project's editor owns the bridge (close it, or pass `-Restart`).

**Default to a new scene in the project that is already open.** A new *project* is
only for when the user asks for one: the bridge is single-connection, so a second
editor cannot simply coexist, and "make a new project" for every request costs a
launch and a conflict. New project ⇒ `-Create`; new game in the existing project ⇒
just `create_scene` with a new filename.

The service outlives opencode and is autostarted at logon by
`Startup\godot-mcp-service.vbs`, so quitting and reopening opencode reconnects to
the same service. The fragile link is always 4 — the editor — not the service.

## Step 1 — one enable call

Toolsets are **gated**: a tool from a disabled toolset does not exist, and calling
one fails with *no* fallback. `godot_enable_toolset` takes a **comma-separated
list and/or bundle names**, so one call is always enough.

Proven minimum for **building** a game:

```
godot_enable_toolset("scene_edit,scripts,resources_edit,project,composite")
```

`inspection` is already on (it is part of `core`), so you can still read the scene
tree and node properties. Add `runtime,input,testing` **only** if the user asks you
to play-test — otherwise they are 20+ tool schemas of dead weight.

Add only what the game actually needs (one more call, comma-separated):

| Need | Add |
|---|---|
| collision shapes/layers, raycasts | `physics` |
| 2D tile-based level (`TileMapLayer`) | `tilemap` |
| `AnimationPlayer`/`AnimationTree` | `animation` |
| audio players, buses | `audio` |
| styled HUD (`Theme`, styleboxes) | `theme_ui` |
| 3D meshes/cameras/lights/GridMap | `scene_3d` |
| GPU particles / VFX | `particles` |
| enemy pathfinding | `navigation` |
| custom input actions | `input_map` |
| bulk edits, scene dependency analysis | `batch`, `analysis` |
| export a build | `export` |

Bundles exist too: `author` (build scenes/scripts/assets), `playtest`
(run/drive/observe), `ship` (export). `godot_enable_toolset("author,composite")`
is a reasonable one-shot for building when you would otherwise add several of the
rows above. Avoid `playtest` on the default path: it exists to drive a running
game, and the user is the one running games.

Enabling an already-enabled toolset is a harmless no-op.

**Do not seed the whole catalog at startup.** Setting the service's
`GODOT_MCP_DEFAULT_TOOLSETS=all` exposes ~189 tool schemas in *every* session,
including ones with no game work — a large, permanent context tax. The gating is
what keeps the surface small; one comma-list call is the cheap way to open it.

## Step 2 — the whole scene in ONE call

`godot_composite_run_commands(commands=[...], confirm=true, stop_on_error=false)`
runs N bridge commands in a **single round trip**, each as its own undo step.

**Everything batches together — verified.** `create_scene` and `create_resource`
both work inside the same batch as the `create_node` / `set_node_property` that
depend on them. The editor drains commands serially, so ordering within the array
is what matters, not separate calls.

Emit the commands in this order:

```
create_resource (every .tres first)
create_scene
create_node     (parents before their children)
create_node ...
write_script    (all scripts for the scene)
set_node_property
attach_script
save_scene      (last)
```

Sub-commands are bare tool names without the `godot_` prefix (or their `cmd_*`
form). A full game is 1 call; the platformer was 89 commands in one, Coin Rush 76
in one.

| command | params |
|---|---|
| `create_resource` | `type`, `resource_path`, `properties` |
| `create_scene` | `root_type`, `scene_path` |
| `create_node` | `parent_path`, `node_type`, `node_name` |
| `write_script` | `script_path`, `content` |
| `set_node_property` | `node_path`, `property`, `value` |
| `attach_script` | `node_path`, `script_path` |
| `save_scene` | — |

Path rules:

- `parent_path: "."` is the **scene root**; child paths are scene-relative
  (`"UI"`, `"Player/Body"`).
- `attach_script` with `node_path: "."` attaches to the **root** — verified.
- The root node's name is derived from the scene filename
  (`res://coin_rush.tscn` → root `coin_rush`).
- Object-typed properties (`mesh`, `material_override`, `shape`, `environment`)
  accept **only** a `res://….tres` path or `null` — never an inline value. Create
  the `.tres` earlier in the same batch; the reference binds.
- `PackedVector2Array` accepts `[{x,y},…]` — so `Polygon2D.polygon` gives level
  art that is visible in the editor with **no texture assets**. Prefer shapes over
  sprites for prompt-built 2D.
- `Color` accepts `"#rrggbb"`.

`write_script` creates missing subfolders, so `res://platformer/player.gd` needs no
mkdir.

### Types: `parent_path` must name a real node type's parent

`create_scene` takes a built-in `ClassDB` type only ("Node2D", "CharacterBody3D",
"Area3D", …) — a custom `class_name` is not accepted. Create with the built-in
base, then `attach_script` to it.

### Read the per-command results

`stop_on_error=false` so one failure cannot hide the rest. Check `ok_all` and scan
`results[]` for any `ok: false` plus its `error`/`hint`. A `dry_run=true` preview
returns a `plan[]` mapping every command to its tool + gating toolset — use it when
a batch is large or destructive.

## The one real gotcha: exact-compare on Vector/Color

`set_node_property` verifies by read-back. `Coerce.values_equal` applies its
`epsilon` only to `TYPE_FLOAT`, `TYPE_DICTIONARY` and `TYPE_ARRAY`; `Vector3`,
`Vector2` and `Color` fall through to Godot's exact `==`. So a non-dyadic component
(e.g. `rotation_degrees = -35` round-tripped through radians → `-34.999996`)
reports a **false** `VALIDATION_ERROR` *after the value has already landed*.

- Use exactly-representable numbers — integers, `.5`, `.25` — for `position` and
  `transform`.
- Avoid `rotation_degrees`. Either set an exact `transform`, or rotate from the
  script's `_ready()`.
- On this error, do **not** assume failure: confirm with `godot_inspection_get_node_property`
  or by reading the `.tscn`.

## Step 3 — hand it over. Do NOT play-test

**The user tests their own games. That is not your job.** Do not call `play_scene`,
do not inject input, do not assert, do not screenshot, and do not look like you are
proving the game works. Every verification call is wall-clock the user did not ask
for — and in practice it is the *entire* cost of the task (see "Speed" below).

Your job ends at a saved scene. Instead of testing:

- confirm `ok_all: true` and that every `results[]` entry is `ok: true` — that is
  authoring correctness, not gameplay;
- `godot_scripts_get_parse_errors` on what you wrote — a syntax error is a build
  failure, and catching it is cheap and worth doing;
- `godot_inspection_get_scene_tree` to confirm nodes and scripts landed.

Then record it, then report it:

```powershell
& "$env:USERPROFILE\.config\opencode\scripts\godot-journal.ps1" -Append -Game "<name>" `
    -Project "<dir>" -Scene "res://<scene>.tscn" -Controls "<input>" -Status "built, not run" -Next "<next step>"
```

That journal is the game's memory across sessions (see "Continuity" below). Then
report what was built, the scene path, and how to run it (`F5`, or the Play
button). **Say plainly that you did not run it.** Never claim a mechanic works
because the scene contains it, and never imply it was tested.

## Only if the user explicitly asks you to play-test

Then — and only then — enable `runtime,input,testing`, and register the probe
autoload once per project (**required** for all live inspection and assertion):

```
godot_resources_edit_register_autoload(
    name="MCPRuntimeProbe",
    path="res://addons/godot_mcp/mcp_runtime_probe.gd",
    confirm=true)
```

Then:

```
godot_runtime_play_scene(scene_path="res://game.tscn")
godot_input_play_sequence(events=[...], delay_ms=...)
godot_testing_assert_node_state(node_path="/root/<Root>", property="...", expected=..., op="==")
godot_runtime_get_game_output(since_seq=0)     # runtime errors, print()
godot_runtime_capture_game_screenshot()
godot_runtime_stop_scene()
```

- Running-game node paths are **absolute**: `/root/<RootName>/Child`.
- `property:x` syntax is **not** supported — read the whole vector or a scalar.
- `assert_node_state` doubles as a **live reader**: pass a trivially-true op
  (`op=">=", expected=0`) and the returned `actual` is the current value.
- Events: `{"type":"action","action":"ui_right","pressed":true}`, or
  `{"type":"key","key":"Space","pressed":true}`, or `{"type":"mouse",...}`.
- **`play_sequence` is fire-and-forget, NOT blocking**: a 2000 ms hold returns in
  ~0.4 s. It schedules the events and returns. So a `play_sequence` followed
  immediately by a read inspects a game that has not moved yet — **wait in
  between**, or the test silently lies. There is no timer inside the code tool, so
  wait with a shell sleep (`Start-Sleep`) sized to the sequence plus a margin, or
  do the whole route in one call and wait once at the end.
- `delay_ms` is uniform and is the gap between **consecutive** events. A
  press/release pair with `delay_ms=954` is a 0.954 s hold — about 210 px at
  220 px/s.
- **Encode the whole route in ONE call.** With uniform gaps, a list of
  press/release pairs becomes a run of held legs separated by equal idle gaps, so
  total time = `events.length × delay_ms`. A 6-leg, 12-event call won a game in
  one shot; one call + one wait beats six call/wait pairs.
- Timing is approximate — a 1000 ms pulse measured 187–220 px. Aim at the pickup
  radius, not a dead-centre touch.
- `godot_testing_run_test_scenario` hardcodes `delay_ms=16`, so it **cannot hold**
  a key; use `play_sequence` for held input and `run_test_scenario` for tap-style
  assertions.
- **Give the probe a moment after `play_scene`.** An assert fired immediately can
  fail with "runtime probe is not connected", and a stale read can return the
  *previous* run's value. Wait ~0.5–1.5 s, and if a value looks wrong, re-read
  until two consecutive reads agree before believing it.
- `godot_runtime_capture_game_screenshot()` is the **only** way to see the
  rendered game. PowerShell `PrintWindow` captures the editor's Vulkan window but
  the playing game's window returns chrome over an empty surface.
- `play_scene` restarts the scene, so every run starts from the authored state.

When asked to test, prefer the built-in `ui_left`/`ui_right`/`ui_up`/`ui_down`/
`ui_accept` actions — they exist already, so no input-map edits are needed.

## Speed: where the time actually goes

Measured on a 4-core laptop with integrated graphics (i7-10610U, no discrete GPU):

| Operation | Cost |
|---|---|
| any MCP round trip | ~0.4–0.5 s |
| `run_commands`, per sub-command | ~8.7 ms (62 commands in 538 ms) |
| `play_sequence`, 2000 ms hold | returns in ~0.4 s — non-blocking |

A whole game — resources, a 43-node tree, 4 scripts, properties, save — is **one
~1.5 s batch**. The least a build can take is **one** call: skip the `dry_run`
unless the batch is large or destructive, because it doubles the call count for a
preview the user did not ask for.

**Testing is where all the time goes, and it is not yours to spend.** A session
that did play-test a 43-node game took **856 s across 182 calls, 180 of them
verification** — for a build that was 2 calls. Not testing is the single largest
speed win available, which is why the default is to hand off.

If you are *asked* to test, be surgical: assert a counter, a position and a HUD
string, encode the whole input route in one `play_sequence`, and stop once win and
lose are each proven once.

## Preconditions, and what to do when it breaks

**Everything above is one command**, and it is Step 0:

```powershell
& "$env:USERPROFILE\.config\opencode\scripts\godot-ensure.ps1" -ProjectPath "<project dir>" [-Create] [-Restart]
```

`godot-new-project.ps1` is the smaller piece it calls — addon + plugin + probe for
an existing project. Use it directly only when you already know the service and
editor are fine.

The addon is **per project** — a new project without this has no bridge.

| Symptom | Cause | Fix |
|---|---|---|
| godot tools missing entirely | the HTTP service is down | run `godot-ensure.ps1` (starts it), or `opencode reload` (~6 s) |
| `BRIDGE_DISCONNECTED` | no editor, addon missing, plugin off, or a *different* project open | run `godot-ensure.ps1`; pass `-Restart` if it just gained the addon |
| new project has "no plugin" | addon never copied / `[editor_plugins]` never written | `godot-ensure.ps1 -Create` — and never create projects in the project manager |
| exit code 4, or the bridge flaps between editors | two editors open, both dialling `:9080` | close one; the bridge is single-connection |
| `Tool '<name>' is not enabled` | toolset gated off | add it to the comma list in Step 1 |
| `PRECONDITION_FAILED: required=active_scene` | no `.tscn` open | `create_scene` (it can be in your batch) |
| `PRECONDITION_FAILED: required=play_session` | not playing | `play_scene` first |
| `PRECONDITION_FAILED: required=runtime_probe` | probe autoload missing | the register call under the explicit-test section |

**To check the service from a plain shell, with no opencode involved:**

```powershell
node "$env:USERPROFILE\.config\opencode\scripts\godot-mcp-probe.mjs"
```

It speaks MCP over HTTP to 9090, lists the tools and prints `bridge_connected`.
That is the command to run after a reboot or a suspected outage, because it cannot
be fooled by a stale client.

Never "simplify" the server back to a stdio `type: local` entry — opencode spawns
it multiple times and the losers lose the fixed bridge port (WinError 10048). It is
a single long-lived HTTP service by design.

## Report honestly

Say what you built, where the scene is, and that **you did not run it** — the user
does the testing. Give the launch step (`F5`). Do not describe assertions or input
you did not inject, and never claim a mechanic works because the scene contains it.

## Continuity: games need memory

A new session starts blank. Without a record it cannot tell which games exist, in
which project, with which controls, or what was left half-done — so it re-asks and
re-derives, which is the "extra steps" this skill exists to remove.

`godot-journal.ps1` is that record, at
`%USERPROFILE%\.config\opencode\games\journal.md` — plain append-only markdown,
one entry per build, no LLM and no database, so reading it is free:

```powershell
godot-journal.ps1 -Tail 5     # at the START of any game work
godot-journal.ps1 -Append ... # at the END of every build or edit
```

Read it **before** the health check, so a request like "add a double jump to the
platformer" resolves to a real project and scene instead of a question. Append even
for small edits, and put the real next step in `-Next`; the next session's first
move is often exactly that field.

`godot-ensure.ps1` also remembers the last project in
`%LOCALAPPDATA%\godot-mcp\last-project.txt`, so `godot-ensure.ps1` with no
arguments returns to the project you were last working on.
