# Recording Architecture

## Scope

Defines the recorder/session domain. Product UX details remain in `../../TECHNICAL_SPEC.md`.

## MVP source

MVP records one entire screen or one selected application window.
The display source is the default.

Domain model remains extensible:

```text
CaptureSource
├── Display   // default
├── Window
└── Region    // future
```

Source selection is a custom in-application list — displays first, then windows.
See `TECHNICAL_SPEC.md` §4.1 and
`../adr/2026-08-22-capture-source-scope-and-selection-ux.md`.

## Session states

Conceptual lifecycle:

```text
idle
→ selectingSource
→ preparing
→ recording ⇄ paused
→ stopping
→ finalizing
→ ready
→ uploading/deleting
→ idle
```

Errors are typed states/results rather than arbitrary UI strings.

## Core invariants

- control overlay never appears in recorded output — in display mode explicit
  capture-filter exclusion is the only mechanism enforcing this;
- the camera preview overlay is excluded on the same terms;
- the control strip docks to the display's *usable* area — under the menu bar,
  above the taskbar. The menu-bar band contains the notch on a notched Mac,
  where a control is neither drawn nor clickable;
- the three overlays are native always-on-top panels, each hosting its own
  secondary Flutter engine — which is why their entry points carry
  `@pragma('vm:entry-point')`, why their root widget must supply its own
  `Directionality`, and why they run on `OverlayBinding`. See
  `docs/adr/2026-08-23-overlay-windows-as-secondary-flutter-engines.md`;
- the control strip is one size in every session state, and its host window is
  restored to the last measured size every time the strip is shown again. The
  overlay engine outlives a session and only reports a size when its own content
  changes, so a second recording would otherwise clip Pause and Stop outside the
  window;
- **a panel's rendered size, in physical pixels, is non-decreasing for the
  lifetime of its view, and never returns to a value it has held before.** A
  window hosting a Flutter view blocks the platform thread on each resize until
  that engine commits a frame at the new size, so every distinct size is a real
  rendered frame; a cache holding two sizes whose *oldest* entry matches the
  request hands back a surface of the other size, and the render target built
  from it has no colour attachment. `OverlayPlacementGeometry.panelSizeAction`
  is the one implementation and carries the sufficiency argument. See
  `docs/adr/2026-08-31-overlay-panels-never-shrink.md`, which amends
  `docs/adr/2026-08-24-overlay-panels-are-sized-once-per-show.md` — the earlier
  "exactly one size per show" was necessary and not sufficient, and the
  application crashed a second time under it;
- the camera preview **obeys that rule** rather than being exempt from it. Its
  window takes the bounding size of all three presets
  (`CameraOverlayConfiguration.boundingTileSize`), is never resized, and the
  tile is drawn as a rectangle inside it, sent on `cameraPreviewState`. Sizing
  the window to the tile made `Camera → Square → Camera` — one press each way —
  a literal A → B → A, which is why the preview was the last panel still
  alternating. The transparent surplus takes no press, and a drag reads and
  reports the tile rather than the window;
- overlay placement is resolved against the display the main application window
  was on when the session started (§5). That window is hidden for the whole
  session, so the display is pinned at the first show rather than re-resolved
  per call — otherwise anything placed later falls back to whichever display has
  keyboard focus, which is the one being recorded, not the one §5 names;
- the finished session is released when the user leaves the post-recording
  screen, not at process exit. `releaseSession` is a distinct call from `abort`,
  which platforms may refuse once a file is finalized, and from `dispose`, which
  ends the platform with the process;
- cursor is present;
- mic default ON;
- camera default OFF;
- system audio default ON;
- camera may toggle during recording;
- microphone may toggle during recording;
- system audio may toggle during recording;
- failed upload does not destroy the finalized local file.

## Local file lifecycle

Write incrementally to disk.

Recommended lifecycle:

```text
recording-<id>.part
→ capture/encode/mux
→ successful finalize
→ recording-<id>.mp4
→ Send or Delete
```

Never keep the full recording in RAM.

Local deletion is allowed only after:

1. explicit user Delete; or
2. confirmed upload success.

Do not delete on upload start, bytes-sent completion, connection close, or assumed success.

## Recovery

On startup, detect incomplete artifacts. Do not silently delete data that may be recoverable.

The exact user-facing recovery UX may remain minimal in MVP, but data-loss behavior must be explicit.

## Idempotency/race safety

Operations such as these must be idempotent or explicitly guarded:

- `Recorder.stop()` — finalizes and returns the `RecordingFile`
- `Recorder.abort()` — ends a session without producing an output file
- `Recorder.releaseSession()` — releases the capture session, not the plugin
- `Recorder.dispose()`
- `RecordingStore.delete(file, DeletionReason)` — deletion always states a reason;
  there is deliberately no unqualified delete on the store

Double-clicks, retries, cancellation races, or repeated callbacks must not corrupt the output or create contradictory states.

Idempotence alone is not enough for the teardown pair. `abort` and `dispose` must
also **never overtake an in-flight `stop`**, and that is a separate property from
being safe to call twice. A teardown that reaches the writer first strands a
finished recording as a `.part` needing §18 recovery.

The reason is not that quitting is fire-and-forget — it is not. The quit path is
`lib/main.dart`'s `AppLifecycleListener(onExitRequested:)` →
`CompositionRoot.dispose()` → `RecorderViewModel.dispose()` and its `shutdown`,
and every link of that chain **is** awaited before `AppExitResponse.exit` is
returned, which is what §19.1's "before the process exits" requires. The reason
is that `stop` and `dispose` are two independent calls into the platform:
`RecorderViewModel.dispose()` does not join a `stop()` the user pressed a moment
earlier, so closing the window during finalization — an ordinary user action —
puts both on the platform at once. The ordering has to hold in the host, because
nothing above it is holding it.

The two platforms hold the line differently, and both are deliberate:

- **macOS refuses.** `RecordingSession.abort()` claims `.stopping` only from
  states a stop has not already claimed, and `release()` returns outright on
  `.stopping`/`.finalizing` rather than tearing down under one.
- **Windows waits.** `RecordingSession::teardown_mutex_` spans the `MediaWriter`
  call as well as the thread joins, so an abort blocks until the finalize is
  done and then lands as a no-op on a file already renamed. The plugin runs
  `abort` and `dispose` on its serial worker so that wait is off the platform
  thread — and, because the worker is FIFO, so that the ordering holds at all.

## TBDs inherited from product spec

Do not silently resolve:

- exact pause timeline semantics;
- output policy when source dimensions/aspect ratio change (displays included);
- source-close UX;
- minimum supported OS versions.

Resolved 2026-08-22, no longer open: source-selection UX, camera PiP geometry,
Delete confirmation. See `../adr/`.
