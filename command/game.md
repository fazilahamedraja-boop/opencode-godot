---
description: Build a playable Godot game from a plain-language description, driving the live editor through the godot MCP (fast path)
---

Build this as a playable Godot game: $ARGUMENTS

**Follow the `godot-game-by-prompt` skill** — it is the authoritative recipe. `/game`
is only the explicit trigger; the skill auto-triggers on the same requests.

`$ARGUMENTS` may also be an edit to an existing game ("add a double jump to the
platformer"), in which case skip straight to the batched authoring call.

The short version, so the fast path is never re-derived:

0. **Readiness first** (this is what makes a cold session work):
   `$OG = "$env:USERPROFILE\.config\opencode\scripts"`, then `& "$OG\godot-journal.ps1" -Tail 5`
   and `& "$OG\godot-ensure.ps1"` — with **no arguments** it
   returns to the remembered project; add `-ProjectPath "<dir>"` for a different one
   and `-Create` for a new one. It starts the service, copies the addon, enables the
   plugin, launches the editor and **waits** for `BRIDGE CONNECTED`. A brand-new
   project must be made with `-Create`, not in the Godot project manager, or the
   plugin will be missing.
1. `godot_health_check` — require `bridge_connected == true`.
2. **One** enable call:
   `godot_enable_toolset("scene_edit,scripts,resources_edit,project,composite")`
   (append `physics,tilemap,animation,audio,theme_ui,scene_3d,particles` only if the
   game needs them). Never enable toolsets one at a time.
3. **One** build call: `godot_composite_run_commands([...], confirm=true, stop_on_error=false)`
   containing, in order: `create_resource` → `create_scene` → `create_node` →
   `write_script` → `set_node_property` → `attach_script` → `save_scene`.
   Do **not** split `create_scene` into its own call — a whole scene batches in one
   round trip (verified).
4. **Hand over — do not play-test.** Record it with
   `godot-journal.ps1 -Append -Game ... -Scene ...`, then report the scene path and
   press-F5 step, saying plainly that you did not run it.

Full detail — the param table, the exact-compare `VALIDATION_ERROR` gotcha, the
four-link readiness chain, the game journal, and the troubleshooting table — lives in
the skill.
