# Technical Specification — Cross-platform Screen Recorder

**Status:** MVP specification  
**Version:** 0.4 — plus §33, proposed v0.5 scope awaiting review  
**Date:** 2026-08-22 (§33 added 2026-08-30)  
**Target platforms for MVP:** macOS, Windows  
**Deferred platform:** Linux  
**Primary UI stack:** Flutter / Dart

> This document is the product and technical source of truth for the MVP.  
> Requirements marked **TBD** are intentionally unresolved and must not be silently invented during implementation.

---

## How this file is superseded

An ADR in `docs/adr/` with **Status: Accepted** and a date later than this file's
overrides it on the point it decides. This file is not rewritten for every such
decision, so where the two disagree, **the ADR is current and this file is stale**.
Report the staleness; do not implement the stale side.

Where a summary table (§2, §31) disagrees with the numbered section body, the body
wins — the tables are digests and drift first.

### Applied amendments

| Amended | Decision | ADR |
|---|---|---|
| §1, §2, §3, §12, §14, §21, §27, §29, §31 | Google Drive removed; destinations are Telegram + WebDAV | `docs/adr/2026-08-23-telegram-only-destination.md`, `docs/adr/2026-08-23-webdav-second-destination.md` |
| §31 | Camera PiP takes the camera's own aspect ratio at `0.16 × canvas width` | `docs/adr/2026-08-23-camera-pip-follows-source-aspect.md` |
| §4.2 | Windows capture builds a `GraphicsCaptureItem` per selected source, not window-only | `docs/adr/2026-08-22-capture-source-scope-and-selection-ux.md` |
| §2, §29, §31 | Post-recording has a third action, New recording | — (shipped; `lib/features/post_recording/`) |

Two consequences of the Drive removal are **not** resolved here and are owner
decisions: §24's resumable-upload release gate and §30 item 6. Both are marked in place.

### Proposed, not yet in force

**§33** carries scope requested on 2026-08-30 — device selection with level
meters, a movable control strip with device menus, a camera picture-in-picture
dragged by hand and sized by preset, and a responsive panel. All four ADRs were
**accepted on 2026-08-30** and the work is delivering in stages, so §33 is the
live requirement for what it covers and §33.10 says which stages have shipped.
Each part folds into its numbered section as it lands.

One item there is not an addition but an amendment to a **core invariant**: the
`Square` and `Circle` camera presets crop the frame, which §7 and `CLAUDE.md`
still forbid outright. §33.5 states the replacement rule; both are amended when
that stage ships, and not before.

---

## Documentation routing

Detailed engineering guidance intentionally lives outside this file to avoid bloating always-on agent context:

- `CLAUDE.md` — short mandatory project instructions and routing map;
- `docs/ARCHITECTURE.md` — architecture overview and dependency direction;
- `docs/architecture/recording.md` — recording state/lifecycle;
- `docs/architecture/media-pipeline.md` — capture/composition/encoding rules;
- `docs/architecture/uploads.md` — upload abstraction, Telegram, WebDAV;
- `docs/architecture/platform-abstraction.md` — Flutter/native boundary and platform plugins;
- `docs/architecture/platform-channel-contract.md` — the method-channel wire contract;
- `docs/development/testing.md` — mandatory tests, CI and release gates;
- `docs/development/compatibility-matrix.md` — what is actually built and verified per platform;
- `docs/development/design-system.md` — mandatory design system and reusable components;
- `docs/development/code-quality.md` — scalability, reliability, security and review rules;
- `docs/adr/` — expensive-to-reverse architectural decisions.


## 1. Product goal

Build one desktop application for macOS and Windows that records an entire screen or a selected application window, optionally composites camera video, records microphone and computer audio, saves a single local MP4 file, and lets the user either upload the result or delete it.

The upload destination is selected in Settings and must be implemented behind a common interface. MVP destinations:

- Telegram Bot API
- WebDAV

## Design source of truth

The UI/UX design is authored in Claude Design and reachable through the `claude_design` MCP connection.

Design file:

`Screen Recorder - Desktop MVP.dc.html`

A synchronized copy is vendored in the repository so the design is readable and
reviewable without the MCP connection:

```text
design/
├── Screen Recorder - Desktop MVP.dc.html   # the canvas document (source of truth)
├── preview.html                            # generated static render, viewable offline
├── support.js                              # canvas runtime
├── scripts/render_design_preview.py        # regenerates preview.html
└── _ds/industry-<id>/                      # the Industry design system
    ├── styles.css                          # tokens + component classes
    ├── readme.md                           # how the system is meant to be used
    ├── _ds_manifest.json                   # machine-readable token registry
    └── _adherence.oxlintrc.json
```

`design/_ds/industry-<id>/styles.css` is the token source the Flutter design
system must be derived from. Re-pull the design and regenerate `preview.html`
whenever the canvas changes; do not hand-edit the vendored copy.

Synchronization is **one-way, design → repository**. The design project carries
design only; do not upload engineering documents into it, including this
specification. This file is the single copy, and a mirrored second copy beside the
canvas would go stale and compete with it as a source of truth.

The connected design is the **visual source of truth** for layout, spacing, typography, colors, iconography, component appearance, visual hierarchy, interaction layout, window presentation, overlay presentation, and visual states represented in the design.

`TECHNICAL_SPEC.md` remains the **product and technical source of truth** for behavior, business rules, recording semantics, state transitions, file/data lifecycle, platform behavior, architecture, permissions, security, uploads, and error semantics.

If design and specification conflict, do not silently choose one. The latest explicit product requirement takes precedence; otherwise the conflict must be surfaced before implementing the conflicting behavior.



Linux is not part of MVP, but the application architecture must allow a Linux capture implementation and other upload destinations to be added later without changing the Flutter application layer.

---

## 2. Confirmed MVP scope

### Included

- macOS desktop app
- Windows desktop app
- Flutter-based shared UI/application layer
- recording of **one entire screen** (default source)
- recording of **one selected application window**
- visible mouse cursor in the recording
- microphone capture
- system/computer audio capture
- optional camera capture
- live recording controls overlay
- camera preview overlay
- Pause / Resume
- Stop
- microphone toggle during recording
- camera toggle during recording
- system audio toggle during recording
- quality setting: 720p / 1080p
- FPS setting: 30 / 60 FPS
- default FPS: 30
- output container: MP4
- video codec: H.264
- audio codec: AAC
- one final video track
- one final mixed audio track
- camera composited into the final video
- microphone + system audio mixed into the final audio
- Send / Delete / New recording actions after recording
- upload destination setting: Telegram / WebDAV
- local file deletion after successful upload
- preservation of the local file after upload failure
- upload progress
- architecture that supports additional capture platforms and upload destinations

### Deferred

- Linux
- 120 FPS
- region capture
- multiple simultaneous windows
- multiple monitors as one recording source
- editing / trimming
- annotations
- cloud history
- local recording library UI
- multiple simultaneous upload destinations
- live streaming
- background removal for camera
- watermarking

---

## 3. High-level architecture

```text
┌─────────────────────────────────────────────────────────┐
│                    Flutter application                  │
│                                                         │
│  Main UI   Settings   Recorder VM   Upload UI           │
│      │         │           │           │                │
└──────┼─────────┼───────────┼───────────┼────────────────┘
       │         │           │           │
       │         │       control/events  │
       │         │           │           │
       ▼         ▼           ▼           ▼
┌──────────────────────┐   ┌──────────────────────────────┐
│ Recording facade     │   │ UploadCoordinator            │
│ / platform interface │   │                              │
└──────────┬───────────┘   └──────────────┬───────────────┘
           │                              │
    ┌──────┴───────┐              ┌───────┴────────┐
    ▼              ▼              ▼                ▼
macOS native   Windows native  Telegram        WebDAV
capture/media  capture/media   destination     destination
pipeline       pipeline
```

### Architectural rule

Flutter owns:

- UI
- user settings
- recording state presentation
- orchestration
- upload destination selection
- progress display
- business rules
- error presentation

Native code owns:

