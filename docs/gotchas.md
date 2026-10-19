# Gotchas

Everything here was hit for real while driving a live Godot 4.7.2 editor from an
agent. Each one cost time, and none of them announce themselves clearly.

## 1. A false `VALIDATION_ERROR` after a vector write succeeds

`Coerce.values_equal` (`addons/godot_mcp/type_coerce.gd`) applies its `1e-5`
tolerance to `float`, `Dictionary` and `Array`. `Vector2`/`Vector3`/`Color`/
`Rect2` fall through to Godot's **exact** `==`.

The property is already set when the comparison runs, so `rotation_degrees = -35`
stores correctly, reads back as `-34.999996` through the degree→radian→degree
round-trip, and the tool reports:

```
VALIDATION_ERROR: rotation_degrees expected -35, got -34.999996
```

**The write landed.** Confirm with `godot_inspection_get_node_property` or by
reading the `.tscn`; re-sending the same value fails identically.

Workarounds:
- keep `position`/`transform` values exactly representable (integers, `.5`, `.25`);
- set awkward rotations from a script's `_ready()` instead of in a batch.

**Fixed upstream?** No, not as of the vendored `2026.10.15`. This repo carries a
verified patch instead:

```
addon/patches/0001-values-equal-float-components-with-epsilon.patch
```

It gives `values_equal` the same `epsilon` for `Vector2`/`Vector3`/`Vector4`,
`Color`, `Rect2`, `Plane`, `Quaternion`, `Basis`, `Transform2D`/`Transform3D` and
the packed float/vector/color arrays — while leaving ints, strings, sizes and
genuinely different values exactly as strict as before. 32 headless cases on
Godot 4.7.2: the proposal passes all 32, the vendored code gets **17** of them
wrong, and nothing that should differ starts comparing equal.

It is an **upstream proposal**: `install.ps1` copies `addon/godot_mcp` verbatim
and never applies it, so the vendored tree stays pristine. To use it on your own
installed copy (same command as verified, with your checkout in place of
`<repo>`; run it from the config root, and note it refuses to apply twice):

```powershell
cd $env:USERPROFILE\.config\opencode
git apply -p2 --directory=godot-mcp-addon <repo>\addon\patches\0001-values-equal-float-components-with-epsilon.patch
```

That is the *editor* verifier. The runtime probe keeps its own copy of this
comparison (`mcp_runtime_probe.gd`, `_values_equal`) and this patch does not
touch it: it drives change detection, not write verification, so a rounding
difference there is a benign extra sample rather than a failed write.

## 2. Object-typed properties only accept a resource path

`mesh`, `material_override`, `shape`, `environment` and friends accept **only** a
`res://….tres` path or `null` — never an inline value. The `.tres` does **not**
need its own call: a `create_resource` earlier in the *same* batch binds
correctly.

## 3. Enabled toolsets reset when the service restarts

Toolset gating is in-memory in the long-lived service. After a restart a fresh
client sees **24 tools** (`core` + `inspection`) no matter what was enabled
before. Re-enable in one call:

```
godot_enable_toolset("scene_edit,scripts,resources_edit,project,composite")
```

Do **not** set `GODOT_MCP_DEFAULT_TOOLSETS` to seed this: the full catalog is 189
tools, and even `author,playtest,composite` exposes ~173 of them in every
session, including sessions that have nothing to do with games.

## 4. `play_sequence` is fire-and-forget

A `play_sequence` call returns long before the game has moved — a 2000 ms hold
comes back in ~384 ms. Reading state immediately after it inspects a game that
has not moved yet, which silently invalidates a test.

Also: `delay_ms` is uniform, so a press/release list becomes held legs with equal
idle gaps (total = `events.length × delay_ms`). That means one whole multi-leg
route fits in **one** call.

## 5. The runtime probe needs a moment, and can be stale

After `play_scene`, the probe takes ~0.5-1.5 s to attach. An immediate assert
fails with "runtime probe is not connected", and a stale one can return the
*previous* run's value. Re-read until two consecutive reads agree.

## 6. Two editors cannot share one bridge

Single connection. The second editor loses silently, and the symptom is
indistinguishable from a missing plugin. Close the extra editor, or point the
other project at a different service/port.

## 7. Killing the service does not need a client reload

