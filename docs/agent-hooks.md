# Agent hooks

Native Canopy observes Claude Code and Codex sessions launched from its agent
buttons. The implementation ports the hook/session concepts from Electron
Canopy's `AgentHookServer`, `AgentSessionManager`, adapters and renderer state.
It does not read or modify Electron's database.

## Data flow and ownership

1. `tool_launch` builds per-invocation settings with `agent_hook_config`.
2. The terminal starts in an owned pending-launch state. No agent process runs
   before its hook route exists.
3. `agent_hook_host` starts one loopback listener, registers the monotonic tab ID
   with a random 256-bit token and appends the protected environment variables.
4. The existing terminal transport starts the process (full Ghostty on macOS).
5. Command hooks stream stdin to HTTP using the system `/usr/bin/curl`. The
   HTTP worker authenticates, parses and normalizes the event, then posts a
   bounded packet through a Native SDK channel. It never touches model state.
6. `agent_actions` accepts a packet only for its live, registered tab.
   `agent_state` handles lifecycle transitions, counters and attention.
7. Closing/exited/failed tabs revoke their route. Cancelling a pending launch
   releases it without waiting for a process that was never started. App
   shutdown stops and joins the HTTP thread before destroying SDK channels.

The transport ID is the native tab ID, not an agent's conversation ID or a
recycled PTY key. The reported conversation ID is tracked separately. Child
sessions cannot idle or overwrite their parent's state. An explicit `clear`
can bind a new conversation; starting/resuming another conversation should use
a new native tab. Same-worktree sessions have independent credentials and
configuration, with no shared file/refcount to restore.

## Configuration and compatibility

Validated against the contracts of Claude Code 2.1.261 and Codex CLI 0.153.2.
Codex 0.153.2's `hooks/src/engine/discovery.rs` loads TOML hooks from the
`SessionFlags` layer. Canopy therefore uses `--enable hooks --config 'hooks=…'`.
It does not write `.codex/hooks.json`, `.gitignore`, `config.toml`, or `CODEX_HOME`.
Existing project/user hook layers remain active and retain their trust policy.
Older Codex versions without session-layer TOML hooks need an upgrade.

Claude receives inline `--settings` JSON. Profile settings are preserved and
Canopy handlers are appended to existing event arrays. A provided profile
`statusLine` is preserved; otherwise Canopy installs its observer for model,
context and cost metrics. Both agents retain their own hook trust and managed
policy checks. Canopy never bypasses trust prompts or approves tool requests.
If policy disables hooks, the card stays at “Waiting for hooks”.

Protected child variables: `CANOPY_HOOK_PORT`, `CANOPY_HOOK_PATH`,
`CANOPY_HOOK_TOKEN`, `CANOPY_HOOK_COMMAND`, `CANOPY_STATUS_COMMAND`.
Profiles cannot override these. The commands contain trusted application code;
no prompt/tool-input strings are interpolated into shell source. Tokens are
held in the native host and private launch environment, never projected to UI.

Each observer finishes within curl's two-second network timeout and always
exits successfully without stdout or hook decisions. Tracking failure must not
block an agent. Existing user hook handlers can still enforce their own policy.

## UI

Agent tabs show waiting/idle/thinking/tool/permission/compacting/error/ended
status. A 32 px footer uses compact, content-sized groups at 12 px edge insets:
state/model on the left, worktree context and operation info on the right.
One flexible spacer separates the groups; there are no proportional columns.
All text stays on one line and truncates within bounded widths. At narrower
widths, secondary fields disappear: model/worktree name below 720 px, usage
below 1100 px, and tool/counter/full path details below 1400 px. The native
window minimum is 860 px; footer geometry is also checked down to 480 px.

The Activity button, panel and stored event history have been removed. Current
state, counters and the last bounded tool detail remain; prompts, raw shell
commands, tool results and transcripts are not retained. Zero-valued counters
are omitted from the footer. Existing Native SDK fonts, colors and interaction tokens
are retained; changing status does not animate or shift the worktree group.
The terminal starts immediately beneath the tab strip. Subagent identities
are bounded to 16; task-completed events are counted. Electron's task inspector,
resume UI and OS notifications remain outside this slice.

Attention is retained for background completion, notification, error and
permission events. Viewing the tab clears unread attention; permission/error
status remains visible until lifecycle events change it. Worktree status is
aggregated with priority permission > error > working > idle > waiting > ended.
Worktree rows stay 28 px tall: a state icon replaces the branch icon, and a
hover tooltip and accessibility label expose the full status. Shapes distinguish
waiting (clock), thinking (ellipsis), tool use (wrench), permission (pause),
compaction (refresh), idle/ended (check circle), and errors (alert).
State survives tab/worktree switches but is not persisted across app restarts,
consistent with the current nonpersistent terminal sessions.

## Receiver limits and failure behavior

- Binds `127.0.0.1` on an ephemeral port, never an external interface.
- Authenticates each route with a constant-time token comparison.
- POST only; rejects duplicate auth/length and transfer-encoding headers.
- Eight concurrent connections, 8 KiB headers, 1 MiB body, two-second deadline.
- One poll thread, no thread per request; a slow connection does not block others.
- SDK channel backpressure returns HTTP 503 and exposes dropped-event counts as
  “Tracking gap” on all live sessions (loss is reported for the shared channel);
  no raw payload or auth token is logged.
- Closing/revoked routes return 404. Malformed JSON returns 400.

Agent hook payloads are observations, not an authoritative scheduler. Displayed
status reflects the most recent normalized lifecycle event. Status-line metrics
are optional; Codex has no equivalent metrics endpoint in this integration.

## Verification

`npm run verify` includes pure normalization/state/config tests, real loopback
HTTP/auth/framing tests and host registration/cleanup tests with two sessions in
one workspace. Test scripts can use `--dump-agent-hooks=claude` or
`--dump-agent-hooks=codex` to inspect the generated default settings without
starting an agent or exposing credentials. The live-window smoke test uses
`-Dsmoke=true` and fixture agents; it does not require an inference request.

Sources:
- Electron reference: `~/GIT/canopy-code/src/main/agents/` and
  `src/renderer/src/lib/agents/agentState.svelte.ts`.
- https://code.claude.com/docs/en/hooks
- https://code.claude.com/docs/en/statusline
- https://github.com/openai/codex/blob/rust-v0.153.2/codex-rs/hooks/src/engine/discovery.rs
- https://github.com/openai/codex/blob/rust-v0.153.2/codex-rs/config/src/hook_config.rs
