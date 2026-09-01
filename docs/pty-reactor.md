# Dynamic PTY reactor

Canopy does not impose a terminal-session count. A new session is refused only
when the host cannot allocate the process, PTY, descriptor, memory, or reactor
registration it needs. Existing sessions remain unaffected by such a failure.

## macOS architecture

```text
dynamic tab store
  -> dynamic PTY registry (one process and master fd per live tab)
    -> one kqueue reactor thread (readiness only)
      -> bounded per-session input/output rings with kernel backpressure
        -> headless libghostty-vt state per opened terminal
          -> snapshots only for currently visible terminal widgets
```

The reactor performs no VT parsing, layout, or rendering. It reads at most one
16 KiB chunk per ready event. The UI drains at most 4 KiB per PTY event and 64
effect messages per frame; remaining work requests the next GPU frame instead
of recursively flooding the host wake queue. A full 256 KiB session staging ring disables that descriptor's
read filter; draining the ring re-enables it. The child then experiences normal
PTY/kernel backpressure instead of output loss.

Writes enable `EVFILT_WRITE` only while a session has pending input. Idle PTYs
therefore produce no readiness wakeups. Process reaping is moved to a short-lived
detached worker after EOF/kill, preventing a slow `waitpid` from blocking the
shared reactor.

## Rendering

Every live PTY retains its independent VT state because invisible terminal
programs may issue device queries that require immediate replies. GPU/display
snapshots are rebuilt only for keys resolved by visible `<terminal>` elements in
the current UI build. With a single selected tab, exactly one terminal widget is
rendered; multi-pane naturally raises this to the number of visible panes.

## Current verification

- 32 simultaneous interactive `zsh` PTYs on macOS;
- one visible terminal widget;
- constant process thread count while growing from 1 to 32 PTYs;
- input/output round trip verified in the eighth session;
- close/reap verified without interrupting the remaining sessions;
- an infinite `yes` stream in a background terminal stayed backpressured while
  another terminal accepted and returned `pwd`;
- idle app CPU observed at approximately 3% in a Debug automation build.

The npm package omits parts of the upstream SDK test fixture tree, so the full
upstream `zig build test` suite cannot run from the published package. The app's
typed model contract, focused tests, clean-install patch application, real PTY
automation, and ReleaseFast build form the validation gate in this repository.
