# Inputs are chosen from a device list, before and during a recording

**Status:** Accepted
**Date:** 2026-08-30
**Accepted:** 2026-08-30 by the product owner, after reviewing the design

## Context

Every input this product records is a boolean. `microphoneEnabled`,
`cameraEnabled` and `systemAudioEnabled` say *whether* a source contributes;
nothing says *which device* it is. The platform takes its own default, and the
application never learns what that default was.

That is wrong in the ordinary case, not an edge one. A laptop with an external
webcam has two cameras and the built-in one is usually the system default. A
headset makes two microphones, and which one is default depends on what was
plugged in last. The user discovers the wrong choice by hearing themselves back
— which is to say, after the recording. Today the only remedy is to change the
operating system's default device and start again.

The product owner's requirement is explicit: the camera and the audio inputs
must be selectable **both before a recording starts and while it is running**.
The capture source (display or window) stays a before-only choice; the reasons
are in §4.1 and are not reopened here.

One platform asymmetry decides part of the shape. On Windows, system audio is
WASAPI loopback against a specific *render endpoint*, so "which output am I
recording?" is a real question with a real answer. On macOS, ScreenCaptureKit
delivers the system mix for the captured content; there is no endpoint to pick.
A design that assumes three selectable kinds everywhere would have to answer
that question on macOS by inventing one.

## Decision

Devices become a value object in the platform interface, enumerated by the
platform and selected by the application.

```text
MediaDevice
├── id            // opaque, platform-owned; never parsed by application code
├── kind          // camera | microphone | systemAudio
├── label         // what the user reads
├── isSystemDefault
└── isAvailable
```

`RecorderCapabilities` gains `selectableDeviceKinds: Set<MediaDeviceKind>`.
macOS reports `{camera, microphone}`; Windows reports all three. The UI draws a
chooser for a kind if and only if it is in that set — a capability, never an
operating-system name (§28). A kind that is not selectable is still recorded;
it simply has one device, and the UI says what that device is rather than
offering a list of one.

`RecordingConfiguration` gains `cameraDeviceId`, `microphoneDeviceId` and
`systemAudioDeviceId`, each nullable. **Null means the platform default**, which
is exactly today's behaviour, so an unconfigured session records precisely what
it records now.

Selection while recording is a platform command of its own:

```text
selectInputDevice(kind, deviceId?) -> void      // valid in `recording` and `paused`
```

The platform swaps the input on the live session. It does not restart capture,
does not close the output file, and does not produce a second track: the file
keeps one video track and one mixed audio track, as §11 requires.

Per kind:

- **camera** — the new device is opened, the compositor is pointed at it and
  the old one is closed. The picture-in-picture geometry is untouched; if the
  new camera has a different shape, the tile takes it, exactly as
  `docs/adr/2026-08-23-camera-pip-follows-source-aspect.md` already specifies.
- **microphone** — the mixer opens the new input and resamples it into the
  session's fixed mix format. The timeline is monotonic (§8), so the swap
  gap is silence at a known position, never a drift.
- **system audio (Windows)** — the loopback client is re-armed on the new
  endpoint under the same rule.

Failure is degradation, never a stopped recording. A device that will not open
leaves the previous one running and raises a non-fatal event; a device that
disappears mid-session falls back to the system default of the same kind, and if
there is none, that input switches off and the strip shows it off. This is the
rule `docs/adr/2026-08-23-optional-inputs-degrade-instead-of-blocking.md`
already sets for a denied input, applied to a lost one.

Hot-plug is an event, not a poll: the platform reports device-list changes, and
any open chooser re-renders from the new list.

### Hearing the input: the level meter

A list of device names does not answer the question the user actually has, which
is *is this one hearing me?* Two microphones with plausible names and one of them
muted at a hardware switch are indistinguishable until the recording is played
back. So the **microphone** carries a live level meter.

System audio does not, on either platform. A level is worth showing when the
user can act on it, and here they cannot: on macOS there is no endpoint to
choose, and on neither platform can they change what the machine is playing from
inside this application. A bar that only ever says "something is playing, or
nothing is" is decoration on a window floating over someone's recording.