- window capture
- cursor capture
- camera frame capture where appropriate
- microphone capture
- system audio capture
- frame timing
- audio/video synchronization
- video composition
- audio mixing
- encoding
- muxing

**Raw video frames and raw audio buffers must not be continuously transferred through Flutter platform channels.**

Flutter platform channels / FFI are for commands, configuration, state, progress, errors, and metadata. The high-throughput media pipeline stays native.

---

## 4. Capture model

MVP supports two capture source types:

```text
CaptureSource
├── Display       // default
└── Window
```

The domain model must still be extensible:

```text
CaptureSource
├── Display
├── Window
└── Region        // future
```

`Display` is the default source. `CaptureSourceType` must remain a value object;
do not encode the choice as a boolean such as `isFullScreen` (§28).

### 4.1 Source selection

Before recording, the user must select exactly one capture source: one display,
or one capturable application window.

The default source is the display containing the main application window (§5).

**Decided** (was §30.1, see `docs/adr/2026-08-22-capture-source-scope-and-selection-ux.md`):
source selection uses a **custom in-application source list**, not a native
system picker.

Required behavior:

- displays are listed first, then windows;
- each entry carries a still thumbnail, a title and a subtitle;
- thumbnails come from one shareable-content snapshot refreshed on focus, not a live stream;
- the list is reachable both at launch and from the launch screen's Change action;
- source enumeration stays behind `CaptureSourceProvider`, so a platform that
  exposes only a native picker can implement the same contract.

Rationale: a custom list is the only option that renders both source types in one
surface, keeps the thumbnail/selection presentation inside the design system, and
behaves identically on macOS and Windows.

#### Which windows are listed

The list offers windows a user can point at, and nothing else. One rule, the
same on both platforms — the alt-tab rule:

| Offered | Not offered |
|---|---|
| on screen | minimised, offscreen, or cloaked |
| at the ordinary window level | menu bar and its status items, the Dock, notification banners, tooltips, wallpaper and desktop layers, other applications' floating palettes |
| top-level | owned/child windows, unless explicitly marked app-like |
| titled | untitled surfaces, whose entry could only read as the application name repeated |
| owned by a named application | windows with no owning application |
| at least 96 × 96 | smaller helper surfaces |
| any application but this one | this application's own panel and overlays |

macOS resolves the level from `SCWindow.windowLayer` and Windows from the
`WS_EX_TOOLWINDOW` / `GW_OWNER` / `DWMWA_CLOAKED` triple; the *rule* is one
rule, and it is expressed in a pure, unit-tested predicate on each side
(`CapturableWindowRule`, `IsCapturableWindow`). Two pickers that disagreed about
what a window is would be two products.

#### Thumbnails are not decorative

A capture thumbnail is how the user tells one of fifteen windows from another,
so it is shown in its own colours. The design system's `.duotone` accent wash
applies to photography and to placeholders; it does not apply here, because two
accent-washed screenshots look like the same screenshot.

### 4.2 Platform implementation

#### macOS

Primary API:

- ScreenCaptureKit
- `SCShareableContent`
- `SCContentFilter`
- `SCStream`

ScreenCaptureKit supports capture of a specified window using a window-specific content filter.

#### Windows

Primary API:

- `Windows.Graphics.Capture`
- `GraphicsCaptureItem`
- `GraphicsCaptureSession`

The recording engine must build a `GraphicsCaptureItem` for whichever source §4 selected:
`CreateForMonitor` for a display, `CreateForWindow` for a window.

### 4.3 Cursor

Mouse cursor must be present in the final recording.

```text
showCursor = true
```

Cursor handling belongs to the platform capture layer.

### 4.4 Window movement and resize

The recording must not crash if the selected source window moves or changes size.

**TBD:** exact output policy when the source aspect ratio or dimensions change during a session:

- maintain a fixed output canvas and letterbox/pillarbox;
- dynamically resize encoded output;
- another policy.

The implementation must not silently crop or distort the content.

### 4.5 Source window closed

If the selected window is closed or becomes permanently unavailable, the recorder must leave the `recording` state cleanly and preserve any recoverable recording data.

**TBD:** UX wording and whether the session is finalized automatically or shown as an error requiring user action.

---

## 5. Current display definition

The application's **current display** is the display that contains the main application window.

This definition is used for placement of recorder UI/overlay windows.

It is defined independently from the selected capture source, and remains so in
window mode. In display mode the captured display and the current display are
usually the same one, but they must not be assumed identical: the user may select
a display other than the one holding the main window.

If the main application window moves to another display before recording begins, the current display must be recalculated.

**TBD:** behavior if the main application window changes display while recording is already active.

---

## 6. Recording overlay

During an active session, show an always-on-top control overlay on the current display.

Required controls:

```text
┌──────────────────────────────────────────────────┐
│ 🎙 Mic │ 📷 Camera │ 🔊 System audio │ ⏸/▶ │ ⏹ │
└──────────────────────────────────────────────────┘
```

### Defaults

| Control | Default |
|---|---|
| Microphone | ON |
| Camera | OFF |
| System audio | ON |
| Recording state | Recording |

### Required behavior

- Microphone toggle works while recording.
- Camera toggle works while recording.
- System audio toggle works while recording.
- Pause switches to Resume.
- Stop finalizes the recording.

### Placement and size

The strip is docked to the **usable** area of the current display, not to the
raw display bounds: below the macOS menu bar, above the Windows taskbar. The
menu-bar band is not neutral space — on a notched Mac it contains the notch,
where a control is neither drawn nor clickable, and the design's own note on
design `1f` requires a strip small enough to dock without covering a menu bar.
Resolve anchored placements against `NSScreen.visibleFrame` / `MONITORINFO.rcWork`.

The strip **must present the same size in every session state**, and it must be
the compact one. Its host window is sized to what the strip measures, so a strip
that grew on pause would resize that window during the click that paused it and
move every remaining control out from under the cursor. Render the paused state
in place — accent frame, hollow status dot, accent-filled play glyph — rather
than by adding a tag and widening a button.

Each control's hit target extends into the gap beside it. A 32 px control with
12 px of dead space around it is a 32 px target on a window that floats over
someone else's work; taking half the gap on each side costs nothing visually and
makes the whole strip live.

One command at a time. Every strip command reads the session state, asks the
platform to change it and only then records the change, so two overlapping
clicks would both read the state before either wrote it — and a second `pause`
against an already-paused platform session is an error, not a no-op. Drop the
overlapping command, and treat a refused pause/resume as a lost click rather
than as a failed recording.

The host window must be re-sized to the last measured content size whenever the
strip is shown again. The overlay engine outlives a session and reports a size
only when its own content changes, so a second recording that re-applies the
placement's nominal size would leave the trailing controls — Pause and Stop —
rendered outside the window, where a click never reaches them.

### Critical requirement: overlay exclusion

The control overlay **must never appear in the captured video**.

This applies to the camera preview overlay (§7) on the same terms.

Implementation principles:

- overlay is a separate top-level window;
- overlay is never a child/content layer of the selected source window;
- native capture is scoped to the selected target;
- every application-owned always-on-top surface is passed to the capture filter's
  exclusion list — `SCContentFilter(display:excludingWindows:)` on macOS,
  `WDA_EXCLUDEFROMCAPTURE` on Windows;
- automated integration tests must verify that recorder controls are absent from the produced video.

Do not rely on visual placement outside the source bounds as the only exclusion mechanism.

**Display mode makes exclusion the sole mechanism.** With a window source, the
content filter already scopes the overlays out, and explicit exclusion is
defense-in-depth. With a display source — now the default (§4) — the control strip
and the camera preview sit inside the captured bounds by definition, so explicit
exclusion is the *only* thing keeping them out of the file. Overlay-exclusion
integration coverage must therefore run against a display source, not only a
window source.

---

## 7. Camera

### Default

```text
cameraEnabled = false
```

### When enabled

Camera video must:

1. be visible to the user as a live camera preview overlay;
2. be composited into the final recording;
3. appear in the lower-right area of the final video.

