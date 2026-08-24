# Platform Abstraction

## Goal

Keep Flutter feature/business code independent from ScreenCaptureKit, Windows.Graphics.Capture, WASAPI and future Linux APIs.

## Common interface

Conceptually:

```dart
abstract interface class Recorder {
  Future<List<CaptureSource>> getAvailableSources();
  Future<RecorderCapabilities> getCapabilities();
  Future<void> prepare(RecordingConfiguration configuration);
  Future<void> start();
  Future<void> pause();
  Future<void> resume();
  Future<RecordingFile> stop();
  Future<void> setMicrophoneEnabled(bool enabled);
  Future<void> setCameraEnabled(bool enabled);
  Future<void> setSystemAudioEnabled(bool enabled);
  Stream<RecorderEvent> get events;
}
```

Exact API may evolve, but Flutter/domain code must not depend directly on native capture types.

## Platform implementations

### macOS

Primary capture technology:

- ScreenCaptureKit;
- Swift native adapter/plugin.

MVP uses display-scoped capture (default) and window-scoped capture, via
`SCContentFilter(display:excludingWindows:)` and `SCContentFilter(window:)`.
Application-owned overlays go in the exclusion list in both modes.

### Windows

Primary capture technology:

- Windows.Graphics.Capture, over a monitor or a window `GraphicsCaptureItem`;
- `WDA_EXCLUDEFROMCAPTURE` on application-owned overlays;
- WASAPI loopback for system audio;
- native Windows adapter/plugin.

## Plugin/package boundaries

A federated-style structure is preferred when repository complexity justifies it:

```text
packages/
├── recorder_platform_interface/
├── recorder_macos/
└── recorder_windows/
```

Future:

```text
recorder_linux/
```

Package granularity may be reduced if it adds ceremony, but interface boundaries and dependency direction must remain.

## The Flutter-free core

Each platform package is split in two: the half that talks to the operating
system, and the half that is pure.

On macOS the pure half is a nested Swift package,
`packages/recorder_macos/macos/recorder_macos/core` (`RecorderCore`). It holds
the wire contract, the camera picture-in-picture geometry, the canvas
arithmetic and the session clock, and imports neither Flutter, AppKit nor
ScreenCaptureKit. `swift test` runs it on any machine — the plugin package
around it declares a `FlutterFramework` dependency that only resolves inside a
Flutter build, so tests could never have run there.

It is nested inside the plugin package rather than beside it because Flutter
copies the plugin directory into `macos/Flutter/ephemeral/.packages/` at build
time. A sibling package would not be copied and the path dependency would
break; a child travels with its parent.

On Windows the same pure code lives in `recorder_types.cpp`, which includes only
its own header, `<algorithm>` and `<sstream>`. A standalone CTest project at
`packages/recorder_windows/windows/test` compiles it without Flutter or Media
Foundation.

**Both suites assert the same properties on purpose.** The two platforms
hand-write the same wire spellings and re-implement the same geometry, and
nothing in the Dart layer can observe them disagreeing. Mirroring the
assertions is the only thing that catches drift, and it already has:
`ResolvePipRect` and `CameraOverlayConfiguration.effectiveAspectRatio` handled a
malformed aspect ratio differently — a square tile against a 0.0001-ratio sliver
— and were aligned on the default 16:9.

## Contract discipline

Treat Flutter ↔ native interfaces as internal APIs.

Each method/event must define:

- inputs;
- outputs;
- typed errors;
- lifecycle;
- cancellation;
- ownership;
- compatibility expectations.

Prefer additive contract evolution.

When the shared platform contract changes, update and test every supported implementation.

## Platform checks

Do not spread:

```dart
if (Platform.isMacOS) ...
if (Platform.isWindows) ...
```

through feature code.

Platform selection belongs in plugin registration/dependency wiring.

## Linux

Linux is out of MVP.

Architecture must allow a future implementation, likely around XDG Desktop Portal + PipeWire for Wayland, without changing recording business logic.
