# Canopy Native SDK PoC

A small, runnable reimplementation of Canopy's core desktop shape using
[Native SDK](https://native-sdk.dev/): a projects/worktrees sidebar and native
terminal tabs. The shipped app uses no Chromium, WebView, or JavaScript runtime.

## What works

- empty-state onboarding with the native macOS folder picker;
- attaching and detaching folders or Git repositories, persisted in the app data directory;
- live discovery with `git worktree list --porcelain` and a project/worktree sidebar;
- creating a new branch and worktree under `~/canopy/worktrees`;
- preflighted removal of non-main worktrees, with dirty, unpublished-commit,
  and submodule warnings before explicit force consent;
- worktree-local tab lists and remembered active tab;
- dynamically allocated terminal sessions, limited by host resources rather
  than an application constant;
- the user's actual login shell started inside the selected worktree;
- terminal focus, input, resize, scrollback, selection, fonts, colors and Metal
  rendering handled by full embedded Ghostty on macOS;
- compact Canopy-inspired chrome with a sans-serif UI and a light/dark theme
  that follows the macOS appearance and accessibility preferences;
- an Electron Canopy-style Preferences dialog with matching 920px geometry,
  208px grouped navigation, compact typography, search, startup restore,
  appearance, and worktree defaults persisted transactionally in SQLite;
- a Canopy-style Tools section that discovers Claude Code and Codex through the
  user's login shell and launches them in the selected worktree;
- Electron-compatible Claude/Codex agent profiles with Default seeding, profile
  groups, create/update/delete flows, unsaved-change protection, and per-tool
  running-session counters;
- opening, activating, and closing terminal tabs;
- Cmd+W closes the active worktree's selected tab (including its PTY), not
  the window; it is inactive with no selected tab or while a modal is open;
- window geometry restore and hidden-inset native macOS chrome;
- terminal shutdown fencing: removal/detach waits for every owned PTY exit
  before mutating Git state or hiding the project.

## Run

Requirements: macOS 13+, Xcode with Metal tools, Node.js 24+, and Zig 0.16.0.

```sh
npm install
npm run check
npm run dev
```

The first build applies the versioned Canopy Native SDK patch and compiles the SDK and Ghostty sources,
so it is much slower than subsequent incremental builds.

Other useful commands:

```sh
npm test
npm run build
npm run verify
```

`package.json` pins the npm CLI and Node/npm toolchain. Native SDK itself and
the lazy Ghostty terminal dependency remain reproducibly pinned in
`build.zig.zon`, where Zig resolves build dependencies.

## Architecture

### Full Ghostty renderer and configuration

The macOS app embeds the full pinned GhosttyKit library, not only libghostty-vt.
Ghostty owns PTY transport, emulation, CoreText font discovery/fallback, glyph
shaping, Metal rendering, shell input and terminal queries. Native SDK owns the
surrounding UI. Inspect the read-only configuration snapshot without opening a
window, applying directives or modifying application storage:

```bash
./zig-out/bin/canopy-native-sdk-poc --inspect-ghostty-config
```

`src/ghostty_config.zig` owns source bytes, ordered directives and diagnostics.
It loads XDG `ghostty/config` then `ghostty/config.ghostty`, followed by the
equivalent macOS Application Support paths. `XDG_CONFIG_HOME` overrides the
default `~/.config`. Deferred `config-file` includes support relative/absolute
paths, `~/`, optional `?` files, resets, and canonical-path cycle detection.
Themes are a lower-priority layer, resolved from XDG `ghostty/themes`, then
Ghostty resource directories (`GHOSTTY_RESOURCES_DIR` or standard installation
locations). Both `light:...,dark:...` branches are retained separately.

The reader preserves unknown keys, repeated values, explicit resets and source
line numbers. It is not yet Ghostty's complete typed validator/default resolver:
conditional directives beyond paired themes, CLI overrides and hot reload are
not interpreted by the snapshot inspector. The renderer loads the discovered
user files through Ghostty's typed configuration API, including themes, fonts,
palette, padding, cursor options and custom shaders. Config is kept outside the
UI model; diagnostics never dump arbitrary option values.
Limits protect startup from malformed inputs: 256 KiB/file, 2 MiB total, 64 file
attempts, 16,384 entries and 128 diagnostics. No config files are created or
rewritten, including when no default config exists.

### Application ownership

The implementation mirrors Canopy Desktop's important ownership boundary:

```text
project -> worktree -> terminal tabs -> native PTY
```

`src/main.zig` owns the root model, typed effects, and orchestration. Pure
boundaries keep data handling out of that reducer: `db_page.zig` decodes bounded
SQLite pages, `tool_launch.zig` builds validated Claude/Codex argv and
environment overlays, and `terminal_tabs.zig` owns terminal metadata, PTY-key
reuse, and bounded tab projection. `src/app.native` is the small composition
root; focused templates in `src/components/` render the titlebar, project
sidebar, terminal workspace, empty state, and operation dialogs. One embedded
component inventory feeds both Debug and ReleaseFast, preventing their import
sets from drifting. ReleaseFast uses `CompiledMarkupImports` with no runtime
parser or file watcher; Debug builds retain import-aware hot reload. On macOS,
`ghostty_host.zig` reconciles tab lifecycles with `ghostty_bridge.m`, a small
AppKit adapter for the pinned C API. Each tab owns a Ghostty surface and PTY;
only the selected surface is adopted into one Native SDK view container.
Background surfaces are marked occluded; switching does not restart processes.
The native container is detached while any modal is open. Tabs from
another worktree remain alive but are filtered from the current tab strip, so
switching worktrees restores that worktree's last active tab.

`npm test` also runs the real Ghostty session and terminal painter suites via
`zig build test-terminal`. The upstream SDK-wide tests use an inert VT seam,
so they are not sufficient to verify alternate screens or full-screen TUI
rendering in the legacy backend. These suites remain regression coverage, not
proof of the new Metal renderer. Full-renderer verification requires a real
macOS window; Native SDK's canvas screenshot does not capture adopted NSViews.

Attached directory paths are stored under the platform app-data directory. At
startup missing paths are discarded, repositories are rediscovered, and plain
folders remain valid projects. Detach changes only Canopy state; it never
deletes project files or Git worktrees.

Persistence writes are serialized, coalesced to the newest snapshot, and use
Native SDK's atomic file replacement inside the permitted app-data root. The
folder picker stays disabled until the startup snapshot has been restored.

Worktree creation validates the branch name, rejects an existing target or
local branch, creates the branch, then checks it out. If checkout fails, the
branch is deliberately retained and Git state is refreshed; avoiding automatic
branch deletion is safer when other Git clients may be active concurrently.
Removal accepts only a discovered, non-main worktree and keeps its branch.
After the user confirms removal, owned PTYs are closed and the complete safety
preflight runs again; any changed result returns to the confirmation dialog.

All Git subprocesses share one zero-backlog execution lane. A command retains
the lane until its matching exit result is delivered; UI mutations are disabled
in the meantime and extra requests are rejected instead of queued. Native SDK
does not impose an app-side process timeout, so slow Git operations can finish
naturally without spawning polling or retry work on the host.

Preferences use Electron Canopy's compatible `preferences(key TEXT PRIMARY KEY,
value TEXT NOT NULL)` table and text-encoded values. The current native slice
shares the `reopenLastWorkspace` and `worktrees.baseDir` keys; its appearance
override uses the namespaced `native.appearance` key. The database lives at the
Native app's own platform data path (`tech.itsol.canopy.native-poc/app.db`) and
runs in WAL mode. It deliberately does not write Electron Canopy's production
database: that database also contains later application migrations and
encrypted values tied to Electron's secure storage. Keeping the file separate
makes both apps safe to run concurrently while preserving an import-compatible
schema for a later migration tool.

Agent profiles use Electron Canopy's `agent_profiles` columns, indexes,
`prefs_json` field names, ordering, and last-profile deletion guard. Claude maps
`model`, `permissionMode`, `effortLevel`, `appendSystemPrompt`, `baseUrl`,
`provider`, `customEnv`, and `settingsJson`; Codex maps `model`, `approvalMode`,
`sandbox`, `fullAuto`, `dangerouslyBypassApprovalsAndSandbox`, `profile`,
`baseUrl`, `customEnv`, and `settingsJson`. Non-default profile names are carried
into terminal tab labels, for example `Claude Code (Work)` and `#2` for another
session with the same profile.