The camera must **not** be captured indirectly by screen/window capture.

Correct pipeline:

```text
Camera capture ───────────────┐
                              ▼
Window capture ───────► Video compositor ─────► H.264 encoder
```

The preview overlay and final-video PiP use the same logical camera source, but final composition happens in the media pipeline.

### Camera PiP

Confirmed:

- position: lower-right
- part of final video

**Decided** (was §30.2, see `docs/adr/2026-08-22-camera-pip-composition.md`,
whose size and shape rows are superseded by
`docs/adr/2026-08-23-camera-pip-follows-source-aspect.md`).
`CameraOverlayConfiguration` defaults:

| Parameter | Value |
|---|---|
| Width | `0.16 × canvas width` |
| Shape | the camera's own aspect ratio |
| Fallback shape | `16:9`, until the camera reports its own |
| Corner radius | `0` |
| Margin from edges | `0.01 × canvas width` |
| Preview | mirrored |
| Final output | not mirrored |

Ratios rather than pixels, so 720p and 1080p and both display and window canvases
share one configuration.

The camera frame is **never distorted**, and is **cropped only by an explicit
shape preset** — identically in the preview and in the file
(`docs/adr/2026-08-30-user-adjustable-camera-pip.md`, §33.5).

The default preset, `camera`, still never crops: the tile takes the camera's own
shape (`followsSourceAspectRatio`), so there is nothing to crop and nothing to
stretch — the same constraint §10 places on the capture source. `Square · small`
and `Circle · small` take the centre of the frame, because a 16:9 sensor cannot
fill a square any other way and letterboxing inside one leaves a tile that is
part desktop. Nothing crops that the user did not ask for by name.

The camera's shape comes from the capture device's active format, not from a
captured frame: the preview is placed as soon as the camera starts, before the
first frame arrives. The host resolves the picture-in-picture rectangle, because
only the host knows what the camera produces; the application places the preview
from the fallback shape and sends the configuration with it.

All values remain configuration, not hard-coded compositor constants. The table
above defines defaults, not a fixed compositor contract.

---

## 8. Audio

Two logical audio sources exist:

```text
Microphone
System audio
```

### Defaults

```text
microphoneEnabled = true
systemAudioEnabled = true
```

### Composition

```text
System audio ───┐
                ├──► Audio mixer ───► AAC encoder
Microphone ─────┘
```

Final file contains one mixed audio track.

### Runtime toggles

If microphone is turned OFF:

- microphone samples stop contributing to the mix;
- recording continues.

If system audio is turned OFF:

- system audio stops contributing to the mix;
- recording continues.

If both are OFF:

- video recording continues without audible content for that interval.

### Platform implementation

#### macOS

Use ScreenCaptureKit for captured application/system audio where supported by the target OS. Microphone capture may use ScreenCaptureKit capability when the chosen minimum macOS version supports the required behavior, or another native Apple audio capture API behind the same abstraction.

#### Windows

Use WASAPI loopback for computer/system output audio and the appropriate native capture API for microphone input.

### Audio synchronization

All sources must be synchronized against one monotonic recording timeline.

Do not synchronize streams using wall-clock time.

---

## 9. Pause / Resume

State transition:

```text
recording ⇄ paused
```

While paused:

- capture/encoding behavior must not leak an unbounded buffer;
- UI remains responsive;
- toggles may be presented according to final UX.

**Recommended semantics, pending confirmation:** paused time does not appear in the final recording timeline.

This must be explicitly covered by automated tests once confirmed.

---

## 10. Quality and FPS settings

### Resolution setting

Available values:

```text
720p
1080p
```

### FPS setting

MVP values:

```text
30 FPS
60 FPS
```

Default:

```text
30 FPS
```

### 120 FPS

Not included in MVP.

The model/API must not use a boolean such as `highFrameRate`. Use a capability-driven representation:

```text
supportedFrameRates: Set<int>
selectedFrameRate: int
```

This allows 120 FPS to be added later after a platform/performance PoC.

### Output dimensions

A 720p/1080p quality preset defines the target output quality/canvas policy.

**TBD:** precise handling for sources whose aspect ratio is not 16:9 — non-16:9
application windows, and displays that are not 16:9 (for example 16:10 or ultrawide).
The source aspect ratio must not be distorted. This remains §30.3.

---

## 11. Output format

Confirmed output:

- container: MP4
- video: H.264
- audio: AAC

One completed recording produces one file.

```text
Window video
+ Camera PiP (optional)
+ Cursor
+ Mixed audio
        ↓
single .mp4
```

### Encoding strategy

Prefer hardware-accelerated H.264 encoding when available, with a tested software fallback if required.

Do not make exact video bitrate a user-facing setting in MVP.

Use a quality-oriented/VBR profile appropriate to selected resolution and frame rate, validated through PoC and visual testing.

---

## 12. Estimated file size

File size depends primarily on **average bitrate**, not resolution alone.

Approximation:

```text
size_GB_per_hour ≈ total_bitrate_Mbps × 0.45
```

The following values are **capacity-planning examples**, not fixed encoder requirements. They assume H.264 plus approximately 192 Kbps AAC audio.

| Example profile | Video bitrate | Approx. 60-minute size |
|---|---:|---:|
| 1080p30, efficient screen content | 4 Mbps | 1.89 GB |
| 1080p30, higher quality | 6 Mbps | 2.79 GB |
| 1080p60, efficient | 8 Mbps | 3.69 GB |
| 1080p60, higher quality | 12 Mbps | 5.49 GB |
| Future 1080p120 example | 16 Mbps | 7.29 GB |
| Future 1080p120 higher quality | 24 Mbps | 10.89 GB |

Actual VBR recordings can be much smaller for mostly static UI and larger for high-motion content.

### Consequence

The standard Telegram Bot API upload limit of 50 MB is not suitable as the primary transport for normal long-form 1080p recordings.

Telegram is the default destination for recordings that fit in a chat. WebDAV carries
what exceeds the hosted 50 MB cap and has no size limit of its own.

A user-run Local Bot API Server raises Telegram's own ceiling to 2000 MB (§16); that is a
present requirement, not a future one.

---

## 13. Post-recording flow

After Stop:

```text
Stop
  ↓
Finalize local MP4
  ↓
Ready
  ↓
┌─────────────┬─────────────┬────────────────┐
│ Send        │ Delete      │ New recording  │
└─────────────┴─────────────┴────────────────┘
```

### Send

Uses the upload destination currently selected in Settings.

```text
Local file
  ↓
UploadDestination
  ↓
Remote success confirmed
  ↓
Delete local file
```

### Delete

Deletes the local recording without upload.

**Decided** (was §30.5, see `docs/adr/2026-08-22-delete-confirmation.md`):
Delete requires a confirmation dialog **only when the recording has never been
uploaded** — the irreversible case.

- the dialog states duration and size, and that the action cannot be undone;
- actions are Keep (secondary) and Delete (primary);
- post-upload cleanup (§18) is automatic and silent, and shows no dialog.

Consequence: the dialog appears at most once per recording.

### New recording

Returns to the recorder ready to start again, with the recording untouched:
nothing is uploaded and nothing is deleted (§18). Send and Delete were the only
two ways out of Ready, which left no way to keep a recording and get on with the
next one.

It states where the file was left, because afterwards the session no longer
refers to that recording.

### Failure rule

If upload fails or is cancelled:

- local file must remain available;
- user must be able to retry or change destination — Change opens Settings,
  which is the one place that both selects a destination and connects it;
- the app must not delete the recording automatically.

---

## 14. Upload architecture

Uploading is a replaceable module.

Core abstraction:

```text
UploadDestination
├── id
├── displayName
├── capabilities
├── validate(file)
├── upload(file, metadata)
├── cancel(uploadId)
└── events/progress
```

Conceptual Dart contract:

```dart
abstract interface class UploadDestination {
  String get id;

  UploadCapabilities get capabilities;

  Future<UploadValidationResult> validate(RecordingFile file);

  Stream<UploadEvent> upload(
    RecordingFile file,
    UploadContext context,
  );

  Future<void> cancel(String uploadId);
}
```

