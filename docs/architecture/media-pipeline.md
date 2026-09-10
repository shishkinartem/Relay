# Media Pipeline

## Principle

Keep the high-throughput media path native.

Flutter/platform channels are for:

- commands;
- configuration;
- state;
- progress;
- errors;
- metadata;
- capabilities.

Do not continuously transfer raw video frames or raw audio buffers through Dart platform channels.

## Logical pipeline

```text
Display/window capture ┐
                       ├── Video compositor ── H.264 encoder ─┐
Camera capture ────────┘                                      │
                                                              ├── MP4 muxer → file
System audio ──────────┐                                      │
                       ├── Audio mixer ─────── AAC encoder ───┘
Microphone ────────────┘
```

The platform may combine stages internally, but these responsibilities should remain conceptually separable.

## Camera

Correct architecture:

```text
camera source ──┬── UI preview
                └── video compositor → final output
```

Never let the camera preview window reach the encoder through screen capture.
In window mode the content filter excludes it; in display mode — the default —
only an explicit capture-filter exclusion does. The same applies to the control
overlay.

PiP geometry is configuration, not scattered compositor constants. Defaults:
`0.16 x canvas width`, the camera's own aspect ratio, `0.01 x canvas width`
margin, lower-right, preview mirrored and output not.

The camera frame is **never distorted**, and is cropped **only** by an explicit
shape preset — identically in the preview and in the file (§33.5, which amended
this rule when presets shipped). The default `camera` preset takes the camera's
own shape, so nothing is cropped and the fit is exact. `square` and `circle` are
1:1 and take the centre of the frame, which is the crop the user asked for by
name; `circle` additionally masks it. With `followsSourceAspectRatio` off and no
crop configured, the frame is letterboxed inside the configured shape instead. The shape is read from the
capture device's active format, so the preview can be placed before the first
frame arrives. See `../adr/2026-08-23-camera-pip-follows-source-aspect.md`.

## Audio

Keep microphone and system audio separate until mixing.

Runtime mute toggles affect contribution to the final mix without ending the recording.

The **OS-level system-audio tap follows the switch** on macOS: it is not left
open and filtered. A session prepared with system audio off opens no tap at all,
so what the operating system reports about the application matches what the
strip says; switching it on mid-session reconfigures the live stream, and a
refusal reports `systemAudioUnavailable` rather than recording silence. Turning
it *off* mid-session still only stops the contribution, so a toggle never
restarts capture — and once a tap is open it stays open for the session.

**Windows was brought to the same rule on 2026-09-10.**
`RecordingSession::StartAudioInput` (`recording_session.cpp`) is the only path to
a WASAPI endpoint, and it opens nothing unless that input's flag is already set —
the guard macOS applies in `prepare`. `Start` calls it once per input, and
`SetMicrophoneEnabled` / `SetSystemAudioEnabled` call it again when they are
switched on, so an input the session started without opens exactly as it would
have at the start. Switching one *off* still leaves its stream running and only
stops its contribution to the mix, which is §8's rule that a toggle never
restarts capture.

**What still differs is when a refusal arrives.** `AudioCapture::Start` returns as
soon as its capture thread exists and the endpoint is opened on that thread, so on
Windows neither toggle can fail in the call: a refused open comes back afterwards
as a non-fatal `microphoneUnavailable` / `systemAudioUnavailable` error, with the
`inputChanged` correction `OnInputLost` raises behind it — the degrade path of
`../adr/2026-08-23-optional-inputs-degrade-instead-of-blocking.md` rather than a
failed call. macOS answers `setMicrophoneEnabled` itself: `startMicrophone()`
throws inside the call, the flag goes back to off and the error is emitted before
it returns. It is asynchronous only for system audio, where opening the tap is an
`SCStream.updateConfiguration` the stream applies in its own time — the shape
Windows now has for both inputs. Neither host fails the toggle on the wire; both
are contracted to answer `null` (`platform-channel-contract.md`).

The consequence a user sees is that the Windows microphone-in-use indicator
follows the switch too. The process holds a capture endpoint only for a recording
the microphone was on for, so Relay should be expected under recent microphone
activity in the privacy settings for those recordings and not for the others,
which is the same match between what the operating system reports and what the
strip says that the macOS paragraph above promises. A user who never switched the
microphone on is no longer told mid-recording that it stopped responding either:
nothing opens an endpoint for it, so nothing can fail for it. Reasoned from the
sources, not observed — nothing on this side has been run on a Windows host
(`../development/compatibility-matrix.md`).

Use monotonic timestamps for A/V synchronization. Do not synchronize media using wall-clock time.

## Backpressure

Every producer/consumer boundary must be bounded.

For each queue define:

- maximum capacity;
- what happens when full;
- whether producer throttles;
- whether newest/oldest frames are dropped;
- metrics emitted for drops.

Never use unbounded frame/audio queues.

Prefer controlled frame dropping over progressive memory exhaustion.

## Threading

- no video encoding on Flutter UI thread;
- no audio mixing on Flutter UI thread;
- no blocking network operations in capture callbacks;
- avoid unnecessary frame copies;
- prefer zero-copy/GPU paths where practical;
- measure before optimizing.

## Hardware encoding

Prefer hardware H.264 encoding where available.

Potential platform paths:

- macOS: VideoToolbox / appropriate AVFoundation integration;
- Windows: Media Foundation / hardware-backed encoder path.

Fallback behavior must be capability-driven and tested.

## Shared media core

Do not add FFmpeg/Rust/C++ solely for architectural symmetry.

Before introducing one, create an ADR covering:

- concrete need;
- alternatives;
- performance;
- binary size;
- packaging;
- licensing;
- hardware encoding;
- debugging/crash complexity;
- future Linux benefit.

## Required reliability validation

Changes to capture, composition, encoders, queue sizes, timestamps, or bridge behavior require relevant platform/integration/performance validation. See `../development/testing.md`.
