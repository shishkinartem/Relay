# Architecture Overview

## Purpose

This document describes the stable project architecture. Product behavior belongs in `../TECHNICAL_SPEC.md`; task routing and mandatory always-on rules belong in `../CLAUDE.md`.

## Dependency direction

```text
Presentation
    ↓
Application / orchestration
    ↓
Domain abstractions
    ↑
Infrastructure implements abstractions
```

Platform integrations and external services must not leak implementation-specific types into feature/domain code.

## Major boundaries

```text
Flutter application
├── recorder feature
├── settings feature
├── post-recording feature
└── upload feature
     │
     ├── Recorder abstraction
     │    ├── macOS implementation
     │    └── Windows implementation
     │
     └── UploadDestination abstraction
          ├── Telegram
          └── WebDAV
```

## Repository layout

```text
lib/
├── app/                  composition root, shell, state-driven routing
├── core/                 settings, logging, formatting, environment, errors
├── design_system/        tokens, icons, components — ported from design/_ds
├── features/
│   ├── recorder/         session state machine, orchestration, screens
│   ├── settings/
│   └── post_recording/   ready, send, delete
└── upload/               coordinator, registry, credential storage

packages/
├── recorder_platform_interface/   the Flutter ↔ native contract, once
├── recorder_macos/                ScreenCaptureKit, AVFoundation, VideoToolbox
├── recorder_windows/              Windows.Graphics.Capture, WASAPI, Media Foundation
├── upload_core/                   destination-agnostic upload contract
├── upload_telegram/
└── upload_webdav/
```

Feature code depends on `recorder_platform_interface` and `upload_core` only.
It never imports a platform API, and never imports Telegram or WebDAV.

## Expected extension axes

- `CaptureSource`
- `RecorderPlatform` — `packages/recorder_platform_interface/lib/src/recorder.dart`;
  implementations register themselves through `RecorderPlatform.instance`
- `UploadDestination`
- `VideoLayer`
- `AudioSource`
- encoder capabilities
- authentication providers

New implementations should usually be registered at composition/wiring boundaries rather than requiring changes to recorder business logic.

## Capability-driven design

Do not infer support from the operating-system name when the platform implementation can expose actual capabilities.

Prefer:

```text
RecorderCapabilities
├── supportedSourceTypes
├── supportedFrameRates
├── qualities
├── supportsSystemAudio
├── supportsMicrophone
├── supportsCamera
├── supportsPause
├── supportsCursorCapture
└── supportsHardwareEncoding
```

UI derives availability from capabilities.

## Failure-domain isolation

Keep these domains independent:

1. capture/recording;
2. local finalization/recovery;
3. upload/authentication.

Examples:

- network failure must not terminate an active recording;
- upload auth failure must not damage a finalized MP4;
- camera failure must not corrupt the screen video track;
- UI errors must not silently delete local media.

## State and ownership

Use explicit state machines for long-lived workflows. Avoid clusters of unrelated booleans that can form impossible states.

Every long-lived native/external resource needs clear ownership and lifecycle:

```text
create → start/use → stop/cancel → dispose
                   ↘ error cleanup
```

Cleanup must be deterministic and idempotent where practical.

The graph is released in the reverse of the order it was built.
`CompositionRoot.dispose()` releases the recorder first and on its own await —
it is the only member holding operating-system capture, and a quit during a
recording must release the camera and the microphone before anything else is
torn down — then everything that holds sockets and timers together.
`main.dart` reaches it from `AppLifecycleListener(onExitRequested:)`, because a
desktop application is quit rather than backgrounded and `detached` is not
guaranteed to arrive before the process goes away.

### The recorder's collaborators

`RecorderViewModel` orchestrates a session. It does not also *own* every
concern a session touches. Four collaborators were split out of it, each
declared as a role interface next to its consumer so the application layer
holds an abstraction and a test can substitute one without a platform:

| Interface | Implementation | Owns |
|---|---|---|
| `SessionPermissions` | `PermissionCoordinator` | reading, prompting, and the privacy pane; one failure rule |
| `SourceCatalog` | `PlatformSourceCatalog` | the source list, the enumeration latch, the default-selection rule |
| `ArtifactRecovery` | `PlatformArtifactRecovery` | `.part` artefacts a previous process left behind |
| `SessionOverlays` | `OverlayPresenter` | the two always-on-top windows |

`sessionEventForUpload` in `features/recorder/domain` translates an upload's
own events into session events. It is a pure function on purpose: the one side
effect the mapping would otherwise need — deleting the local file after a
confirmed remote success — requires a stated `DeletionReason` and stays behind
`RecordingStore`, which is what keeps "never delete before confirmed remote
success" a property of the code rather than of a comment.

`PlatformSourceCatalog` depends on `CaptureSourceProvider` rather than the whole
`Recorder` contract. Enumerating is all it does, and the narrower dependency is
the one a substitute is easiest to satisfy.

## ADR policy

Create an ADR for decisions expensive to reverse, including:

- Flutter/native bridge strategy;
- platform-native encoders vs shared FFmpeg/Rust/C++ media core;
- file/finalization model;
- OAuth trust model;
- introduction of a backend;
- resumable-upload persistence;
- Linux capture backend;
- 120 FPS implementation strategy.

See `adr/README.md`.