Tool commands and worktree paths stay separate argv entries. Discovery runs
`/usr/bin/which` inside the user's actual login shell and retains the resulting
absolute executable path; PTY launch reuses that exact path inside the same
login environment, so another global installation cannot win through a
different `PATH`. `terminal_launch.zig` serializes argv using POSIX single-quote
escaping for Ghostty's macOS login wrapper; configured values cannot become
shell syntax. Per-profile environment values retain the protected system,
linker, runtime, proxy/TLS, Git/SSH and editor variable filter. The handoff owns
its command/environment until surface creation, then releases them; Ghostty
copies the environment into its own session. Raw values never enter UI rows.
Inherited `NO_COLOR` from the app launcher/build tool is removed in the PTY
child (not globally). An explicit `NO_COLOR` in a profile or Ghostty `env`
configuration remains authoritative.

Native SDK/CLI is pinned to `0.10.1` by `package-lock.json`. The reproducible
patch in `patches/` replaces its fixed four-session tables with dynamic stores
and serves every macOS PTY from one `kqueue` reactor. It also adds bounded,
slot-owned per-session environment overlays so agent configuration never needs
to appear in process argv, and answers terminal Device Attributes queries so
shells such as fish do not stall during capability detection. Ghostty remains
pinned to
`7aa9591746ffa4d2eee458960c76554352832595` in `build.zig.zon`.

