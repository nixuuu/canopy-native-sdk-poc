# Native chrome and motion

The tab strip uses 4 px outer insets, 6 px gaps, 180 × 28 px tabs and a
36 px rail. It has no tab-count badge. Previous/next controls appear only
when tabs overflow the rail or the bounded 12-tab window hides other tabs.
Navigation selects a tab and reveals it; wheel/trackpad scrolling preserves
the current selection. The model mirrors the SDK's horizontal scroll offset.
`tab_strip.zig` shares the geometry and selection-visibility rules.

`ui_motion.zig` owns short, interruptible transitions driven by presented-frame
timestamps. Intermediate samples update retained widget presentation; they do
not rebuild the model view, remeasure text, or republish accessibility. Sidebar
motion changes retained split geometry and crops the native terminal viewport.
A source rebuild is required only for data/structural changes and the final
sidebar cleanup. Frame updates are batched into one display-list emission:


- Selected/new tab: 4 px entrance over 150 ms.
- Closing a tab: surviving tabs settle into the vacated space over 150 ms.
- Dialog entrance: the entire surface and its contents move 8 px over 250 ms.
- Preferences section switch: 4 px over 150 ms.
- Sidebar/drawer: 250 ms opening, 180 ms closing, reversed from the current pose.

Dismissed dialogs leave immediately; motion never delays a close, cancellation,
terminal shutdown or Git operation. Terminal content and adopted Ghostty NSViews
are never transformed. Geometry and hit targets follow transformed chrome via
the SDK widget transform path. Layout/selection remains model-owned. Reduced
Motion snaps both current and newly triggered transitions and parks the frame
loop as soon as no work remains.

Large dialogs remain opaque and use Canopy's stationary dim backdrop. The
SDK's duplicate full-window blur is disabled via paint_scrim while preserving
modal scroll occlusion (scrim remains enabled), so translating a dialog does not
rerasterize a moving blur across the entire window.

The worktree tree uses the SDK's runtime-scrolled virtual window. Only visible
rows plus overscan are mounted, including after wheel/keyboard scrolling or a
source rebuild.

A small versioned SDK patch adds `UiApp.Options.decorate_view`, a post-build
hook shared by compiled views and reloaded markup. This keeps animation behavior
consistent during development without coupling the SDK to Canopy. Its regression
test exercises both view sources through a real SDK test runtime.

Validation covers tab overflow boundaries, selection visibility, separated hit
areas, removal of the count badge, animation reversal/settling, Reduced Motion,
untouched terminal surfaces, and compiled/markup parity. Native window checks
are required in addition to these tests, since canvas screenshots omit NSViews.

## Frame pacing and measurement

On macOS 14+, visible surfaces use a demand-driven display link attached to the
view's display. The clock follows the actual display refresh rate, including
144/165/240 Hz, without a 120 Hz timer cap. It pauses when no frame is pending.
Older macOS and occluded/first-frame cases retain the common-mode timer path.
A weak target avoids a display-link/view retain cycle.

Build an isolated profiling instance with `-Dprofile-motion=true
-Dautomation=true -Doptimize=ReleaseFast`. Its data is separate under
`tech.itsol.canopy.native-poc.performance`. Set `NATIVE_SDK_GPU_FRAME_TRACE=1`
when launching to record `CAMetalDrawable.presentedTime` and bounded animation
begin/end markers. The normal app does not register these trace callbacks.

Analyze its log with:

```
node scripts/analyze-motion-frames.mjs frames.log 144
```

The analyzer reports actual visible frame intervals, retains long/stalled gaps,
excludes completely occluded animations, and never combines animations across
idle time. SDK `frame_profile` values are CPU-stage durations, not FPS.
`CANOPY_BENCH_MOTION=1 npm test` additionally compares full rebuilds with the
retained presentation path on a large synthetic scene (CPU only).