Implementations:

```text
TelegramUploadDestination
WebDavUploadDestination
FutureUploadDestination
```

The recording feature must not import Telegram- or WebDAV-specific APIs.

### Upload state

```text
idle
  ↓
validating
  ↓
uploading(progress)
  ├──► cancelled
  ├──► failed
  ▼
succeeded
  ↓
deletingLocalFile
  ↓
completed
```

### Common requirements

- progress reporting
- cancellation
- network errors surfaced as typed domain errors
- retry support
- file-size preflight when destination has a hard limit
- no deletion before confirmed remote success
- destination-specific logic isolated behind the common interface

---

## 15. Upload destination setting

Settings contain:

```text
Upload destination
○ Telegram      <account line>   [Set up]
○ WebDAV        <account line>   [Set up]
```

Neither destination may require a developer account, an API console or a payment
method: that requirement is what removed Google Drive
(`docs/adr/2026-08-23-telegram-only-destination.md`) and what chose WebDAV over
Dropbox and Backblaze B2
(`docs/adr/2026-08-23-webdav-second-destination.md`).

Exactly one destination is active for a Send action in MVP.

Persist the selected destination between app launches.

The architecture may later support multiple destinations, but MVP must not upload to both automatically.

### Connecting a destination

Every destination must be connectable **from inside the application**. A
destination that needs credentials and offers no way to supply them is not
implemented (`docs/adr/2026-08-23-destination-credentials-in-app.md`).

A destination declares a `DestinationSetup`: whether it is connected by typed
values or by an interactive flow, the label of its action, ordered
plain-language instructions, and its fields. One screen renders any destination
from that declaration, so adding a destination adds no branch to the UI.

Required behavior:

- credentials are **verified with the service before they are stored**, and a
  refusal is reported in the connect screen with the service's own reason;
- secrets are written to OS-backed secure storage and never read back out for
  display — a secret field is shown empty, and submitting it empty keeps the
  stored value;
- `Disconnect` forgets the credentials and survives a restart;
- the account line in Settings re-resolves after the flow returns.

---

## 16. Telegram destination

### MVP configuration

Connected in Settings: a bot token, a chat id and an optional Bot API base URL.
The token is stored in OS-backed secure storage (§27), never in a file.

Relay verifies the pair with `getMe` and `getChat` before storing it, so a
mistyped token or a chat the bot cannot post to is reported at setup rather than
at the end of a recording.

A deployment may pre-seed a build through `.env`:

```text
TELEGRAM_BOT_TOKEN
TELEGRAM_CHAT_ID
TELEGRAM_BOT_API_BASE_URL   // optional, defaults to official API
```

Anything connected in the application takes precedence over the seed, and an
explicit disconnect is not undone by it.

Do not commit real credentials.

Provide `.env.example`, never a committed populated `.env`.

### Standard API limitation

As of 2026-08-22, the official Telegram Bot API documentation states that bots can send video/document files up to 50 MB through the standard hosted Bot API.

Therefore:

- validate file size before upload;
- fail fast with a user-visible explanation when the selected endpoint cannot accept the file;
- do not start a doomed upload.

### Local Bot API Server

Telegram publishes an open-source Bot API server that a user can run themselves.
It raises the upload ceiling from 50 MB to **2000 MB**, and it is free.

The Telegram destination must therefore allow its API base URL to be configured
rather than hard-coding the hosted Telegram endpoint.

Running the server is not part of the application: Relay does not install,
launch or supervise it. **Documenting it is**, because it is the only way past
the 50 MB cap now that Telegram is the only destination
(`docs/adr/2026-08-23-telegram-only-destination.md`). README carries the flow;
the base-URL field links to Telegram's own description of what a local server
changes.

The documented flow must include, in order:

- `api_id` / `api_hash` from my.telegram.org — the user's own account, not the
  bot, and free;
- running the server, by container or by source build, and its default port;
- the `logOut` call against the hosted API, which Telegram requires before a bot
  runs locally;
- the ordering constraint that follows: the chat id is discovered through the
  hosted API's `getUpdates`, and `logOut` locks the hosted API out for ten
  minutes, so the chat id must be obtained first;
- how to go back — `close` on the local server, then clear the base URL.

### Credential security

A bot token packaged inside a distributed desktop application cannot be considered secret.

A token the user connected themselves is their own, and lives in their keychain.
A token shipped inside a distributed binary is not a secret regardless of where
the application then stores it.

If the product becomes publicly distributed, redesign Telegram credentials around a backend/proxy or another trust model before release.

---

## 17. WebDAV destination

The destination for a recording that does not fit in a chat. No size limit of
its own, and no developer registration to reach it
(`docs/adr/2026-08-23-webdav-second-destination.md`).

WebDAV is a protocol, so one implementation serves Koofr, Nextcloud, ownCloud,
Box and others. No provider name may appear in the implementation; providers
belong in setup steps and field hints.

### Configuration

Connected in Settings: address, user name, app password, and an optional folder.
Requirements:

- authentication is HTTP Basic with an **app password** issued by the provider's
  own account settings — never the account password, which these providers
  reject;
- the password is stored in OS-backed secure storage (§27) and sent in a header,
  never in a URL, where it would reach logs and redirects;
- `connect` verifies before it stores: `PROPFIND` for the credentials, then
  `MKCOL` for the folder, so a wrong address, a rejected password or a
  read-only account is reported at setup rather than after a recording (§14);
- the address must be `http(s)`; anything else is refused without a request.

### Upload mechanism

A single streaming `PUT`. The file is read as it is sent, so memory does not
grow with the recording.

Requirements:

- progress reporting;
- cancellation;
- transient-failure retry, and a stall deadline — nothing may wait forever;
- **no resume.** WebDAV has no standard way to continue a partial `PUT`;
  `UploadCapabilities.supportsResume` must report false rather than claim a
  capability the protocol does not have. An interrupted transfer restarts, and
  §13's rule that the local file survives a failure is what makes that safe.

### Provider guidance

Koofr is the documented provider: 10 GB free, WebDAV on the free plan, app
passwords from a settings page.

Yandex.Disk is deliberately not suggested. It is reachable with this
implementation, but its WebDAV transfers are throttled to roughly one minute per
megabyte, which makes it unusable for video.

Google Drive was implemented here — OAuth 2.0 for desktop with PKCE, a loopback
redirect, resumable chunked uploads — and removed, because nothing in it could
be reached without first creating a project in the Google Cloud console. The
reasoning is in `docs/adr/2026-08-23-telegram-only-destination.md`. Its
requirements — system-browser authorization, PKCE, narrowest scope, refresh
tokens in OS-backed storage, resumable uploads, confirmed completion before
deleting local media — remain the standard for any OAuth destination added
later.

---

## 18. Local file lifecycle

Recording must be written incrementally to disk. Do not keep a complete recording in RAM.

Recommended lifecycle:

```text
recording-<id>.part
        ↓
capture / encode / mux
        ↓
successful finalize
        ↓
recording-<id>.mp4
        ↓
Send or Delete
```

Use an atomic or crash-safe finalization strategy where platform/filesystem semantics allow it.

### Deletion rules

Local file may be deleted only when:

1. user explicitly chooses Delete; or
2. selected upload destination reports successful completion.

Never delete because:

- upload started;
- all bytes were locally read;
- HTTP connection closed;
- app assumes success.

### Startup recovery

At startup, detect incomplete temporary recording artifacts.

Do not silently delete potentially recoverable data.

Recovery UX can be minimal in MVP, but data-loss behavior must be explicit.

---

## 19. Recording state machine

```text
idle
  ↓
selectingSource
  ↓
preparing
  ↓
recording
  ⇄ paused
  ↓
stopping
  ↓
finalizing
  ↓
ready
  ├──► deleting ───► idle
  └──► uploading
          ├──► uploadFailed ───► ready
          ├──► cancelled ──────► ready
          ▼
      uploadSucceeded
          ↓
      deletingLocalFile
          ↓
         idle
```

