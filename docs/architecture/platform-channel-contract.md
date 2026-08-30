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
| `getInputDevices` | `kind: String` | list of media-device maps |
| `startInputMetering` | `kind: String`, `deviceId: String?` | `null` |
| `stopInputMetering` | `kind: String` | `null` |
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

`kind` on the three input methods is a `MediaDeviceKind` name — `camera`,
`microphone` or `systemAudio` (§33.2).

**`getInputDevices` always answers.** An empty list is a legitimate answer —
no camera is attached, or the platform records a mix with no endpoint behind it
— and not an error. A kind the platform cannot enumerate returns the single
device that kind will actually use, so the caller can name it without offering
a choice, or an empty list when it cannot say even that. A `kind` that is absent
or that the platform does not recognise is an empty list too: "there is nothing
here to choose" is both true and renderable, and a `PlatformException` is
neither. None of the three methods may fall through to the default
`FlutterMethodNotImplemented` / `NotImplemented()` arm: Dart decodes that as
`unsupported`, which is a failure rather than an answer. What the UI offers is
gated by `selectableDeviceKinds` and `meterableDeviceKinds`, never by an
unimplemented method.

macOS meets that rule; **Windows does not yet**. It rejects an absent or
unrecognised `kind` with an `unknown`-coded error, and rejects the same way
("the recorder is busy with an earlier request") when the sixteen-deep serial
worker queue that owns its COM apartment is full — so `getInputDevices` there
can fail instead of answering. That is a divergence for the Windows side to
close, not a second reading of this contract; it is recorded in
`../development/compatibility-matrix.md` → *Input devices*.

**A meter listens to the device it was given.** `startInputMetering` carries
`deviceId` beside `kind`, always present with `null` included, and **`null`
means the platform's own default** — the same meaning it has on
`RecordingConfiguration`, and the same device an unconfigured `prepare` would
open. The argument is not decoration: the bar sits under a device row, and a
meter reporting the system default while the user was choosing between two
microphones would answer a question nobody asked. §33.7 requires the meter to
follow the newly selected device *immediately*, and this is the only argument
that can carry that. `stopInputMetering` names no device, because there is only
ever one tap per kind to stop.

**A caller re-points by stopping and starting again.** Metering is reference
counted (below), so every `startInputMetering` takes a reference and a start
that no stop ever matches leaves the tap open for a meter nobody is watching —
the microphone held and the operating system's in-use indicator lit for the life
of the process. The application's meter does the stop for its caller; a platform
must not paper over a missing one.

A start naming a `deviceId` different from the one already being metered is
still required to move the single tap rather than open a second: a platform may
receive one if a future caller gets this wrong, and holding two microphones open
is the worse failure.

**Metering is reference counted, not stacked.** Two callers of
`startInputMetering` make one tap, and the tap closes when the last one stops. A
`stopInputMetering` with nothing running is a no-op, not an error. During a
recording the levels come off the live capture — never open a second handle on
a device the session already holds, so a running session's own microphone is the
level source whatever `deviceId` says. Outside a recording, open the lightest
tap the platform offers and release it completely on stop: no device may stay
open for a meter nobody is watching. Only `microphone` is meterable on either
platform, and a start for another kind is a silent no-op, not an error.

**A meter keeps reporting while a session is paused.** Pause stops what is
written, not what is heard: neither platform closes the microphone across
`pause`, so the bar goes on showing what the microphone hears while none of it
reaches the file. macOS's `RecordingSession.pause()` moves the clock and the
state and leaves the microphone's `AVCaptureSession` running; Windows meters the
packets its capture is already reading and declines only to write them. A bar
frozen at the moment of pause would read as a broken meter rather than a paused
recording, and §33.7 treats a flat bar on an enabled input as a finding worth
reporting.

Changing the **recording's** device mid-session (§33.2) is still not carried
here: the device a session records is chosen before `prepare`, in the
configuration map, and re-pointing it arrives later as an additional method.
`deviceId` on `startInputMetering` moves the meter alone — it never re-points a
running capture.

### capabilities map

