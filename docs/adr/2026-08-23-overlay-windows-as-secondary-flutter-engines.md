# Overlay windows are native panels hosting secondary Flutter engines

**Status:** Accepted
**Date:** 2026-08-23

## Context

`TECHNICAL_SPEC.md` §6 requires the recording control strip and the camera
preview to be separate always-on-top top-level windows that never appear in the
captured video. `docs/development/design-system.md` additionally requires them
to follow the connected design and use the shared design system components —
they are `1f`, `1g`, `1e` and `1p` in the canvas, drawn from the same tokens as
every other screen.

Flutter's own multi-window support is not available on the stable channel this
project builds against (`flutter config` reports `enable-windowing` as
*Unavailable*), so a second window cannot simply be opened from Dart.

## Decision

Each overlay is a **native top-level window hosting its own Flutter engine**,
created and owned by the platform plugin.

- macOS: an `NSPanel` (`.borderless`, `.nonactivatingPanel`, level
  `.statusBar`) whose `contentViewController` is a `FlutterViewController` over
  a `FlutterEngine` run at the Dart entry point `controlStripMain` or
  `cameraPreviewMain`.
- Windows: a layered `WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_TOPMOST`
  window hosting the same two entry points.

The overlay engines render `RecordingControlStrip` and `CameraPreviewSurface`
from `lib/design_system`, so the strip in the overlay and the strip in a widget
test are the same widget.

State flows one way. The application engine pushes an immutable
`RecordingOverlayState` snapshot through `relay/overlay`; native forwards it to
the overlay engine over `relay/overlay/view`; the overlay renders it and sends
back `OverlayCommand`s, which native forwards to `relay/overlay/events`. The
overlay owns no session state, so it cannot drift out of step with the recorder.

Camera frames reach the preview through a `FlutterTexture` registered against
the **preview engine's** texture registry. They never cross a platform channel,
and the preview never screen-captures the camera back off the display.

## Alternatives considered

- **Draw the overlays natively** (AppKit views / Win32 painting). Rejected: it
  would fork the design system into Swift and C++, which
  `docs/development/design-system.md` forbids — repeated visual values must live
  in the shared typed tokens, not be re-picked per platform.
- **A package such as `desktop_multi_window`.** Rejected under the dependency
  policy in `docs/development/code-quality.md`: the plugin already owns native
  window creation because it must apply `sharingType = .none` /
  `WDA_EXCLUDEFROMCAPTURE` and hand the window ids to the capture filter. A
  dependency would add a second window-ownership model without removing ours.
- **Render the strip inside the main window.** Rejected: §6 requires a separate
  top-level always-on-top window, and the main panel is hidden for the duration
  of a session precisely so it does not land in a display recording.
- **Wait for Flutter multi-window.** Rejected: unavailable on stable, and the
  contract here is small enough that adopting it later is a change inside the
  plugin, not in feature code.

## Consequences

Two extra Flutter engines run during a session. They are created lazily on the
first `showControlStrip` / `showCameraPreview` and reused for the process
lifetime, so a pause/resume or a camera toggle does not rebuild them.

The overlay entry points must be annotated `@pragma('vm:entry-point')` or the
Dart compiler tree-shakes them out of a release build. `RelayTheme` must supply
`Directionality` itself, because no `WidgetsApp` sits above an overlay's widget
tree — the first version of this crashed on the first frame for exactly that
reason.

They must also run on `OverlayBinding`, not the default one. A secondary engine
is told about the *application's* lifecycle, not its own window's, and Flutter
stops producing frames for `hidden`, `paused` and `detached`
(`SchedulerBinding.framesEnabled`). Recording puts the application in exactly
that state on purpose — §6 takes the main window off the screen and the user
moves on to whatever they are recording — so the panels froze on the last
snapshot they had drawn. State pushes still arrived and presses still became
commands; only the pixels stopped. The clock stopped, Pause and Resume never
swapped, and the session underneath did exactly what was asked while the strip
said otherwise. This is the sharpest edge of the decision, and it is invisible
from the Dart side of the boundary: nothing in the widget tree, the state
machine or the platform contract can express it, and no widget test can reach
it. `test/features/recorder/presentation/overlay_binding_test.dart` pins the
binding; the end-to-end symptom is only observable by driving the built
application (`docs/development/testing.md`).

Exclusion is enforced twice and independently: at the window-server level on
each panel, and through the capture filter's exclusion list, which
`excludedWindowIds` exposes so an integration test can assert the list is
populated before capture starts. With a display source — the default — that
list is the only thing keeping these windows out of the file.
