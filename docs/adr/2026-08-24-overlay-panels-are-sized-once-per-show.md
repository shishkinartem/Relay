# Overlay panels are sized once per show

**Status:** Accepted
**Date:** 2026-08-24

## Context

Every recording after the first crashed the application, on macOS, with
`SIGSEGV` at address `0x0` inside `impeller::Canvas::SetupRenderPass()` on an
overlay engine's `io.flutter.raster` thread. Four crash reports in 24 hours; the
faulting thread belonged to the control strip's engine, not to the capture
pipeline.

The cause was a size alternation, not a lifetime bug.

`OverlayWindowController.showControlStrip` applied the placement's *requested*
size — Dart always sends the fixed placeholder `360 × 46`
(`OverlayPresenter.controlStripSize`) — and then immediately corrected the panel
back to the size the strip had measured for itself. On the first session
`stripContentSize` is nil, so the correction is skipped and the panel makes a
single transition. On every session after that the panel is already at the
measured size *M*, so the pair drove it `M → 360 × 46 → M` inside one main-loop
turn, while the panel was still ordered out. The two sizes can never coincide:
the strip measures taller than 46, and `control_strip_window_test.dart` asserts
its width exceeds 360.

Each of those is a blocking resize. `FlutterView.setFrameSize:` hands off to
`ResizeSynchronizer`, which stalls the platform thread until the raster thread
commits a frame at that exact size, so all three sizes are really rendered.
`FlutterBackBufferCache` then selects a cached surface by age and in-use flag
**without comparing its size to the requested one**, and purges the cache only
when `_surfaces.firstObject` disagrees. Alternating A → B → A while an old-size
surface is still `IOSurfaceIsInUse` leaves a mixed-size cache that returns a
wrong-sized `MTLTexture`. The embedder stamps the *requested* size into the
descriptor, `TextureMTL` marks itself invalid on the mismatch,
`RenderTarget::SetColorAttachment` silently no-ops on an invalid attachment, and
the rasterizer then calls a pure-virtual `GetSize()` on the null texture it was
never given.

The crash also had a second-order cost. Dying inside `SCStream.startCapture()`
orphaned the capture on the daemon side: `replayd` invalidated the connection,
found no active session to stop, then completed the in-flight start anyway and
told Control Center a stream was live. One observed orphan captured for 11 hours
with no client process, keeping the "Screen & System Audio Recording" privacy
indicator lit. Nothing in the application can clear that; only not crashing can.

Windows never had the bug: `OverlayWindows::ShowControlStrip` already substitutes
the measured size into the placement before resolving the frame.

## Decision

**An overlay panel is driven through exactly one size per show, and is never
resized while it is off screen.**

- The effective size is resolved *before* the panel is placed or created, by
  `OverlayPlacementGeometry.effectiveSize(requested:measured:)`: a measurement
  the overlay has already reported wins over the placement's request.
- A panel that does not yet exist is created at that frame, so a first show
  performs no resize either. This needs one non-obvious step: assigning
  `contentViewController` resizes the window to the controller's view, and a
  `FlutterView` starts at `NSZeroRect`, so a panel built with the right
  `contentRect` still comes back 0 × 0 unless the controller's view is sized
  first. The first attempt at this ADR's own rule missed that and left every
  first show resizing 0 × 0 → target, off screen — the same fault class, with
  the worse of the two sizes. A probe against this project's own
  `FlutterMacOS.framework` is what settled it, and is the only thing that can:
  `swift test` cannot build the plugin target and `flutter build` only compiles.
- A resize that is genuinely needed on a re-show — the resolved size changed
  since the last session — orders the panel front *before* resizing, so the
  frame the engine is forced to commit has a drawable to land in.
- A deferred measurement that arrives after the strip was hidden is stored and
  applied by the next show; the deferred resize itself is skipped when the panel
  is not visible.
- Placement arithmetic moved into `RecorderCore` as pure functions, where
  `swift test` can execute it. Degenerate sizes — zero, negative, non-finite —
  are rejected there rather than written into a window; macOS previously passed
  an absolute frame straight through where Windows clamped.
- The session's display is pinned at the first show, while the main window is
  still on screen, and used for every later placement in that session.

This is a constraint on future code, not only a repair. Any new overlay, and any
new reason to re-place an existing one, must resolve its size once.

## Alternatives considered

**Order the panel front before resizing it.** Would keep the resize on a visible
window, but a first show would then flash the panel at its default position
before moving it, and the alternation — the actual fault — would remain.

**Clear `stripContentSize` when the strip is hidden.** Makes the second session
start from the request again, which reintroduces the same two sizes, only spread
across turns instead of within one.

**Pin the Flutter engine to a Skia backend.** Avoids the Impeller code path but
gives up the renderer the toolchain defaults to, for a bug the application
caused itself by resizing twice.

**Give each session fresh overlay engines.** Removes the cross-session state
entirely, but an engine costs a raster thread, an IO thread and a Dart isolate
per session, and tearing one down while its raster thread is live is a larger
risk than the one being fixed.

## Consequences

- A re-show is now a no-op on size and at most a move, so the second session
  behaves exactly like the first.
- The arithmetic is unit-tested (`OverlayPlacementGeometryTests`), including the
  regression itself: resolving twice must not produce a resize.
- macOS and Windows now resolve overlay sizes the same way, which is what the
  platform abstraction claimed already.
- The crash-orphaned `replayd` stream is addressed only by not crashing. A
  client-side `applicationWillTerminate` hook would not have helped: `SIGSEGV`
  never reaches AppKit, and in the observed orphan the daemon had already torn
  down the connection before the stream was created.
- Overlay placement no longer follows keyboard focus mid-session. §5's TBD on
  what happens when the main window changes display *during* a recording is
  untouched — the window is hidden for the whole session, so it cannot.