```jsonc
{
  "qualities": ["hd720", "fullHd1080"],
  "frameRates": [30, 60],
  "sourceTypes": ["display", "window"],
  // §33.2. A kind absent from selectableDeviceKinds is still recorded; the UI
  // names what it records instead of offering a list. What getInputDevices
  // returns for such a kind is whatever is true of it: the one device it will
  // open, or an empty list where there is no endpoint at all. macOS returns an
  // empty list for systemAudio — ScreenCaptureKit delivers the mix — and the
  // row is named from a Dart literal ("System mix"), not from an enumeration.
  "selectableDeviceKinds": ["camera", "microphone"],
  "meterableDeviceKinds": ["microphone"],
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

### media-device map

```jsonc
{
  "id": "camera:0x1a2b",    // opaque, non-empty, stable across enumerations;
                            // never parsed in Dart
  "kind": "camera",         // "camera" | "microphone" | "systemAudio"
  "label": "Logitech Brio", // what the user reads; empty is allowed and Dart
                            // substitutes the kind's own word
  "isSystemDefault": true,  // the device the platform would use if nothing
                            // were chosen — the null device id means this one
  "isAvailable": true       // false when listed but not openable right now
}
```

Ordering is part of the contract: **the system default first, then the rest in
the platform's own order** (§33.2).

An entry with no `id`, an empty `id`, or a `kind` this build does not know is
dropped on decode rather than defaulted, so one unrecognized row does not cost
the user the rest of the list.

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
  // §33.2. Always present, null included. Null means the platform's own
  // default device.
  "cameraDeviceId": null,
  "microphoneDeviceId": "mic:0x2f",
  "systemAudioDeviceId": null,
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

**A null device id means the platform's own default**, which is exactly today's
behaviour: an unconfigured session must record precisely what it recorded
before devices could be chosen. **An id that no longer resolves falls back to
that default and emits a non-fatal `error` event; it must never fail
`prepare`** — a wrong microphone is a degraded recording, a refused `prepare`
is no recording at all. `systemAudioDeviceId` is ignored where `systemAudio`
is not in
`selectableDeviceKinds`.

### strip-position map

```jsonc
{
  "displayId": "display:1",  // as the host spells display ids elsewhere
  "x": 0.31,                 // top-left as a fraction of the USABLE area
  "y": 0.44                  // both in [0, 1]; a fraction, never a point
}
```

A fraction rather than a point because a point survives nothing: a resolution
change, an undocked monitor or a different machine puts the strip where no
window can be. Dart clamps a fraction slightly outside the unit square rather
than rejecting it — that is a rounding artefact of a display that changed
shape — and drops one with no display id or a non-finite component entirely.

**`displayId` is best-effort across launches, and deliberately so.** Both
platforms spell it with the identifier they already use elsewhere — a
`CGDirectDisplayID` on macOS, an `HMONITOR` on Windows — and neither is stable
across a reboot or a change of display topology. A stored id can therefore
resolve to a *different* physical display than the one the strip was left on.

That is accepted rather than fixed, because the failure is bounded: the fraction
still resolves against a real display's usable area and is still clamped, so the
worst case is the right relative spot on the wrong screen, and one drag corrects
it. The alternative — a second, stable display-id spelling maintained on both
platforms purely for this — costs more than the case is worth. Recorded in
`../development/compatibility-matrix.md`.

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
{ "type": "inputLevel", "kind": "microphone",    // §33.2
  "peak": 0.62, "rms": 0.41 }
{ "type": "devicesChanged", "kind": "camera" }   // "kind" may be omitted,
                                                 // meaning "re-read everything"
{ "type": "stats", "capturedFrames": 26160, "encodedFrames": 26154,
  "droppedFrames": 6, "audioDiscontinuities": 0, "avDriftMs": 3.2,
  "encoderName": "VideoToolbox H.264", "hardwareEncoding": true }
{ "type": "error", "code": "systemAudioUnavailable",
  "message": "…", "details": "…", "fatal": false }
```

`fatal: false` degrades the session — an optional input dropped out and
recording continues. `fatal: true` ends it.

`peak` and `rms` are **linear amplitude in `[0, 1]`** — not decibels, and never
a buffer. §3 keeps raw media native; a level is a measurement, an audio buffer
on this channel is a spec violation. Emit at roughly 20 Hz while metering is
running, and **not at all when nothing is metering**. A level for a kind the
build does not know is decoded as a non-fatal error rather than attributed to
the wrong meter, so the spelling must match `MediaDeviceKind`.

## `relay/overlay`

| Method | Arguments | Result |
|---|---|---|
| `showControlStrip` | placement map | `null` |
| `hideControlStrip` | — | `null` |
| `controlStripPosition` | — | strip-position map, or `null` |
| `showCameraPreview` | placement map + `matchesCompositedPip: bool`, optional `cameraOverlay` | `null` |
| `hideCameraPreview` | — | `null` |
| `updateControlStrip` | overlay-state map | `null` |
| `setMainWindowVisible` | `visible: bool` | `null` |
| `excludedWindowIds` | — | `List<String>` |

Placement is one of three shapes, in logical points:

- **anchored** — `{ width, height, anchor: "topCenter", margin }`, docked to the
  current display's usable area (§5, §6);
- **fractional** — the anchored shape plus
  `position: { displayId, x, y }`, where `x` and `y` are the strip's *top-left*
  as a fraction of that display's **usable** area (§33.3);
- **absolute** — `{ frame: { x, y, width, height } }`, a rectangle inside the
  captured canvas, used by the camera preview.

**A fractional placement always resolves.** The host resolves it against the
usable area of the display `displayId` names, clamps the whole strip inside that
area, and falls back to `anchor` on the current display when the id names no
attached display. Clamping against the usable area — not the raw display
bounds — is what keeps the menu bar, the notch and the taskbar uncovered
however the fraction was arrived at.

`controlStripPosition` answers with `{ displayId, x, y }` in the same
convention, or `null` when no strip is on screen or the host cannot name its
display. It is **pulled once, as the session tears down**, rather than pushed on
every move: a strip is dragged for a second and a half and the application needs
one answer, not sixty. A `null` leaves the stored position alone — failing to
read one is not the user having dragged the strip back.

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
| `beginMove` | — hands the drag to the platform's own window-move loop |

**`beginMove` is called once per gesture.** The strip's own Flutter side detects
a press on its background that has travelled 4 px and asks the host to take
over; the operating system then tracks the pointer until mouse-up. When that
loop ends the host snaps the strip — within 24 points of a usable-area edge or
of the usable area's horizontal centre it lands exactly on it — and clamps it.
The strip then belongs to whichever display holds its centre.

There is deliberately no per-move message: §3 keeps this channel for commands,
and the operating system already has a drag loop that runs at the display's
refresh rate.

`textureId` is registered against the preview engine's own texture registry, so
it is meaningful only inside that engine and never crosses into the main one.

## Compatibility

Evolve additively. A new optional field with a defaulted reader is a
compatible change; renaming a method or changing a field's type is not, and
requires updating every implementation and its tests in the same change.
