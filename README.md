# Canopy Native SDK PoC

A small, runnable reimplementation of Canopy's core desktop shape using
[Native SDK](https://native-sdk.dev/): a projects/worktrees sidebar and native
terminal tabs. The shipped app uses no Chromium, WebView, or JavaScript runtime.

## What works

- resizable projects sidebar with the real local Canopy checkout and worktree;
- worktree-local tab lists and remembered active tab;
- dynamically allocated terminal sessions, limited by host resources rather
  than an application constant;
- a login `zsh` started inside the selected worktree;
- terminal focus, input, resize, scrollback, selection, ANSI colors, and rendering
  handled by Native SDK's `libghostty-vt` integration;
- opening, activating, and closing terminal tabs;
- window geometry restore and hidden-inset native macOS chrome.

The fixture paths are intentionally explicit in `src/main.zig` so this first PoC
boots against the exact local checkouts it was made to evaluate. Project picker,
Git worktree discovery, persistence, and safe worktree mutations belong to the
next slice.

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

Native SDK/CLI is pinned to `0.10.1` by `package-lock.json`. The reproducible
patch in `patches/` replaces its fixed four-session tables with dynamic stores
and serves every macOS PTY from one `kqueue` reactor. Ghostty remains pinned to
`7aa9591746ffa4d2eee458960c76554352832595` in `build.zig.zon`.

## Known PoC boundaries

- Native SDK is pre-1.0; this PoC carries a focused patch that should eventually
  become a maintained fork or upstream contribution.
- `ptySpawn` has no public `cwd` option. The PoC passes the worktree as a separate
  argv item to a small `zsh` bootstrap, avoiding path interpolation.
- Project/worktree fixtures are local constants; no `git worktree add/remove` is
  performed.
- Tab metadata is not persisted yet; terminal processes are intentionally not
  restorable sessions.
- Closing a live tab keeps it in `closing` until Native SDK confirms process-tree
  shutdown. Dynamic transport and emulator entries are then retired without
  imposing a new application-level session limit.

## Next production slice

1. folder picker plus `git -C <repo> worktree list --porcelain` discovery;
2. persistent project and per-worktree tab metadata;
3. preflighted worktree create/remove commands;
4. reopen-closed-tab history;
5. virtualized tab chrome, keyboard shortcuts, and tab reordering;
6. split panes and cross-platform epoll/IOCP reactors.
