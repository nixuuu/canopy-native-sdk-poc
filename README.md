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
- a login `zsh` started inside the selected worktree;
- terminal focus, input, resize, scrollback, selection, ANSI colors, and rendering
  handled by Native SDK's `libghostty-vt` integration;
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

`src/main.zig` owns the model and process effects. `src/app.native` only renders
state and dispatches typed messages. Native SDK owns PTY transport and terminal
emulation behind each numeric key. Tabs from another worktree remain alive but
are filtered from the current tab strip, so switching worktrees restores that
worktree's last active tab.

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

Native SDK/CLI is pinned to `0.10.1` by `package-lock.json`. The reproducible
patch in `patches/` replaces its fixed four-session tables with dynamic stores
and serves every macOS PTY from one `kqueue` reactor. Ghostty remains pinned to
`7aa9591746ffa4d2eee458960c76554352832595` in `build.zig.zon`.

## Known PoC boundaries

- Native SDK is pre-1.0; this PoC carries a focused patch that should eventually
  become a maintained fork or upstream contribution.
- `ptySpawn` has no public `cwd` option. The PoC passes the worktree as a separate
  argv item to a small `zsh` bootstrap, avoiding path interpolation.
- Tab metadata is not persisted yet; terminal processes are intentionally not
  restorable sessions.
- Worktree creation currently covers new local branches only; attaching an
  existing branch and choosing a base branch are not implemented yet.
- Closing a live tab keeps it in `closing` until Native SDK confirms process-tree
  shutdown. Dynamic transport and emulator entries are then retired without
  imposing a new application-level session limit.

## Next production slice

1. persistent per-worktree tab metadata and lazy session restore;
2. existing/base branch choices during worktree creation;
3. reopen-closed-tab history;
4. virtualized tab chrome, keyboard shortcuts, and tab reordering;
5. split panes and cross-platform epoll/IOCP reactors.