Ghostty owns the terminal identity and bundled terminfo resources, with
`COLORTERM=truecolor`. Fonts and colors now come from Ghostty configuration,
independently of the surrounding Canopy UI theme.

`scripts/build-ghostty.mjs` builds GhosttyKit from the hash-verified Zig source
dependency, caches the combined static library under `zig-out/ghostty`, and
installs runtime resources beside the executable in `zig-out/share/ghostty`.
Keep that directory when distributing the binary; a macOS bundle should carry
it at `Contents/Resources/ghostty`, with `share/terminfo` copied alongside as
`Contents/Resources/terminfo`. First compilation is substantially slower.

## Rendering and resize diagnostics

The header sidebar button toggles the docked project rail. Its user-selected
width is stored in logical points, not a window percentage. Below 960 points
the rail collapses automatically; the same button reveals it over the terminal.
Escape, an outside click, selecting a worktree or launching a sidebar tool
closes the overlay. Returning to a wide window restores the dock unless it was
manually collapsed. Disclosure motion lasts 180 ms, honors Reduce Motion and
requests frames only while moving. The native terminal is cropped behind the
overlay without resizing its PTY or stopping its process.

The Canopy SDK patch keeps the canvas frame clock active in AppKit tracking
modes using a cancellable, one-shot common-mode timer. It uses the display's
30–120 Hz cadence rather than a separate fixed 60 Hz application timer, and
still coalesces requests instead of queuing missed frames. Metal canvas presents
follow the [Core Animation transaction contract](https://developer.apple.com/documentation/quartzcore/cametallayer/presentswithtransaction),
and stale-size textures are retained rather than presented as blank resize frames.
Ghostty's own renderer remains independent; its adapter only sends DPI, display
identity and pixel-size changes when those values actually change.

`geometry_updates.zig` retains only the newest window size and sidebar fraction.
The application consumes them on the next canvas frame instead of rebuilding
the whole widget tree for every intermediate mouse event. Native view
autoresizing keeps the Ghostty container fluid in between canvas frames; its
final frame still comes from the authoritative widget layout.

Terminal surface focus is synchronized separately from Ghostty's app focus:
only a visible selected surface whose responder, window and application are
active can be focused. Window/app notifications pause background animation
without polling, stealing keyboard focus or stopping PTY input/output. Switching
tabs, minimizing, detaching the renderer for a modal and reactivating the window
all use the same edge-deduplicated policy. `CANOPY_GHOSTTY_ACTIVITY_TRACE=1` logs
those transitions only (no terminal contents). Measure idle energy in ReleaseFast
without automation or GPU verification enabled. A focused terminal with custom
shaders can still animate according to Ghostty's `custom-shader-animation`
setting; Canopy does not rewrite or silently override that configuration.

An activating click in the terminal claims keyboard focus without click-through
to the TUI. For a manual focus regression check, focus a sidebar control, switch
to another app, then click the terminal once and type. Repeat after closing
Preferences and switching tabs; clicks on chrome must not focus the terminal.

Canvas raster caching admits layout translations, including float32 roundoff
around identity, but not real scaling/rotation/shear. The original transform is
applied without snapping. The cache's existing 64 MiB budget remains unchanged.
The experimental SDK GPU compositor remains off: the initial benchmark was
slower than the CPU path for this UI. Duplicate backgrounds under the native
terminal surface are omitted.

To repeat a bounded CPU-stage benchmark, launch an automation-enabled build,
open one terminal, and leave the window size unchanged during the measurement:

```sh
npm run dev:automation
# In another terminal, from this repository:
npm run perf:sidebar -- /path/to/the/running/apps/working-directory 24
```

The script prints per-stage p50/p90/max timings and viewport dimensions. Compare
the same viewport and project set; CLI/IPC gaps make the `interval` field unsuitable
as an FPS measurement. `NATIVE_SDK_GPU_DRAW_TRACE=1` attributes native raster cost.
`NATIVE_SDK_GPU_VERIFY_INCREMENTAL=1` compares dirty updates to an independent
uncached full redraw; its extra rendering must not be included in performance
measurements. `max_delta`/`changed_bytes` distinguish 8-bit antialias rounding
from significant geometry errors. `npm test` also covers the native frame clock
in tracking mode and the raster/presentation admission policy.

## Known PoC boundaries

- Native SDK is pre-1.0; this PoC carries a focused patch that should eventually
  become a maintained fork or upstream contribution.
- Full Ghostty embedding is macOS-only in this slice. The C API is internal and
  revision-bound; updating Ghostty requires reviewing the AppKit adapter.
- Ghostty window-management actions (splits, new windows, fullscreen, quick
  terminal) are not implemented by Canopy. Terminal actions and new/close tab
  bindings are handled; this is not the complete Ghostty application UI.
- Configuration is loaded at startup, not hot-reloaded. Canopy's explicit
  shell/tool command and worktree override Ghostty's default command/directory.
- Tab metadata is not persisted yet; terminal processes are intentionally not
  restorable sessions.
- Worktree creation currently covers new local branches only; attaching an
  existing branch and choosing a base branch are not implemented yet.
- Preference compatibility currently covers startup restore and the worktree
  directory. Electron-only encrypted credentials are intentionally untouched,
  and terminal typography is configured in Ghostty's config file.
- Claude/Codex API keys currently use the CLI's own login or inherited process
  environment. Native SDK has an OS credential store, but its current text
  control has no secure model-free password binding, so the PoC does not expose
  an unsafe secret field. Codex `settingsJson` is persisted compatibly; Canopy's
  hook server and `.codex/hooks.json` ref-counted lifecycle remain future work.
- Closing a live tab keeps it in `closing` until Ghostty surface teardown
  completes. Callbacks use never-reused tab identities, preventing a delayed
  callback from changing a newly opened tab that recycled a legacy PTY key.

## Next production slice

1. persistent per-worktree tab metadata and lazy session restore;
2. existing/base branch choices during worktree creation;
3. reopen-closed-tab history;
4. virtualized tab chrome, keyboard shortcuts, and tab reordering;
5. split panes and cross-platform epoll/IOCP reactors.
