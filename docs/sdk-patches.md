# Native SDK patch maintenance

The npm manifest pins SDK 0.10.1. `patch-package` applies the versioned patch at
install. The inventory is checked by `npm run check:patch`; an SDK update or a
new patched file must update the inventory and its verification mapping.
These changes are maintained locally; no upstream acceptance is assumed.

## PTY lifecycle and readiness

Dynamic terminal membership, readiness-only reactor, backpressure and owned shutdown.

- `src/canopy_terminal_tests.zig`
- `src/root.zig`
- `src/runtime/core.zig`
- `src/runtime/effects.zig`
- `src/runtime/effects_pty_tests.zig`
- `src/runtime/pty.zig`
- `src/runtime/root.zig`
- `src/runtime/terminal_session.zig`
- `src/runtime/terminal_session_tests.zig`
- `src/runtime/ts_core_host.zig`
- `src/runtime/ui_app.zig`

Validation: `npm test: terminal_session_tests`, `npm test: terminal and application lifecycle regressions`.

## Native frame scheduling and raster policy

Tracking-mode frame delivery and bounded retained-surface caching/presentation.

- `src/platform/macos/appkit_host.m`
- `src/platform/macos/native_sdk_frame_clock.h`
- `src/platform/macos/native_sdk_raster_policy.h`

Validation: `npm test: canopy-frame-clock-tests`, `npm test: canopy-raster-policy-tests`, `Real macOS window smoke`.

## Canvas terminal painting and appearance

Terminal-grid paint/cache behavior and application token compatibility.

- `src/primitives/canvas/terminal_grid.zig`
- `src/primitives/canvas/terminal_grid_tests.zig`
- `src/primitives/canvas/tokens.zig`
- `src/primitives/canvas/widget_render.zig`
- `src/primitives/canvas/widget_render_style.zig`

Validation: `npm test: terminal_grid_tests`, `npm run check`, `Real macOS window smoke`.

## Upgrade procedure

1. Review upstream equivalents for each group before rebasing the patch.
2. Apply against the exact npm version; do not regenerate unrelated SDK code.
3. Run `npm run verify`, then the native-window checks mapped above.
4. Update the patch, inventory and source pins together. Keep independent
   behavior changes in separate commits.