Capture-related errors:

```text
permissionDenied
sourceUnavailable
sourceClosed
cameraUnavailable
microphoneUnavailable
systemAudioUnavailable
captureFailed
encodingFailed
diskFull
finalizationFailed
```

Upload errors belong to the upload subsystem and must not corrupt the recording state.

---

## 20. Recorder interface

Conceptual API:

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

Configuration:

```dart
class RecordingConfiguration {
  final CaptureSource source;
  final RecordingQuality quality;
  final int frameRate;
  final bool cameraEnabled;
  final bool microphoneEnabled;
  final bool systemAudioEnabled;
  final bool showCursor;
}
```

Capabilities:

```dart
class RecorderCapabilities {
  final Set<RecordingQuality> qualities;
  final Set<int> supportedFrameRates;
  final bool supportsCamera;
  final bool supportsMicrophone;
  final bool supportsSystemAudio;
  final bool supportsPause;
}
```

Do not branch on `Platform.isWindows` / `Platform.isMacOS` throughout feature code. Platform choice belongs behind the recorder/platform interface.

---

## 21. Flutter application architecture

Follow separation of concerns:

```text
UI
↓
ViewModel / presentation state
↓
Use cases / application services where useful
↓
Repositories / service abstractions
↓
Platform plugins and external APIs
```

Recommended feature boundaries:

```text
lib/
├── app/
├── core/
│   ├── errors/
│   ├── logging/
│   └── settings/
├── features/
│   ├── recorder/
│   │   ├── domain/
│   │   ├── application/
│   │   └── presentation/
│   ├── settings/
│   └── post_recording/
└── upload/
    ├── domain/
    ├── application/
    └── presentation/
```

Platform integrations should be isolated in dedicated plugin/package boundaries, for example:

```text
packages/
├── recorder_platform_interface/
├── recorder_macos/
├── recorder_windows/
├── upload_core/
├── upload_telegram/
└── upload_webdav/
```

Exact package granularity may be reduced if it adds ceremony without isolation value, but the dependency direction must remain the same.

---

## 22. Native media requirements

### Threading

- never encode video on Flutter UI thread;
- never mix audio on Flutter UI thread;
- native capture callbacks must not perform blocking network/file operations;
- use bounded queues;
- define backpressure/drop strategy;
- no unbounded frame accumulation.

### Frame timing

- use monotonic timestamps;
- preserve A/V synchronization;
- account for Pause/Resume;
- dropped-frame statistics should be measurable.

### Hardware acceleration

Prefer hardware H.264 encoders:

- Apple VideoToolbox / appropriate AVFoundation path on macOS
- Media Foundation / hardware-backed encoder path on Windows

Exact encoder implementation must be validated in a PoC.

### Shared native media core

A shared C/C++/Rust/FFmpeg-based media core is **not required by this specification**.

Do not introduce FFmpeg only for architectural symmetry. If proposed, document:

- why native platform pipelines are insufficient;
- performance benefit;
- binary size impact;
- packaging complexity;
- licensing implications;
- hardware encoding behavior.

Use an ADR before adopting it.

---

## 23. Permissions

The app must detect and handle permissions before entering a recording session.

### macOS

Expected permission categories include:

- screen/window recording
- microphone
- camera

### Windows

Use platform-appropriate capture/device access checks.

### Rules

- permission denial is a typed state, not a generic exception;
- do not start a partially configured recording silently;
- if optional camera permission is denied and camera is OFF, recording may proceed without camera;
- if a user explicitly enables a source and required permission is unavailable, surface a clear error;
- **an answer the OS applies only to a fresh process is its own state**, `pendingRelaunch`, never
  reported as a refusal. macOS grants screen recording to the launched binary, so the process that
  asked cannot observe the answer;
- **the app offers the relaunch itself** where the platform needs one. A permission whose only
  remedy is "quit and open the app again" must not be left to the user to perform by hand;
- **"the platform could not be asked" is distinct from "the user has not been asked"**, and gets its
  own screen. An unreachable platform must not be presented as a first run;
- **only a refusal is reported as `permissionDenied`.** A capture-source enumeration that fails for
  any other reason is `sourceUnavailable`; blaming the user for a fault they did not cause sends
  them to a privacy pane where nothing is wrong;
- a process the OS attributes to whatever launched it, rather than to the app, must say so and
  offer to reopen itself properly.

Exact minimum OS versions remain **TBD** and must be selected after validating all required APIs.

---

## 24. Performance and reliability acceptance criteria

Exact numeric CPU/GPU budgets are **TBD**, but MVP must be validated with the following scenarios.

### Required soak tests

At minimum:

- 60-minute 1080p30 recording
- 60-minute 1080p60 recording
- microphone + system audio enabled
- camera enabled
- repeated camera/mic/system-audio toggles
- Pause / Resume
- selected window movement and resize
- display source with both overlays on screen
- network unavailable after Stop
- upload interruption and restart. Neither shipping destination resumes
  (`supportsResume: false`); a broken transfer restarts from zero, and that is the
  accepted behavior (§30.10). The gate is that the local file survives and the
  restart succeeds — not that the transfer continues from an offset.
- disk-space exhaustion
- capture source closure

### Must verify

- no progressive memory growth indicating a leak
- no UI freeze
- bounded capture/encode queues
- acceptable A/V synchronization
- final MP4 is playable
- overlay controls absent from output
- camera PiP present only when enabled
- local file retained after failed upload
- local file deleted after confirmed successful upload

---

## 25. Testing strategy

### Unit tests

Must cover:

- recording state machine
- settings persistence
- FPS/quality configuration
- upload destination selection
- upload validation
- file deletion rules
- retry decisions
- typed error mapping

### Integration tests

Per platform:

- source enumeration/selection
- window capture
- cursor visibility
- microphone capture
- system audio capture
- camera capture
- pause/resume
- overlay exclusion
- finalization

### Upload tests

Use fakes for normal application tests.

Real-service integration suites should be opt-in and use test credentials.

Never require production credentials to run the default test suite.

### Regression principle

Every fixed bug in recording state, file lifecycle, overlay exclusion, or upload deletion behavior should receive a regression test where technically practical.

---

## 26. Logging and diagnostics

Use structured logs.

Log:

- state transitions
- selected capability values
- non-sensitive device/source identifiers where safe
- capture errors
- encoder errors
- dropped-frame counts
- upload state
- retry state

Do not log:

- Telegram bot tokens
- WebDAV app passwords
- refresh tokens
- authorization codes
- full environment contents
- raw audio/video content

Debug logs must be redactable before user sharing.

---

## 27. Configuration and secrets

Allowed development configuration examples:

```text
TELEGRAM_BOT_TOKEN=
TELEGRAM_CHAT_ID=
TELEGRAM_BOT_API_BASE_URL=
```

Repository must contain:

```text
.env.example
```

Repository must not contain:

```text
.env
real tokens
refresh tokens
private credentials
```

These three keys are the whole set; `lib/core/environment/app_environment.dart` reads no
others. WebDAV has no `.env` seed keys at all — it is connected in Settings only.

Destination credentials belong in OS secure storage, not in environment variables.

---

## 28. Extensibility requirements

Do not encode product assumptions directly into implementation types.

Avoid:

```text
isTelegramUpload
isHighFps
isFullScreen
cameraIsBottomRightForever
```

Prefer capability/value objects:

```text
UploadDestinationId
CaptureSourceType
supportedFrameRates
VideoCompositionConfiguration
CameraOverlayConfiguration
```

Future additions should be possible without rewriting the recorder feature:

```text
CaptureSource
├── Window
├── Display
└── Region

UploadDestination
├── Telegram
├── GoogleDrive
├── S3
├── OneDrive
└── CustomBackend

VideoLayer
├── CapturedWindow
├── Camera
├── Watermark
└── Annotation
```

---

## 29. MVP UX flow

