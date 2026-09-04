# Architecture

The application keeps UI projection, state transitions and native execution
separate. `main.zig` assembles the host; `app_controller.zig` exhaustively routes
messages and composes startup. Neither is a feature implementation registry.

## Feature boundaries

| Module | Responsibility |
| --- | --- |
| `app_types.zig`, `messages.zig` | Shared application contracts, independent of host composition |
| `workspace_actions.zig` | Attach/restore, worktree workflows, teardown coordination and project persistence |
| `terminal_actions.zig` | Terminal commands and application statuses |
| `settings_actions.zig` | Preference/profile queries, writes and navigation |
| `agent_actions.zig` | Tool discovery, launch preparation and titles |
| `sidebar_actions.zig` | Width persistence effects |
| `model.zig`, `.native` files | Read-only projections and declarative layout |

State modules (`git_workflow`, `terminal_controller`, `teardown_state`, editors
and persistence state) own transitions. Stores own records. Feature modules
may coordinate each other through named operations but do not import
`main.zig` or `app_controller.zig`. Native adapters never implement user-consent
policy. Do not add another framework layer to wrap a single operation.

## Git and teardown

`git_workflow.Request` and `Value` are typed contracts: booleans, paths, worktree
entries, a safety snapshot, or a classified error. Production has no porcelain
protocol; old-format fixture decoding is confined to `src/tests/`.

`git_host` owns one worker and copies request data before launching it. The
worker owns all libgit2 handles. Its SDK channel wakes the loop; only a matching
notification marks the lane ready. `git_service.Service(Executor)` consumes
completed results synchronously and starts the next admitted request. Its
executor can be replaced in tests. Every executor supplies `busy`, `start`,
`completed`, `release`, and `deinit`; borrowed worktree entries remain live
until `release` after the consumer returns.

Host event order is explicit:

1. Process SDK messages and geometry.
2. Drain the ready Git result.
3. Reconcile terminal/native callbacks.
4. Submit any newly admitted Git operation, including one admitted by a
   terminal-exit callback in step 3.
5. Finish sidebar interaction and persistence.

A second Git request is rejected, never queued. Shutdown joins the owned worker
before destroying its channel or stores. SDK journal replay of host-owned Git
results remains unsupported.

Removal waits for owned terminals, inspects the actual worktree HEAD, branch,
working/index state, submodules and unpublished history, and compares this to
the approved snapshot. The library adapter repeats inspection before pruning.
HEAD or safety changes return `changed` and require another review. Read errors
are errors, not invented dirty flags or commit counts. Force cannot bypass
worktree locks, identity checks or the approval snapshot. Detached commits are
compared against local and remote refs; attached branches against remote refs.
The dirty-state fingerprint includes paths, index object IDs and filesystem
size/mtime; it is a change detector, not a transaction lock against external Git
processes. External processes must not mutate a checkout during removal.

## Terminal ownership

`terminal_controller` is the only owner of tab lifecycle transitions, including
bulk close. `terminal_transport` selects Native SDK PTY effects or owned Ghostty
launch data. A monotonic tab identity protects native callbacks from recycled
PTY keys. `ghostty_host` maps callbacks and mounts views; `ghostty_bridge.m`
owns the embedded engine while `ghostty_view.m` owns AppKit input/IME/geometry.
Their private declarations live in `ghostty_native.h`; the public C ABI remains
in `ghostty_bridge.h`. The viewport uses an authored global key, never an
accessibility label, for native mounting.

Inactive worktrees and detached projects are collected only when no terminal
owns them. Snapshot reconciliation validates and reserves before mutation and
uses path indexes. Entity IDs are never reused. SDK effect keys use disjoint
families in `effect_keys.zig` and remain exactly representable in JSON.

## Settings and compatibility

Preference saves retain the submitted snapshot. Editors freeze mutations while
a write/reload is pending, and only a matching active completion commits state.
All navigation replacing a dirty profile draft goes through one consent gate,
including agent changes, new profile, close and reload.

Profile queries stage pages and atomically replace the visible store on success.
Failure retains the previous snapshot and offers reload. Profile codecs reject
malformed/oversized known fields and preserve unknown JSON fields. `profile_fields`
is the shared JSON/editor/validation schema; explicit CLI mapping stays in
`tool_launch`. Add tests for new fields and maintain the external JSON dialect.

## Verification and dependencies

Run `npm run verify`: Zig formatting, patch-inventory validation, application,
terminal, native policy tests, strict markup validation and ReleaseFast build.
Native renderer/viewport changes additionally require a real macOS window check;
canvas-only captures omit adopted NSViews. `-Dsmoke=true` uses a separate app
identity/database and worktree base for that check. `npm run format:native`
formats the owned Objective-C integration using `.clang-format` (clang-format
must be installed). The pinned SDK patch inventory is in `docs/sdk-patches.md`.

Keep fixes separate from future feature changes. Never write Electron Canopy's
database. Raw Ghostty configuration remains host-only. libgit2 is statically
linked from hash-pinned sources; network transports, hooks and external Git
filters are not enabled by this local integration.