| | |
|---|---|
| What it shows | the **selected** device — change the selection and the meter follows it, so two microphones are compared by speaking rather than by guessing |
| Where | under the device row on the launch screen, in the microphone sheet, and as a fill inside the strip's own microphone square |
| What crosses the channel | a metering value (peak and RMS, ~20 Hz), never audio. §3's rule that raw buffers stay native is unaffected |
| When it runs | only while a meter is on screen. Metering is started and stopped explicitly; nothing opens a device to animate a bar nobody is looking at |
| Before recording | metering opens the device briefly, which needs the permission. Without it the meter says so instead of sitting flat |
| During recording | levels come from the live mixer — no second open of a device already in use |
| System audio | not metered at all — see above |
| Silence | a flat bar for three seconds on an enabled input is reported as a finding — "nothing has reached this microphone" — not left as a blank control |
| Muted input | the bar is drawn dead rather than hidden, so "off" and "broken" do not look the same |

The meter is diagnostic, not decorative: it exists so a bad recording is
prevented rather than discovered.

### Where the choice lives on the launch screen

On / Off stays on the input's row, where it is today. Everything the device
selection adds — the device, its meter, the camera's shape presets — sits behind
a **disclosure**, closed by default and remembered per input between launches.

Closed, the launch screen is the one that shipped: three rows, three toggles.
Open, each input names the device it will use. The alternative was three
permanently taller rows for a choice most sessions never change, on a panel
whose minimum height is already a constraint (§33.6).

The chosen devices persist in `AppSettings` as `id` **and** `label`. On the next
launch an id that no longer resolves falls back to the system default, and the
launch screen says which device it could not find rather than silently recording
the wrong one.

## Alternatives considered

- **Choose devices before the recording only.** Rejected: the wrong microphone
  is discovered while talking into it. Half the requirement, and the half that
  is easy.
- **Let the operating system's sound and camera settings be the chooser.**
  Rejected: it is two applications for one task, it changes the default for
  every other program on the machine, and on macOS it cannot be done without
  leaving a recording that is capturing the screen it is being done on.
- **A native device picker per platform.** Rejected for the reason §4.1 already
  rejected a native source picker: two different surfaces, neither of them
  ours, and no way to show the same information on both platforms.
- **A `String?` device id on the configuration, with no enumeration.**
  Rejected: without a list there is nothing to choose from, no label to show,
  and no way to notice a device that has gone away.
- **Meter system audio too, for symmetry.** Rejected: symmetry is not a reason
  to show a number nobody can act on, and it would put a moving element in the
  strip that changes whenever the machine makes a sound.
- **A "test recording" button instead of a live meter.** Rejected: it makes the
  user record, stop, and listen to answer a question a bar answers continuously,
  and it cannot be used during the recording that is already running.
- **Per-device meters, one bar per row.** Rejected: it means opening every
  microphone on the machine at once to animate a menu — expensive, and on macOS
  it lights the recording indicator for devices the user has not chosen.
- **Model system audio as selectable everywhere and return a one-item list on
  macOS.** Rejected: it reads as a choice the user has made when they have not,
  and it would put a disclosure chevron on a control that cannot disclose
  anything. `selectableDeviceKinds` says the true thing instead.

## Consequences

The method-channel contract grows: device enumeration, a device-changed event,
and `selectInputDevice`. `docs/architecture/platform-channel-contract.md` is
updated on acceptance, on both platforms or neither.

macOS cannot offer a system-audio device. That is a visible product difference
and belongs in `docs/development/compatibility-matrix.md`, not in a footnote.

The control strip needs somewhere to put three choosers without changing size.
That is `docs/adr/2026-08-30-movable-control-strip-and-input-menus.md`.

Metering adds a low-rate event to the channel and a start/stop command, and the
strip's microphone square gains a level fill. Neither changes what crosses the
boundary in kind: still control and metadata, never media.

Audio device swapping is the riskiest part: a mixer that assumes one input
format for the life of a session has to stop assuming it. §24's soak tests grow
a case that swaps the microphone repeatedly during a long recording and
verifies that audio stays in sync with video at the end of it.
