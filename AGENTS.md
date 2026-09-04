# Repository Guidelines

## Project Structure & Module Organization

This macOS PoC uses Zig, Native SDK markup, and Ghostty.
`src/main.zig` assembles startup and the native host; `model.zig` owns state,
`messages.zig` defines messages, and `app_controller.zig` orchestrates effects.
Keep domain transitions independent of host calls. See `docs/architecture.md`.

UI lives in `src/app.native` and `src/components/`; Objective-C
adapters accompany Zig sources. Application tests are in `src/tests/`,
with shared fixtures in `support.zig`. Pure module tests stay beside their
implementations. `assets/` contains the icon, `scripts/` contains build and
profiling utilities, and `patches/` holds the versioned Native SDK patch.

## Build, Test, and Development Commands

Use macOS 13+, Xcode with Metal tools, Node.js 24+, npm 11+, and Zig 0.16.0.
Respect the exact toolchain and dependency pins in the manifests and lockfile.

- `npm install`: install the CLI and apply `patch-package` patches.
- `npm run dev`: build and run with development hot reload.
- `npm run check`: strictly validate Native markup.
- `npm run format`: format Zig sources; `npm run format:check` checks formatting.
- `npm test`: run application, terminal, painter, and native policy suites.
- `npm run build`: produce the ReleaseFast build.
- `npm run verify`: run formatting checks, tests, markup validation, and build.

The initial Ghostty build is slow.

## Coding Style & Naming Conventions

Use `zig fmt`, four-space Zig indentation, `snake_case` module filenames and
fields, `PascalCase` types, and `camelCase` functions. Follow existing two-space
indentation in `.native` markup and JavaScript utilities. Name component files
with kebab-case, such as `terminal-workspace.native`. Keep markup declarative
and side effects in controllers or transport adapters.

## Testing Guidelines

Use Zig `test "descriptive behavior"` blocks and `std.testing`; application
suite filenames follow `*_tests.zig` and are imported through `src/tests.zig`.
Cover changed transitions, failures, and stale callbacks. No numeric coverage
threshold is configured. Run `npm run verify` before handoff. Renderer changes
also require a real macOS window check: canvas screenshots omit adopted NSViews.

## Commit & Pull Request Guidelines

Follow Angular-style prefixes found in history: `feat:`, `fix:`, `refactor:`, and
`perf:`. Use imperative subjects. Keep behavioral changes separate from
structural refactors. PRs should explain the problem, resulting behavior, and
validation; link issues and include screenshots for UI changes.

## Lifecycle & Configuration Safety

Preserve the single-command Git lane and wait for owned terminal shutdown before
detach or worktree removal. Keep Ghostty configuration and secrets out of UI
projections and logs. Use the native app's separate SQLite database; never write
Electron Canopy's production database. Record SDK changes in `patches/`.