```text
Launch
  ↓
Select source (display — default — or window)
  ↓
Optional settings
  ├── Quality: 720p / 1080p
  ├── FPS: 30 / 60
  └── Upload: Telegram / WebDAV
  ↓
Start
  ↓
Permission / capability preflight
  ↓
Recording overlay
  ├── Mic ON/OFF
  ├── Camera ON/OFF
  ├── System audio ON/OFF
  ├── Pause/Resume
  └── Stop
  ↓
Finalize MP4
  ↓
Ready
  ├── Send
  │     ↓
  │   selected UploadDestination
  │     ↓
  │   success → delete local file
  │
  ├── Delete
  │     ↓
  │   delete local file
  │
  └── New recording
        ↓
      keep the file, return to the recorder
```

---

## 30. Open product decisions

Numbering is stable: resolved items keep their number and record where the
decision lives, so existing references stay valid.

**Resolved**

1. ~~Window selection UX: native system picker or custom window list.~~
   **Resolved 2026-08-22** — custom in-application source list, displays then
   windows. See §4.1 and `docs/adr/2026-08-22-capture-source-scope-and-selection-ux.md`.
2. ~~Camera PiP exact size, margin, shape, and mirroring rules.~~
   **Resolved 2026-08-22** — `CameraOverlayConfiguration` defaults in §7.
   See `docs/adr/2026-08-22-camera-pip-composition.md`.
5. ~~Delete confirmation UX.~~
   **Resolved 2026-08-22** — confirm only when the recording was never uploaded.
   See §13 and `docs/adr/2026-08-22-delete-confirmation.md`.
10. ~~Whether resumable upload remains a release gate.~~
    **Resolved 2026-08-25** — no. A broken upload restarts from zero on both
    destinations; the local file is preserved either way (§18). Resume stays a
    capability the `UploadDestination` contract can express
    (`UploadCapabilities.supportsResume`) if a future destination offers it.

**Still open — intentionally not invented**

3. Fixed-output behavior when the selected source changes aspect ratio/dimensions (§10).
4. Exact Pause timeline semantics (recommended: omit paused duration).
6. Google Drive target folder behavior. **Stale:** the destination was removed by
   `docs/adr/2026-08-23-telegram-only-destination.md`. Whether this closes as
   resolved-by-removal, or carries over to WebDAV's target-folder behavior, is an
   owner decision — §30 items are not resolved silently.
7. Behavior if the main app window moves to another display during recording.
8. Minimum supported macOS version.
9. Minimum supported Windows version.

The open items should be resolved before the corresponding behavior is considered complete.

---

## 31. Architectural decisions currently fixed

| Area | Decision |
|---|---|
| UI | Flutter |
| MVP OS | macOS + Windows |
| Linux | deferred, architecture-ready |
| Capture source | one display (default) or one selected window |
| Source selection UX | custom in-app source list |
| Cursor | included |
| Overlay controls | excluded from recording |
| Microphone default | ON |
| Camera default | OFF |
| System audio default | ON |
| Camera output | lower-right PiP in final video, the camera's own aspect ratio, 0.16 × canvas width |
| Audio output | system + mic mixed |
| Quality | 720p / 1080p |
| FPS | 30 / 60, default 30 |
| 120 FPS | future capability |
| Container | MP4 |
| Video codec | H.264 |
| Audio codec | AAC |
| Post-recording | Send / Delete / New recording |
| Delete confirmation | required only when never uploaded |
| Upload abstraction | common `UploadDestination` |
| MVP destinations | Telegram + WebDAV |
| Resumable upload | not supported; a broken transfer restarts |
| Destination selection | Settings |
| Delete after upload | only after confirmed success |

---

## 32. Research basis

Checked against current official documentation as of 2026-08-22:

- Flutter desktop support and plugins  
  https://docs.flutter.dev/platform-integration/desktop
- Flutter architecture recommendations  
  https://docs.flutter.dev/app-architecture/recommendations
- Flutter architecture guide  
  https://docs.flutter.dev/app-architecture/guide
- Flutter package/plugin development and FFI  
  https://docs.flutter.dev/packages-and-plugins/developing-packages
- Apple ScreenCaptureKit / SCContentFilter  
  https://developer.apple.com/documentation/screencapturekit/sccontentfilter
- Apple ScreenCaptureKit capture guide  
  https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos
- Windows.Graphics.Capture  
  https://learn.microsoft.com/en-us/windows/uwp/audio-video-camera/screen-capture
- Windows WASAPI loopback  
  https://learn.microsoft.com/en-us/windows/win32/coreaudio/loopback-recording
- Windows `WDA_EXCLUDEFROMCAPTURE`  
  https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setwindowdisplayaffinity
- Telegram Bot API  
  https://core.telegram.org/bots/api
- Google Drive resumable upload  
  https://developers.google.com/workspace/drive/api/guides/manage-uploads
- Google OAuth 2.0 for Desktop Apps  
  https://developers.google.com/identity/protocols/oauth2/native-app
- Google Drive API scopes  
  https://developers.google.com/workspace/drive/api/guides/api-specific-auth

---

## 33. Interactive capture controls (v0.5, in delivery)

**Status: Accepted 2026-08-30, delivering in stages.**

The specification for four changes requested on 2026-08-30, each decided by an
**Accepted** ADR of the same date. It stays here, whole, while it is being
built: each part is folded into §2, §4, §6, §7, §8, §10 and §31 **as it ships**,
so those numbered sections never describe behaviour that does not exist yet.
§33.10 says what has shipped.

One scope boundary was set explicitly by the product owner and is not a
technical limitation: **the capture source is chosen before recording only.**
Display and window selection stays where §4.1 puts it. The camera and the two
audio inputs are selectable before *and* during a session.

### 33.1 What this adds

| # | Change | ADR |
|---|---|---|
| 1 | The camera, the microphone and (where the platform allows) system audio are chosen from a list of real devices, before and during a recording; the microphone shows a live level meter, and every detail sits behind a disclosure that is closed by default | `docs/adr/2026-08-30-input-device-selection.md` |
| 2 | The control strip can be moved anywhere in the display's usable area, and remembers where | `docs/adr/2026-08-30-movable-control-strip-and-input-menus.md` |
| 3 | Each input control discloses its device list from a chevron, in an action sheet | same |
| 4 | The camera picture-in-picture is dragged into place, and sized by one of three presets — Camera, Square · small, Circle · small | `docs/adr/2026-08-30-user-adjustable-camera-pip.md` |
| 5 | The panel has a width range and the layouts answer to it, identically on both platforms | `docs/adr/2026-08-30-responsive-panel.md` |

Already delivered under this request, and **not** proposed — §4.1 now states it:
the source list shows only real windows, and capture thumbnails are shown in
their own colours instead of accent-washed.

### 33.2 Input devices

```text
MediaDevice { id, kind, label, isSystemDefault, isAvailable }
MediaDeviceKind = camera | microphone | systemAudio
```

| Requirement | |
|---|---|
| Enumeration | behind the platform interface, like `CaptureSource`; ids are opaque |
| Default | null device id — the platform's own default, which is today's behaviour |
| Change before recording | from the launch screen, per input |
| Change during recording | from the strip's action sheet (§33.4) |
| Effect of a change | the input is swapped on the live session; the output keeps one video track and one mixed audio track |
| Availability | `RecorderCapabilities.selectableDeviceKinds`; a kind absent from it is recorded but not chosen |
| Persistence | id **and** label in `AppSettings`; an id that no longer resolves falls back to the system default and the launch screen says so |
| Failure | degrades, never stops the recording — the rule in `docs/adr/2026-08-23-optional-inputs-degrade-instead-of-blocking.md` |
| Level meter | the **microphone** shows the selected device's live level, so the choice can be made by speaking. The meter is started *with the device it is to listen to* — a bar under a device row that showed the system default would answer a question nobody asked — and re-points when the choice changes. A metering value crosses the channel, never audio (§3); metering runs only while a meter is on screen. System audio is **not** metered — the user can act on neither the endpoint nor what the machine is playing |
| Disclosure | On / Off stays on the input's row; the device, the meter and the camera's presets sit behind a per-input disclosure, closed by default and remembered between launches |

