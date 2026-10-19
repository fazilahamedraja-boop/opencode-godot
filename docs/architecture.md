# How this works

Four processes, one chain. Every link can fail on its own, and three of them
fail with the same message from inside the AI client ("godot tools missing" or
`BRIDGE_DISCONNECTED`). That is the whole reason this repo exists.

```
opencode  ──HTTP──▶  godot-editor-mcp  ──WebSocket──▶  Godot editor  ──▶  your project
 (AI)                (service, :9090)      (:9080)       (addon dials out)
```

## The four links

| # | Link | Lives in | Breaks when |
|---|------|----------|-------------|
| 1 | HTTP service on `127.0.0.1:9090` | `godot-editor-mcp` (PyPI) | nothing is running, or two copies race for the bridge |
| 2 | Addon files inside the project | `<project>/addons/godot_mcp` | the project was created in the Project Manager (it starts empty) |
| 3 | Plugin enabled in `project.godot` | `[editor_plugins]` | the editor was already open when the entry was written |
| 4 | A **running editor** on **that** project | the Godot process | a different project owns the bridge, or no editor is open |

`scripts/godot-ensure.ps1` walks all four, fixes what it can, and does not
return success until the addon has actually attached.

## Why one long-lived service instead of a stdio server

The editor side is a **WebSocket client**: the addon dials out to the service
and reconnects with backoff. That means the *service* owns the listening socket
on `:9080`, and only one process can own it.

Some MCP clients spawn a stdio server more than once. opencode did exactly that
here — three copies, roughly three seconds apart. The first won the port; the
copies opencode actually talked to lost it, reported `bridge_bind_error 10048`,
and every addon tool was dead while the server itself looked healthy.

Running **one** service and pointing the client at it as a remote server removes
the race:

```json
"mcp": {
  "godot": { "type": "remote", "url": "http://127.0.0.1:9090/mcp" }
}
```

It also survives restarts better: when the service dies, the addon reconnects by
itself within a few seconds, and the client reconnects on its next call — no
client reload needed. Only a failure at *client startup* is sticky.

## Why "editor is running" is not "bridge is connected"

Listening on `:9080` proves the **service** is up. It says nothing about Godot.
The proof that the editor is attached is an established connection *to* `:9080`
owned by a Godot process:

```powershell
Get-NetTCPConnection -RemotePort 9080 -State Established
```

Because the bridge is single-connection, two open editors do not conflict
visibly — one silently loses. That looks identical to a missing plugin.

## Why the addon must be copied into the project

The addon is `EditorPlugin` code inside `res://addons/godot_mcp/`. Godot's
Project Manager creates an empty project, so new projects have no `addons/`
directory at all. `scripts/godot-new-project.ps1` copies the pinned addon in,
writes `[editor_plugins]`, and registers the `MCPRuntimeProbe` autoload.

Godot reads `[editor_plugins]` when the editor **opens**. A script that edits
`project.godot` while the editor is running changes nothing until that project is
reopened — and the reload cannot be triggered over the bridge, because the bridge
is what is missing. `godot-ensure.ps1 -Restart` exists to break that loop.

## Why a journal instead of a database

Game work has no memory of its own: a new session does not know which games
exist, where they live, what the controls are, or what was half-finished. The
journal is an append-only markdown file at:

```
%USERPROFILE%\.config\opencode\games\journal.md
```

Deliberately not an LLM and not a database, so reading it is free and
deterministic. `-Tail N` at the start of game work, `-Append` at the end. That is
what makes "add a double jump to the platformer" resolve to a real project and
scene instead of a question.

## Where the time goes

Tool round trips dominate: an MCP call is ~0.4-0.5 s, and a batched
`run_commands` call is ~8.7 ms per sub-command. So a 43-node game is about
**1.5 s of tool time in two calls** — one dry run, one apply. If a session feels
slow, it is almost always verification, not authoring.
