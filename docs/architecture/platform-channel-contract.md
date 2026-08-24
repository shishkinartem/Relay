# Flutter ↔ native channel contract

This is an internal API. Every supported platform implementation speaks exactly
these names and payload shapes; a change here is not complete until macOS and
Windows both implement it and their tests pass
(`platform-abstraction.md` → *Contract discipline*).

The Dart side of the contract lives once, in
`packages/recorder_platform_interface`. Platform packages ship the native half
only. Channel names are constants in `RecorderChannels`.

Raw frames and raw audio never cross these channels. They carry commands,
configuration, state, progress, errors, metadata and capabilities only
(`media-pipeline.md`).

## Channels

| Name | Type | Direction |
|---|---|---|
| `relay/recorder` | MethodChannel | application engine → native |
| `relay/recorder/events` | EventChannel | native → application engine |
| `relay/overlay` | MethodChannel | application engine → native |
| `relay/overlay/events` | EventChannel | native → application engine |
| `relay/overlay/view` | MethodChannel | overlay engine ↔ native |

## Errors

Every failure is a `PlatformException` whose `code` is a `RecorderErrorCode`
name — `permissionDenied`, `sourceUnavailable`, `sourceClosed`,
`cameraUnavailable`, `microphoneUnavailable`, `systemAudioUnavailable`,
`captureFailed`, `encodingFailed`, `diskFull`, `finalizationFailed`,
`invalidState`, `unsupported`, `unknown`.

`message` is user-presentable; `details` is diagnostic. Application code never
inspects a message string.

## `relay/recorder`

| Method | Arguments | Result |
|---|---|---|
| `getCapabilities` | — | capabilities map |
| `getAvailableSources` | `refreshThumbnails: bool` | list of source maps |
| `getCurrentDisplay` | — | display map |
| `checkPermissions` | — | `{kind: status}` |
| `requestPermission` | `kind: String` | status `String` |
| `openPermissionSettings` | `kind: String` | `null` |
| `prepare` | configuration map | `null` |
| `start` | — | `null` |
| `pause` | — | `null` |
| `resume` | — | `null` |
| `stop` | — | recording-file map |
| `abort` | — | `null` |
| `setMicrophoneEnabled` | `enabled: bool` | `null` |
| `setCameraEnabled` | `enabled: bool` | `null` |
| `setSystemAudioEnabled` | `enabled: bool` | `null` |
| `recoverArtifact` | `path: String` | recording-file map, or `null` |
| `releaseSession` | — | `null` |
| `dispose` | — | `null` |
| `relaunchApplication` | — | `null` |
| `quitApplication` | — | `null` |

`releaseSession` is not `abort` and not `dispose`. `abort` is about an
unfinished recording and a platform may refuse it once a file has been
finalized; `dispose` ends the platform with the process. `releaseSession` means
"this recording is over and the user has moved on" — the host drops the session
and everything it built, so an idle recorder holds no camera, no microphone and
no capture. It is idempotent, a no-op where there is no session, and never
touches a recording on disk (§18).

### capabilities map

```jsonc
{
  "qualities": ["hd720", "fullHd1080"],
  "frameRates": [30, 60],
  "sourceTypes": ["display", "window"],
  "supportsCamera": true,
  "supportsMicrophone": true,
  "supportsSystemAudio": true,
  "supportsPause": true,
  "supportsCursorCapture": true,
  "supportsHardwareEncoding": true,
  // Permission-recovery flags. Both default to the permissive value when the
  // key is absent (false / true), so omitting them silently disables the
  // relaunch UI instead of failing.
  "screenRecordingNeedsRelaunch": true,      // macOS: true; Windows: false
  "screenRecordingLaunchedByThisApp": true,  // macOS: getppid() == 1
  "platformName": "macOS",
  "platformVersion": "26.5.2",
  "unsupportedReason": null   // non-null disables recording entirely
}
```

### source map

```jsonc
{
  "id": "display:1",          // opaque; never parsed in Dart
  "type": "display",          // "display" | "window"
  "title": "Built-in Display",
  "subtitle": "2560 × 1600",
  "pixelWidth": 2560,
  "pixelHeight": 1600,
  "isCurrentDisplay": true,   // §5 — the display holding the main window
  "thumbnail": <Uint8List>    // PNG, may be absent
}
```

Ordering is part of the contract: **displays first, then windows** (§4.1).

### display map

```jsonc
{ "id": "1", "logicalWidth": 1512, "logicalHeight": 982,
  "pixelWidth": 3024, "pixelHeight": 1964, "scaleFactor": 2.0 }
```

### configuration map

`RecordingConfiguration.toMap()`:

```jsonc
{
  "sourceId": "display:1", "sourceType": "display",
  "sourceWidth": 2560, "sourceHeight": 1600,
  "recordingId": "8f2a11", "outputDirectoryPath": "/Users/…/Movies/Relay",
  "quality": "fullHd1080", "targetHeight": 1080, "frameRate": 30,
  "cameraEnabled": false, "microphoneEnabled": true,
  "systemAudioEnabled": true, "showCursor": true,
  "cameraOverlay": { "widthRatio": 0.16, "aspectRatio": 1.7777,
                     "followsSourceAspectRatio": true,
                     "cornerRadius": 0.0, "marginRatio": 0.01,
                     "corner": "bottomRight",
                     "mirrorPreview": true, "mirrorOutput": false },
  "composition": { "aspectRatioPolicy": "containWithinPreset",
                   "geometryChangePolicy": "fixedCanvasLetterbox" }
}
```