### 33.3 The control strip moves

Amends §6's placement rule. The default placement is unchanged.

| Requirement | |
|---|---|
| Handle | everything inside the frame that a control did not take — the grip, the status dot, the clock, the dividers and the padding. The readouts are drawn, not pressed, so they never swallow a gesture aimed at the strip |
| Threshold | 4 px — under it the gesture is a click, and no control fires from a gesture that crossed it |
| Who runs the drag | the operating system. The strip asks once, and the platform's own window-drag loop tracks the pointer until mouse-up: a per-move message on a channel meant for commands is both slower and against §3 |
| Stored as | a fraction of the display's usable area, plus the display id |
| Clamped | to the usable area on every show, drag end and display change — so the menu bar, the notch and the taskbar stay uncovered |
| Snap | 24 px to a usable-area edge or the horizontal centre, applied after the drag ends |
| Second display | allowed; the strip belongs to the display holding its centre when the drag ends |
| Remembered | read when the session tears down and persisted then. A position the host cannot report leaves the stored one alone: failing to ask is not the user having dragged it back |
| Reset | automatic when the stored spot cannot be resolved |

**Keyboard and reset**, which stage D deferred, arrive with the menu:
`nudgeControlStrip` moves the strip by 8 px per arrow and 32 with Shift, then
clamps and snaps exactly as a drag end does, and `resetStripPosition` is a bare
command that drops the remembered spot and re-shows the strip at its default
dock. Both are answered by the host, so the strip's window never has to *keep*
key focus for them to take effect.

The arrow keys still have to be *received*, and only a focused window receives a
key. The strip's panel is non-activating, so it is focused after the user has
clicked it, not while the application being recorded is in front: the arrows are
a path for someone the drag does not serve, not a global hotkey. Claiming one
would be worse — a recorder that swallows the arrow keys of every application it
records is a bug, not an accessibility feature. `resetStripPosition` is raised
by a click and needs no focus at all.

### 33.4 Device menus on the strip

A chevron on the trailing edge of each selectable input opens an action sheet —
a labelled device list, the pattern a Zoom user already knows.

| Requirement | |
|---|---|
| Window | its own always-on-top panel, **not** part of the strip, because the strip keeps one size in every state (§6) |
| Exclusion | a third overlay kind, in the capture filter's exclusion list; §6's "must never appear in the captured video" applies in full |
| Placement | below the strip when there is room, above it otherwise; aligned to the chevron; clamped to the usable area |
| Focus | non-activating: opening it must not take key focus from the application being recorded |
| Contents | `System default`, then devices, current one checked, then `Off` — which is the existing toggle |
| Microphone sheet | carries the level meter for the selected device, under the list, **fed live** — the sheet renders in its own engine and holds no state, so a level that is not pushed to it is a bar that never moves |
| System-audio sheet | list only, no meter |
| Camera sheet | carries the three shape presets (§33.5) instead of a meter — the preview window already is one — plus `Reset position` once the tile has been dragged, and in **window mode** the four named corners |
| One at a time | a second chevron replaces the first sheet |
| Not selectable on this platform | no chevron; the control stays a plain toggle |
| Closed by the host | reported back to the application, as a selection carrying no device |

**A dismissal is reported, and this is not a detail.** The application draws the
chevron and is the only thing that knows which sheet is open; the host is the
only thing that sees the click outside that closes it. Left unreported, the two
disagree: the sheet is gone, the application still believes it is there, and the
next press on that chevron is read as the second press that closes it — the user
presses twice to reopen a sheet that is not on screen. The host therefore sends
`{kind, dismissed: true}` whenever *it* closed the sheet, and stays silent when
the sheet closed because the application asked it to.

### 33.5 The camera picture-in-picture

Amends §7, and one of `CLAUDE.md`'s core invariants. Position is dragged; size
and shape are presets. There are **no resize handles**.

| Preset | Shape | Width | Frame |
|---|---|---|---|
| **Camera** — default | the camera's own aspect ratio | the camera's own width mapped onto the canvas, capped at `0.16 × canvas width`, floored at `0.08` | whole, never cropped |
| **Square · small** | 1:1 | `0.10 × canvas width` | centre-cropped |
| **Circle · small** | 1:1, masked to a circle | `0.10 × canvas width` | centre-cropped |

| Rule | |
|---|---|
| Position | free, as a fraction of the canvas; clamped to the `0.01 × canvas width` margin; snaps to a corner within 2% of the canvas width |
| Dragged from | the live preview in display mode, where the preview **is** the tile (design `1p`); in window mode it is not (design `1e`), so position there is one of the four corners, chosen in the camera sheet the strip's chevron opens |
| Choosing a corner | clears any stored free position — the two are alternative answers to one question, and a stored fraction would silently win over the corner just chosen |
| A preset or a corner | leaves the sheet open. The tile changes under it, and comparing three shapes or four corners must not cost a reopen each time |
| Applied | between frames, for the next frame; the encoder canvas never changes, so the file keeps one continuous video track |
| Persisted | when the session ends normally, so a mid-session experiment does not survive a crash |

**The no-crop invariant changes, deliberately.** §7 and `CLAUDE.md` currently
say the camera frame is never cropped and never distorted. A 16:9 sensor cannot
fill a square or a circle without cropping, and letterboxing inside them would
leave a tile that is partly desktop. The rule becomes:

> The camera frame is **never distorted**, and is cropped **only** by an explicit
> shape preset — identically in the preview and in the file.

The default still never crops, and no crop happens that the user did not ask for
by name. The preview shows the same crop as the output, so `1p`'s promise holds.

### 33.6 A panel that answers to its width

Amends the design's fixed-panel note, for the panel only.

| Content width | Layout | Panel width |
|---|---|---|
| `< 560` | the reference layout, exactly as drawn — this stays the minimum | `< 588` |
| `560 – 767` | source grid at three columns | `588 – 795` |
| `≥ 768` | source grid at four columns; control rows may pair where the design has room | `≥ 796` |

**The width is the one the layout is given, not the window's.** A component that
read the window would stop being the same object wherever it is placed, and
would need to know what padding happened to sit around it. The panel's own
padding is `AppSpacing.panelPadding` on each side — 28 in total — which is the
whole of the difference between the two columns above, and is why the panel
flips a column 28 points later than the breakpoint's number.

Maximum 960. No horizontal scrolling at any width. Tokens do not scale — the
grid changes, the objects on it do not. Both platforms open at the same
preferred size and enforce the same limits; `windows/runner/main.cpp` currently
opens the Flutter template's 1280 × 720 and must not.

### 33.7 Corner cases

The list is the specification, not a reminder. An unanswered row is an
unimplemented requirement.

#### Moving the strip

| Case | Required behaviour |
|---|---|
| Slow click on a control | stays a click — a control is in front of the handle and takes the press itself, so a gesture that reaches the handle was never going to press anything |
| Press on the clock or the status dot | drags. They are readouts, not targets |
| Drag ends off the usable area | clamped back inside it |
| Drag while stopping or finalizing | the window still moves; the controls stay disabled |
| Drag with a sheet open | the sheet closes |
| Display holding the strip is disconnected | the strip moves to the current display, at its stored fraction there, or the default |
| Resolution or scale factor changes | the fraction is re-resolved; the strip stays proportionally where it was |
| Dock or taskbar shown, hidden or moved | the usable area changed — re-clamp |
| macOS notch / menu bar | unreachable by construction: clamping is against `visibleFrame` |
| Windows per-monitor DPI, taskbar on any edge | the fraction is stored per display; placement re-resolves on the target monitor's `rcWork`. **Partly met:** a drag *across* a scale boundary does not re-scale the hosted engine — `docs/development/compatibility-matrix.md` says why it is open rather than half-fixed |
| macOS full-screen Space | the panel joins the active Space, or it vanishes when the recorded app goes full screen |
| Display sleeps or the screen locks | the strip hides with the display and returns unmoved |
| Strip overlaps the camera preview | cosmetic only — both are excluded from capture; the strip draws above |
| Next session | the strip returns where the user left it |
| Stored display no longer exists | default anchor, and the stale entry is dropped |

