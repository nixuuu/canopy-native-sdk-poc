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
- terminal focus, input, resize, scrollback, selection, ANSI colors, and rendering
  handled by Native SDK's `libghostty-vt` integration;
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
- window geometry restore and hidden-inset native macOS chrome;
- terminal shutdown fencing: removal/detach waits for every owned PTY exit
  before mutating Git state or hiding the project.

## Run

Requirements: macOS 11+, Node.js 24+, and Zig 0.16.0.

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

The implementation mirrors Canopy Desktop's important ownership boundary:

```text
project -> worktree -> terminal tabs -> native PTY
```

`src/main.zig` owns the model and process effects. `src/app.native` is the small
composition root; focused templates in `src/components/` render the titlebar,
project sidebar, terminal workspace, empty state, and operation dialogs. Their
sources are embedded in the binary. ReleaseFast uses `CompiledMarkupImports`
with no runtime parser or file watcher; Debug builds retain import-aware hot
reload. Native SDK owns PTY transport and terminal emulation behind each numeric
key. Tabs from another worktree remain alive but are filtered from the current
tab strip, so switching worktrees restores that worktree's last active tab.

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
different `PATH`. No configured value is interpolated into shell source.
Per-profile environment values use a bounded Native SDK PTY environment
overlay, with the same protected system, linker, runtime, proxy/TLS, Git/SSH,
and editor variable filter as Electron Canopy. The overlay is copied into the
PTY request, merged over the host environment, and securely wiped after the
child consumes it.

Native SDK/CLI is pinned to `0.10.1` by `package-lock.json`. The reproducible
patch in `patches/` replaces its fixed four-session tables with dynamic stores
and serves every macOS PTY from one `kqueue` reactor. It also adds bounded,
slot-owned per-session environment overlays so agent configuration never needs
to appear in process argv, and answers terminal Device Attributes queries so
shells such as fish do not stall during capability detection. Ghostty remains
pinned to
`7aa9591746ffa4d2eee458960c76554352832595` in `build.zig.zon`.

Every PTY advertises `COLORTERM=truecolor` while retaining the widely available
`xterm-256color` terminfo contract. The renderer preserves libghostty-vt's full
ANSI/256-color palette and OSC overrides verbatim; `38;2`/`48;2` RGB colors pass
through without quantization or theme-driven dimming.

## Known PoC boundaries

- Native SDK is pre-1.0; this PoC carries a focused patch that should eventually
  become a maintained fork or upstream contribution.
- `ptySpawn` has no public `cwd` option. The PoC passes the worktree and selected
  login shell as separate argv items to a minimal `/bin/sh` bootstrap, avoiding
  path interpolation while preserving fish/zsh/bash startup behavior.
- Tab metadata is not persisted yet; terminal processes are intentionally not
  restorable sessions.
- Worktree creation currently covers new local branches only; attaching an
  existing branch and choosing a base branch are not implemented yet.
- Preference compatibility currently covers startup restore and the worktree
  directory. Electron-only encrypted credentials are intentionally untouched,
  and terminal font-size wiring awaits a Native SDK terminal typography API.
- Claude/Codex API keys currently use the CLI's own login or inherited process
  environment. Native SDK has an OS credential store, but its current text
  control has no secure model-free password binding, so the PoC does not expose
  an unsafe secret field. Codex `settingsJson` is persisted compatibly; Canopy's
  hook server and `.codex/hooks.json` ref-counted lifecycle remain future work.
- Closing a live tab keeps it in `closing` until Native SDK confirms process-tree
  shutdown. Dynamic transport and emulator entries are then retired without
  imposing a new application-level session limit.

## Next production slice

1. persistent per-worktree tab metadata and lazy session restore;
2. existing/base branch choices during worktree creation;
3. reopen-closed-tab history;
4. virtualized tab chrome, keyboard shortcuts, and tab reordering;
5. split panes and cross-platform epoll/IOCP reactors.