The addon reconnects by itself (`_RETRY_MIN 0.5` → `_RETRY_MAX 5.0`, so within
about five seconds). opencode's MCP client recovers on the next call. This is
*not* true of a failure at client startup, which is sticky until the client is
reloaded.

## 8. One editor window can be two processes

Godot's `*_console.exe` is a small launcher that starts the real editor as its
own child, so a single window shows up twice in `Get-Process` / CIM queries.
Never count processes to decide how many editors are open, and never wait on the
launcher's PID: the **child** is the process that owns the bridge socket.
`godot-ensure.ps1` drops the launcher for exactly this reason.

Related: if you point `godot-ensure.ps1` at a project while another editor is
open, the refusal only fires when that editor is actually attached to *this*
bridge port. Editing the dial port (via `GODOT_MCP_BRIDGE_PORT` +
`GODOT_MCP_BRIDGE_URL`) lets two services coexist on one machine.

## 9. A fresh Windows profile refuses to run any of this

The default execution policy is `Restricted`, so `.\install.ps1` dies with
*"running scripts is disabled on this system"*. A script that arrived inside a
downloaded ZIP is blocked twice over, because Mark-of-the-Web also blocks it
under the more common `RemoteSigned`. Both are per-process problems with a
per-process answer:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File <script>
```

`install.cmd` and `uninstall.cmd` exist only to do that, and the skill uses the
same form for `godot-ensure.ps1` and `godot-journal.ps1`, because the agent's
shell can be just as locked down as the user's.

## 10. An existing MCP entry can point at a dead port

A `godot` entry in `opencode.json` is not proof that opencode can reach the
service. If the entry's URL and the service port diverge — typically after
changing `GODOT_MCP_HTTP_PORT` — the tools simply never appear, and nothing
fails loudly. `godot-doctor.ps1` compares the two, and `install.ps1
-PatchOpencode` rewrites the URL to the current port instead of reporting
"already configured".

## 11. MCP entries live one level down (`mcp.servers`)

opencode's config schema keeps MCP servers under `mcp.servers`, and marks the flat
`mcp.<name>` form `"deprecated": true` — but it still parses, so both shapes are in
the wild. Reading only the flat form is what made the doctor report
`opencode.json ... godot entry: MISSING` and exit `NOT READY` on a machine where the
`godot` tools were working: the entry was there, one level down. `install.ps1` and
`godot-doctor.ps1` read both, and `-PatchOpencode` puts the entry back into whichever
shape the file already uses (a new file gets `mcp.servers`). If you move an entry by
hand, put it in the same object as the other servers — an entry at the wrong depth is
valid JSON that opencode never reads, and the doctor will say so.

## 12. A PowerShell 7 parent strips `Get-FileHash` from a 5.1 child

`PSModulePath` is inherited. Start `install.cmd` from a PowerShell 7 terminal — or
from CI, or from any pwsh parent — and the Windows PowerShell 5.1 child it spawns
resolves `Microsoft.PowerShell.Utility` out of *PS7's* directory first. That
assembly is a .NET Core one, it does not load under .NET Framework, and the
cmdlets defined in it — `Get-FileHash` among them — are simply absent from the
session, while `Get-ChildItem`, `Copy-Item`, `ConvertTo-Json` and the rest keep
working. So the failure is late and confusing: a *first* install succeeds, then an
**upgrade** dies partway through replacing files with

```
Get-FileHash : The term 'Get-FileHash' is not recognized as the name of a cmdlet,
function, script file, or operable program.
```

Reproduced end to end on a 5.1.26100.9444 child under pwsh 7.6.7: the same
`install.cmd <cfg> -NoService -NoAutostart` exits 0, then 1. Your own shell is
fine either way — this only bites a *different* host's child.

The fix is not to repair the environment but to stop depending on module
autoloading for hashing: `install.ps1`, `godot-new-project.ps1` and
`godot-doctor.ps1` each carry a `Get-Sha256` that uses the .NET
`System.Security.Cryptography.SHA256` API and returns the same uppercase hex
`Get-FileHash` did, and a regression test asserts by AST that no `Get-FileHash`
call comes back. If you write automation around this repo, do the same and it
will not care which host started it. The general shape of the trap is wider than
hashing: any cmdlet that lives in a *module* can disappear in a child host, so
anything load-bearing belongs in the script itself, or in .NET.