#### Device menus and swapping

| Case | Required behaviour |
|---|---|
| Recording stops with a sheet open | the sheet closes with the session |
| Selected device unplugged while its sheet is open | the list re-renders, the fallback is shown selected, the sheet stays open |
| Selected device unplugged with no sheet open | fall back to the system default; if there is none, that input turns off and the strip shows it off |
| No device of that kind at all | `No microphone found` — never an empty panel |
| Permission for that kind not granted | the list shows what the platform reports; choosing prompts; a refusal degrades the session, it does not block it |
| Sheet would extend past the usable area | flips to the other side of the strip, then clamps |
| Click outside the sheet | closes the sheet, and the click **is** forwarded — see below |
| Two chevrons in quick succession | one sheet; the second replaces the first |
| Swap requested while a swap is in flight | dropped, not queued — §6's one-command-at-a-time rule |
| Swap to a device that will not open | the previous device keeps running; a non-fatal error is shown |
| Swap to the device already selected | no-op; no gap in the audio |
| Repeated microphone swaps in a long session | audio stays in sync with video — §24 soak case |

**The click outside is deliberately not swallowed**, reversing this row's
earlier requirement. Consuming it needs an invisible window spanning the whole
display for as long as a sheet is open — a click-eating surface laid over the
very application being recorded, where a swallowed click is indistinguishable
from the recorder having frozen. A menu closing *and* the click landing is the
lesser surprise, and it is what both hosts implement: macOS observes with a
non-consuming `NSEvent` monitor, Windows with the equivalent. If this is ever
revisited, it needs a new decision, not a quiet change.

#### The level meter

| Case | Required behaviour |
|---|---|
| Selection changes | the meter follows the newly selected device immediately |
| The meter is in an overlay window | every sample is pushed to it, deduplicated against the last one pushed and never two pushes at once. A snapshot is the only thing that reaches another engine; rebuilding the application's own widget tree reaches nothing there |
| Permission not granted | the bar is drawn dead and says why; the session may still start, with a silent track |
| Device busy or held exclusively by another application | the meter says so rather than reading zero |
| Flat for 3 s on an enabled input | reported as a finding — "nothing has reached this microphone" — not left as a blank control |
| Input muted | the bar is drawn dead, not hidden: "off" and "broken" must not look alike |
| Meter leaves the screen, or its disclosure is closed | metering stops; no device stays open to animate a bar nobody is looking at |
| System audio | never metered, on either platform |
| During recording | levels come from the live mixer; a device already in use is never opened a second time |
| Clipping | the top of the scale is marked distinctly, so a level that is too hot is visible as such |

#### Camera picture-in-picture

| Case | Required behaviour |
|---|---|
| Drag past a canvas edge | clamped to the margin |
| Preset changed mid-drag | the drag ends at the tile's current position; the new preset's size is applied around it, then re-clamped |
| Corner chosen while a free position is stored | the corner wins and the position is cleared, so the tile does not stay where it was dragged |
| Corner offered with a display source | never — the tile is dragged there, and a corner list would be a second, worse answer to a question already answered better |
| Camera swapped for one with a different shape, on the `Camera` preset | the tile keeps its top-left and width; the height changes; the position is re-clamped if that pushes it out |
| Camera swapped, on `Square` or `Circle` | nothing moves — the tile is 1:1 whatever the sensor is; only what the centre crop contains changes |
| A camera narrower than the crop needs | the crop takes the full width and the full height it can; it is never upscaled past the sensor's own pixels |
| Camera turned off mid-drag | the drag ends; the preset and position are kept for when the camera returns |
| Adjusted while paused | allowed; applies to frames after resume |
| Source window resized mid-session | ratios are relative to the canvas, so the tile follows whatever §30.3 resolves — **this scope does not resolve §30.3** |
| Crash mid-session | neither the position nor the preset is persisted; the next session starts from the previous default |
| Preview and output disagree about the crop | a defect, not a tolerance: design `1p` promises they are the same object |
| Anything drawn in the preview window that the compositor does not draw | the same defect. In display mode the window paints the camera and nothing else — no frame, no registration marks, no ground, and no background around the tile. A border on screen that is absent from the file is a disagreement about the object, not a decoration |
| The tile's own window is opaque | it must not be. The compositor leaves every pixel outside the tile untouched, so an opaque window puts a square on the user's screen around a circular tile |

#### Responsive panel

| Case | Required behaviour |
|---|---|
| Disclosure open when the window is resized | it stays open and its content reflows; the state is per input, not per width |
| Disclosure state | remembered between launches, per input; a disclosure whose input has no details on this platform is not drawn |
| Window resized while the source picker is open | the grid re-columns; selection and scroll position survive |
| Window dragged between monitors of different DPI | the layout re-measures at the new scale |
| Very tall window | the list grows; the footer stays pinned |
| Any width | no horizontal scrolling |

### 33.8 Platform differences this scope creates

| | macOS | Windows |
|---|---|---|
| Camera device choice | yes | yes |
| Microphone device choice | yes | yes |
| System-audio device choice | **no** — ScreenCaptureKit delivers the system mix, there is no endpoint to choose | yes — WASAPI loopback is per render endpoint |

Expressed as `RecorderCapabilities.selectableDeviceKinds`, never as an
operating-system name (§28), and recorded in
`docs/development/compatibility-matrix.md` on acceptance.

### 33.9 What must be tested

| Level | Coverage |
|---|---|
| Pure/unit | the capturable-window rule (**done**); strip drag, snap and clamp arithmetic; preset resolution and picture-in-picture geometry at every canvas size, both bounds and all three presets |
| Widget | the disclosure — closed by default, opens, persists; the action sheet's states — loading, empty, selected, device lost, no permission, silent; the meter's dead and clipping states; the strip's click-versus-drag threshold; every reflowing screen at all three widths |
| Plugin | device enumeration and `selectInputDevice` payloads, on both platforms or neither |
| Integration | the third overlay is absent from a recording made from a **display** source; a device swapped mid-recording produces one continuous file; each camera preset lands in the file at the geometry the preview drew |
| Soak (§24) | repeated microphone swaps during a long recording, verified for A/V sync at the end |

### 33.10 Suggested delivery order

Each stage is shippable on its own and none of them requires the next.

| Stage | Contents | State |
|---|---|---|
| A | Real windows only; thumbnails in their own colours | **shipped** — §4.1 |
| B | Responsive panel; Windows opens at the right size | **shipped** — §33.6 |
| C | Device enumeration and selection *before* recording, behind a disclosure, with the microphone's level meter | **shipped** — §33.2, §33.4 (launch screen only) |
| D | The strip moves, and remembers where it was left | **shipped** — §33.3 |
| E | Device menus on the strip, live swapping mid-recording, keyboard movement and `Reset position` | **shipped** — §33.4 |
| F | The camera picture-in-picture is dragged, and sized by preset | **shipped** — §33.5 |

Every stage is now written on both platforms. **None of the Windows half has
been compiled**, on this host or anywhere: see
`docs/development/compatibility-matrix.md`, which also records that CI's Windows
unit-test job has been failing since before this scope began. §33 stays here,
whole, until that is green — the numbered sections it amends are updated as each
stage lands, and §33.11 says which.

### 33.11 Folding this section away

Each stage folds into the numbered sections as it ships, and §33 is deleted once
the last one has:

| When this ships | Fold into |
|---|---|
| C (device selection) — **done**, fold pending stage E | §8 and §20 |
| D and E (the strip) | §6 |
| F (the picture-in-picture) | §7, §2's deferred list, and the no-crop invariant in §7 **and in `CLAUDE.md`** — see §33.5 |
| B (the panel) — **done**, fold pending | the design notes and §29 |

`docs/architecture/platform-channel-contract.md` is updated with each stage that
changes the wire, not at the end. `docs/development/compatibility-matrix.md`
records what is verified per platform as each stage lands.
