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
