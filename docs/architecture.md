# Architecture

Canopy uses a small composition root and keeps state transitions separate from
Native SDK effects. Dependencies point toward domain state; domain modules do
not import `main.zig` or the native host.

## Layers

- `main.zig` assembles markup, migrations, the native host and process startup.
- `messages.zig` defines the typed UI/effect message contract.
- `model.zig` owns application state and read-only markup projections.
- `app_controller.zig` routes messages and performs Native SDK effects.
- State modules (`terminal_controller.zig`, `preferences_editor.zig`,
  `profile_editor.zig`, `project_persistence.zig`, `tool_registry.zig`,
  `workspace_dialogs.zig`, `teardown_state.zig`) own transitions without host
  process, file or database calls.
- Transport adapters (`git_libgit2.zig`, `git_host.zig`, `ghostty_bridge.m`) translate typed domain
  requests to platform operations.
- Stores and parsers (`workspaces.zig`, `profiles.zig`, `preferences.zig`,
  `ghostty_config.zig`) own bounded data and compatibility formats.

## Invariants

1. Git has exactly one operation in flight. A second request is rejected, never
   queued, and only the matching completion releases the lane.
2. Every terminal tab has a monotonic tab identity. PTY keys may be recycled
   only after the previous tab is retired.
3. Closing a project or worktree waits for all owned terminal callbacks before
   detach or Git removal starts.
4. Preferences and project snapshots commit only matching active writes.
5. Raw Ghostty configuration remains host-only because it may contain secrets.
6. Markup is a projection of model state; it does not own process lifecycle.

## Change workflow

Keep behavioral changes separate from structural refactors. Add state-machine
tests beside pure modules and application scenarios under `src/tests/`. Run
`npm run verify` locally before handing off a slice; it formats recursively,
runs the model/markup contract and terminal suites, checks Native markup, and
builds ReleaseFast. CI is intentionally outside the current PoC cleanup scope.

`git_libgit2.zig` implements the typed local requests through the pinned C API.
The native host starts `git_host.zig` only after lane admission, with copied
request data. One worker owns all libgit2 handles and result memory. A dedicated
SDK channel wakes the UI without polling; the host joins the completed worker,
dispatches the borrowed result synchronously, frees it and starts the next step.
The host also joins at shutdown. No worker touches the model or stores.
SDK session replay does not currently reproduce host-delivered Git results.

The build compiles hash-pinned libgit2 using CMake, with a static archive and
local repository support. No SDK modifications are needed. Hooks and external
filters are not run; network transports are disabled. Removal verifies linked
worktree identity, common repository, validity, lock state and (unless approved
force) dirty/submodule state immediately before pruning. The existing UI also
rechecks its safety snapshot after terminal shutdown.
