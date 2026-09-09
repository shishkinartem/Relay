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

### The window the runner already made

Not every platform fact travels over the channel. `RecorderPlatform.windowChrome`
(`packages/recorder_platform_interface/lib/src/recorder.dart`, with the enum in
`lib/src/models/window_chrome.dart`) says how the host framed the Flutter view:
`overlaidWindowButtons` when the system draws its window buttons on top of it,
`separateTitleBar` when the window keeps a caption of its own and the view sits
below it in the client area.

Each runner answers for its own window, which is the entire reason the value
exists. `macos/Runner/MainFlutterWindow.swift` makes the title bar full-size and
transparent, so the traffic lights land over the view and the application's
header row has to leave the room they occupy free; `windows/runner/win32_window.cpp`
creates a plain `WS_OVERLAPPEDWINDOW`, so nothing of the system's is painted over
the view and that same reservation is a dead gap down the leading edge — which is
what Windows shipped with. A runner that stopped making its title bar transparent
would change the answer without changing platform, and a Linux runner would answer
from its own window in the same way. That is why the property belongs to the
registered plugin rather than to an `if (Platform.isMacOS)`, which *Platform
checks* below forbids and `test/architecture_test.dart` enforces.

**It is deliberately not a `RecorderCapabilities` field.** Capabilities describe
what the *recorder* can do and are fetched asynchronously over the method channel;
this is a synchronous property of a window that existed before Dart started, and
the first frame of the first screen is laid out around it. A `Future` is the wrong
shape for a value that can neither change nor arrive late — a header that reflowed
once the channel answered would be a visible jump on every launch. Hence a plain
getter with a default: `separateTitleBar`, because it is what a runner that has
done nothing special produces, and overlaying the buttons is the thing a platform
has to declare.

The design system may not import this package, so the composition root is the
one place that turns the enum into the header's inset token
(`CompositionRoot.titleBarLeadingInset` → `AppWindowChrome`) — the same
dependency direction every other platform fact takes to reach a widget.

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

On Windows the pure half is not a package but a pair of translation units, which
the standalone CTest project at `packages/recorder_windows/windows/test` compiles
without Flutter, WASAPI or Media Foundation, each into its own binary.
`recorder_types.cpp` is the mirror of `RecorderCore` and includes only its own
header, `<algorithm>` and `<sstream>`. `audio_mixer.cpp` joined it after the
first real Windows run, adding `<algorithm>` and `<cstring>` to its own header;
it holds the resampler, the audio ring buffer and the drain ceiling, and it has
no counterpart in the macOS pure half — `AudioMixer.swift` sits outside
`RecorderCore`, where `swift test` cannot reach it. The mixer was outside this
project entirely until a recording came back with a microphone track punched full
of holes by a defect living in two of those pure functions: untestable only
because nothing but the application build was compiling them.

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