`prepare` writes to `<outputDirectoryPath>/recording-<recordingId>.part` and
`stop` finalizes to `recording-<recordingId>.mp4` (§18).

### recording-file map

```jsonc
{ "path": "…/recording-8f2a11.mp4", "recordingId": "8f2a11",
  "sizeBytes": 1094813696, "durationMs": 872000,
  "createdAtMs": 1755900000000, "width": 1920, "height": 1080,
  "frameRate": 60, "hasAudio": true, "hasCamera": false }
```

## `relay/recorder/events`

Each event is a map with a `type` discriminator.

```jsonc
{ "type": "state", "state": "recording" }        // PlatformRecorderState name
{ "type": "tick",  "elapsedMs": 872000 }         // recorded time, paused excluded
{ "type": "inputChanged", "microphoneEnabled": true,
  "cameraEnabled": false, "systemAudioEnabled": true }
{ "type": "stats", "capturedFrames": 26160, "encodedFrames": 26154,
  "droppedFrames": 6, "audioDiscontinuities": 0, "avDriftMs": 3.2,
  "encoderName": "VideoToolbox H.264", "hardwareEncoding": true }
{ "type": "error", "code": "systemAudioUnavailable",
  "message": "…", "details": "…", "fatal": false }
```

`fatal: false` degrades the session — an optional input dropped out and
recording continues. `fatal: true` ends it.

## `relay/overlay`

| Method | Arguments | Result |
|---|---|---|
| `showControlStrip` | placement map | `null` |
| `hideControlStrip` | — | `null` |
| `showCameraPreview` | placement map + `matchesCompositedPip: bool`, optional `cameraOverlay` | `null` |
| `hideCameraPreview` | — | `null` |
| `updateControlStrip` | overlay-state map | `null` |
| `setMainWindowVisible` | `visible: bool` | `null` |
| `excludedWindowIds` | — | `List<String>` |

Placement is either anchored — `{ width, height, anchor: "topCenter", margin }`
— or absolute — `{ frame: { x, y, width, height } }`, in logical points on the
current display (§5).

`showCameraPreview` also carries `matchesCompositedPip`, the presentation mode
the preview window renders (design `1e` versus `1p`). It is **stated, never
inferred from the placement**: both modes send an absolute frame, so a host
that read the mode off the presence of `frame` would report display mode for a
window recording too and the captioned window-mode preview would never render.
Hosts must read the field and default a missing one to `false`.

`cameraOverlay` — the picture-in-picture tile configuration — is present only
when `matchesCompositedPip` is true, because it exists so the host can
re-resolve the tile against the camera's real shape and land the preview
exactly where the compositor draws it. Its presence is a consequence of the
mode, not the way to determine it.

`setMainWindowVisible` hides the main panel for the duration of a session.
The panel is ordinary chrome, not an excluded overlay, so a display recording
would otherwise contain it.

`excludedWindowIds` exists so an integration test can assert that every
application-owned always-on-top window reached the capture filter's exclusion
list before capture started (§6).

### Exclusion obligations

Native implementations must, for **every** window they create here:

- create it as a separate top-level window, never a child of a captured window;
- mark it non-capturable at the window level — `NSWindow.sharingType = .none`
  on macOS, `SetWindowDisplayAffinity(WDA_EXCLUDEFROMCAPTURE)` on Windows;
- add it to the content filter's exclusion list —
  `SCContentFilter(display:excludingWindows:)` /
  `GraphicsCaptureSession` item exclusion;
- report it from `excludedWindowIds`.

With a display source — the default — this is the *only* mechanism keeping the
overlays out of the file (§6).

## `relay/overlay/events`

Emits the raised `OverlayCommand` name as a bare `String`:
`toggleMicrophone`, `toggleCamera`, `toggleSystemAudio`, `pauseOrResume`,
`stop`.

## `relay/overlay/view`

Registered on the *secondary* engines only. Native runs those engines at the
Dart entrypoints `controlStripMain` and `cameraPreviewMain`.

Native → overlay:

| Method | Arguments |
|---|---|
| `controlStripState` | overlay-state map |
| `cameraPreviewState` | `{ textureId, mirrored, matchesCompositedPip, aspectRatio }` |

Overlay → native:

| Method | Arguments |
|---|---|
| `command` | `{ command: String }` — forwarded to `relay/overlay/events` |
| `contentSize` | `{ width, height }` — resizes the window to fit its content |

`textureId` is registered against the preview engine's own texture registry, so
it is meaningful only inside that engine and never crosses into the main one.

## Compatibility

Evolve additively. A new optional field with a defaulted reader is a
compatible change; renaming a method or changing a field's type is not, and
requires updating every implementation and its tests in the same change.
