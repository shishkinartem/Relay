# Compatibility matrix

"Supported" means built **and** the basic flow exercised, not merely compilable
(`code-quality.md`). Anything not verified says so.

| Platform | Minimum version | Display capture | Window capture | System audio | Microphone | Camera | Cursor | 30 FPS | 60 FPS |
|---|---|---|---|---|---|---|---|---|---|
| macOS | 13.5 *(provisional, §30.8)* | built + run | built + run | built | built | built | built | built | built |
| Windows | 10 build 19041 *(provisional, §30.9)* | not built | not built | not built | not built | not built | not built | not built | not built |
| Linux | — | deferred (§2) | deferred | deferred | deferred | deferred | deferred | deferred | deferred |

## What "built + run" covers on macOS

Verified on macOS 26.5.2 (arm64) with Flutter 3.47.1:

- the application builds, launches and registers `RecorderMacos`;
- source enumeration returns displays before windows, with still thumbnails;
- the three overlay windows are created and **report** ids from
  `excludedWindowIds` — which is all `integration_test/macos_recording_test.dart`
  asserts, and the claim it used to be given credit for was stronger than that.
  It checks `excludedWindowIds().length >= 2`; it never checks that those ids
  reached an `SCContentFilter`. That mattered: until 2026-08-30 the filter's
  exclusion list was empty in **every** session, because `prepare` builds the
  filter before any overlay is ordered front and a panel that is not on screen
  is absent from `SCShareableContent`. Only `sharingType = .none` was keeping
  the overlays out of the file, and the test was green throughout. The filter is
  now rebuilt whenever an overlay appears (`refreshCaptureExclusions`), and the
  assertion is still the weak one — strengthening it needs a check that the
  recorded frames contain no overlay pixels, which is a real capture on a real
  host;
- the permission preflight reports and requests correctly.

`integration_test/macos_recording_test.dart` additionally records a real
display source, pauses, resumes, stops and asserts the produced MP4.

**Two gates skip it, in this order.** First the `platform` tag, which
`dart_test.yaml` configures to skip — so a run without `--run-skipped` executes
nothing and still exits 0:

```bash
flutter test integration_test -d macos --run-skipped
```

Only then does the second gate apply: the recording test skips when
`canRecordScreen` is false, and it reports that skip rather than passing silently.
If you have granted screen recording and still see zero tests, it is the first gate,
not a permission problem.

## Input devices (§33.2)

What each platform reports in `selectableDeviceKinds` / `meterableDeviceKinds`.
The UI reads those capabilities, never the platform name.

| Platform | Camera choice | Microphone choice | System-audio choice | Metering |
|---|---|---|---|---|
| macOS | selectable | selectable | **none** — ScreenCaptureKit delivers the system mix, so there is no endpoint to pick | microphone only |
| Windows *(not built)* | selectable | selectable | selectable — WASAPI loopback is per render endpoint | microphone only |
| Linux | deferred (§2) | deferred | deferred | deferred |

Only the microphone is meterable on either platform. System audio carries no
level on purpose: a level is worth showing where the user can act on it, and
they can change neither the macOS endpoint nor what the machine is playing from
inside this application.

The Dart half of the contract is unit-tested by
`packages/recorder_platform_interface/test/contract_test.dart`, group
*input devices (§33.2)*. The table above is what each platform is contracted to
report (§33.8), not a measurement: live enumeration against attached hardware
was not exercised while it was written, and the Windows half has been neither
compiled nor run on this host — see *Not verified*.

### Where the two halves actually diverge

Read off the sources on 2026-08-30, not intended behaviour. Anything here that
disagrees with `../architecture/platform-channel-contract.md` is a gap in a
platform, not a second reading of the contract.

| Behaviour | macOS | Windows |
|---|---|---|
| `startInputMetering`'s `deviceId` | **ignored.** `InputMeter.openTap()` opens `InputDeviceEnumerator.defaultDevice(kind: .microphone)` whatever id arrived | **ignored.** `OpenDefaultCaptureMeter()` takes the default `eCapture` endpoint whatever id arrived |
| `getInputDevices` with an absent or unrecognised `kind` | `[]` — `MediaDeviceKind(name:)` yields nil and the plugin answers with an empty list | **rejects** with `unknown` ("An input device kind is required.") |
| `getInputDevices` under load | always answers; no queue between the call and AVFoundation | **rejects** with `unknown` ("busy with an earlier request") once the 16-deep serial COM worker is full |
| `start`/`stopInputMetering` with an absent or unrecognised `kind` | silent no-op | **rejects** with `unknown`, before the meter is reached |
| `isAvailable` on a media-device map | **computed**: `isConnected && !isSuspended && !isInUseByAnotherApplication` | **constant `true`** for every row. Only `DEVICE_STATE_ACTIVE` endpoints are enumerated at all, and openability is never probed — so §33.7's "device busy or held exclusively by another application: the meter says so rather than reading zero" cannot be satisfied from this field on Windows |
| `isSystemDefault` | the device `AVCaptureDevice.default(for:)` would return | audio: the endpoint `GetDefaultAudioEndpoint(…, eConsole)` names. Cameras: **index 0**, because Media Foundation names no default and the recorder opens the first source |
| Metering across `pause` | keeps reporting; `pause()` touches the clock and the state only | keeps reporting; packets are metered and simply not written |

### What `devicesChanged` actually watches

| Aspect | macOS | Windows |
|---|---|---|
| Registered | at plugin registration, always | on the **first `getInputDevices`** — nothing is watched until Dart enumerates once |
| Source | `AVCaptureDevice.wasConnected` / `wasDisconnected` | `IMMNotificationClient` on the endpoint enumerator |
| Cameras connecting / disconnecting | reported | **missed.** Audio endpoints only; a webcam plugged in mid-run needs a `WM_DEVICECHANGE` registration this plugin does not make |
| Microphones connecting / disconnecting | reported | reported (`OnDeviceAdded` / `OnDeviceRemoved`) |
| A device changing state without being unplugged | **not watched** — the two AVFoundation notifications are the whole registration | reported (`OnDeviceStateChanged`) |
| The system default changing with nothing replugged | **missed.** There is no CoreAudio default-device listener anywhere in the macOS sources, so switching the default microphone in System Settings emits nothing | reported (`OnDefaultDeviceChanged`) |
| A device renamed | not watched | deliberately ignored — a renamed device is the same device |
| `kind` on the event | named when the device carries exactly one media type; omitted for a capture card, which means "re-read everything" | **never named** — always the bare "re-read everything" form |
| The standalone meter's tap after a default change | re-points, but only off a connect/disconnect: `deviceListChanged()` compares the tap's device against the current default and re-opens. A default switched in System Settings with nothing replugged never reaches it | **keeps the endpoint it opened.** Nothing tells `InputMeter` to re-read; the tap re-opens only once `GetPeakValue` starts failing |

Neither platform's `devicesChanged` is exercised by an automated test: macOS's
observers need real hardware to arrive or leave, and the Windows half has not
been compiled.

## Provisional minimum versions

Both minimums are **open questions in the specification** (§30.8, §30.9) and are
recorded here as build settings, not as resolved decisions.

macOS 13.5 is the floor. 13.0 is what this application's own APIs need, but
Flutter 3.47's `flutter_additional_macos_build_settings` builds every plugin
pod at a 13.5 deployment target, so a Runner declaring 13.0 fails to link
against them — the error surfaces the moment `GeneratedPluginRegistrant.swift`
is recompiled, which is also why an Xcode build failed while an incremental
`flutter build` appeared to succeed. The application's own requirement is:

| API | Needed for | Available from |
|---|---|---|
| `SCStream`, `SCContentFilter` | display and window capture | 12.3 |
| `SCStreamConfiguration.capturesAudio` | system audio (§8) | 13.0 |
| `SCScreenshotManager` | source thumbnails | 14.0 — falls back to `CGDisplayCreateImage` / `CGWindowListCreateImage` on 13 |
| `SCStreamConfiguration.captureMicrophone` | not used — microphone comes from AVFoundation, which works on 13 | 15.0 |

Windows 10 build 19041 is what `Windows.Graphics.Capture` with
`IsCursorCaptureEnabled` requires. Nothing on Windows has been compiled.

## Native unit tests

The pure half of each platform — the wire contract, the picture-in-picture
geometry, the canvas arithmetic and the session clock — is now separated from
the Flutter- and OS-bound half so it can be executed on its own.

| Platform | Where | How to run | State |
|---|---|---|---|
| macOS | `packages/recorder_macos/macos/recorder_macos/core` | `swift test` | green — **run the command for the count**, do not quote one from here. It has been hand-copied to three files and drifted three ways |
| Windows | `packages/recorder_windows/windows/test` | `cmake -S … -B build/win-tests && ctest --test-dir build/win-tests` | **never compiled on this host** — `cmake`, `ctest` and `cl` are all absent. CI *does* configure and build it under MSVC; what fails there is `ctest`, which is the row below |

Both suites assert the same properties on purpose. The two platforms hand-write
the same wire spellings and re-implement the same geometry, and nothing in the
Dart layer can observe them disagreeing — mirroring the assertions is the only
thing that catches drift. It already has: `ResolvePipRect` and
`CameraOverlayConfiguration.effectiveAspectRatio` handled a malformed aspect
ratio differently (a square tile against a 0.0001-ratio sliver) and were aligned
on the default 16:9.

## Not verified

```text
NOT RUN: Windows native build (packages/recorder_windows/windows/CMakeLists.txt)
Reason: no MSVC toolchain, no Windows SDK and no cmake on the development host (macOS).
That is no longer the whole reason. `.github/workflows/ci.yml` already carries the two
jobs that would compile all of this on a real Windows host — `native-windows` runs the
cmake/ctest suite and `build-windows` runs `flutter build windows`, both on
`windows-2022`. Neither has ever seen this work: checked 2026-08-30, the branch carrying
it has never been pushed and the commit is not on `main`, so no CI run exists for it.
The compile half is therefore a push away rather than a hardware problem. The DPI
question under *The movable control strip* is the part that genuinely still needs a
physical two-monitor machine, which CI's single virtual display cannot provide.

RED IN CI: Windows native unit tests (packages/recorder_windows/windows/test)
Reason: not the development host's gap. CI's `native-windows` job configures and
builds this suite successfully under MSVC on windows-2022 — so it is compiled,
just not here — and then `ctest` fails. It has failed on all five CI runs to
date, including HEAD `fe023e7`. The job is not `continue-on-error` and the
workflow is not path-filtered: the red was visible all along and was read as the
known "Windows is written but not built" gap rather than as a real failure.

One cause is identified and fixed: `SessionClock.PausedIntervalsAreSubtracted`
asserted 5 s where `capture - start - paused_total` gives 6 s (10 s of wall time,
4 s of it paused). The expectation was wrong, not the clock — §9 and every
sibling case in the suite subtract the pause, as does the macOS SessionClock.
Reproduced on macOS 2026-08-30 by extracting `SessionClock` verbatim from
recorder_types.{h,cpp} into a standalone TU; the other eleven SessionClock cases
pass before and after. Whether it was the *only* failure is unknown from here,
and the suite has since grown the strip-geometry and device cases, which have
never been compiled at all. The next CI run is the verdict.

NOT RUN: fragmented MP4 output on Windows
Reason: same. docs/adr/2026-08-23-fragmented-mp4-on-both-platforms.md changes
the sink writer's container type so an aborted `.part` is recoverable; it must
be compiled and a mid-session abort confirmed recoverable before release.

NOT RUN: Windows native input-device enumeration and metering (§33.2)
Reason: same. input_devices.cpp/.h and the plugin arms that call them have never
been through a compiler on this host, so the endpoint enumeration, the camera
enumeration through Media Foundation, the default-first ordering, the
reference-counted meter, the IMMNotificationClient watcher and every divergence
listed under *Where the two halves actually diverge* are read off the source and
not measured. windows/test/recorder_types_test.cpp covers the pure half only, and
it has not been compiled here — run it with
`ctest --test-dir build/win-tests -C Debug --output-on-failure` on a Windows host.
The count is deliberately not quoted: it has been hand-copied into three files
before and drifted three ways.

NOT RUN: Windows debugResourceCensus (spec 19.1)
Reason: same — never compiled. `RecordingSession::DebugCensus()`,
`OverlayWindows::DebugCensus()`, `InputMeter::DebugCensus()`, the `ResourceCensus`
struct in recorder_types.{h,cpp} and the plugin's `debugResourceCensus` arm are all
read off the source and not measured. The `ResourceCensus` and
`MeteringSubscriptions::Total` cases added to windows/test/recorder_types_test.cpp
cover the arithmetic and the released-rows rule; like the rest of that suite they
have not been compiled here.

NOT RUN: what a census actually proves on either platform
Reason: the two tests spec 19.1 names run at the view-model level against
`FakeHostResources` (test/features/recorder/application/resource_census_test.dart).
They prove the *application* drives a host that obeys 19.1 back to where it
started — every `releaseSession` sent, every meter stopped, every overlay hidden,
on every exit including a fatal error and a quit. They cannot prove that
ScreenCaptureKit, AVFoundation or WASAPI let go of anything, because no Dart test
can see a native object graph, and neither native suite can reach the code that
counts it: `RecorderMacosPlugin`, `OverlayWindowController` and `InputMeter` all
need FlutterMacOS and AVFoundation and sit outside `RecorderCore` — the same
asymmetry `packages/CLAUDE.md` records for `LetterboxRect`. Closing this needs a
real integration run that calls `debugResourceCensus` across ten start → stop
cycles on each platform.

NOT RUN: Windows stop/abort teardown ordering
Reason: same. `RecordingSession::teardown_mutex_` now spans the MediaWriter call as well
as the thread joins, and the plugin's `abort` and `dispose` queue their teardown on the
serial worker, so an abort can no longer overtake an in-flight `Finalize()` and strand a
finished recording as a `.part` (spec 18). Verified by reading only — the race needs a
Windows host to reproduce: start a long recording, press Stop, then close the window
while it is finalizing, and confirm `recording-<id>.mp4` exists and no `.part` is left.

NOT RUN: Windows integration tests
Reason: same.

NOT RUN: integration_test/ in CI
Reason: `flutter test integration_test -d macos --run-skipped` does not terminate. Measured
2026-08-25: 1h35m on a macos-15 runner with no output, killed only by the next push, and
the same hang locally on a host that does hold the screen-recording grant. Without
--run-skipped the `platform` tag skips everything and the job passes having run nothing.
The suite is therefore run by hand and watched. The hang itself is undiagnosed.

NOT RUN: §24 soak tests (60 min 1080p30, 60 min 1080p60, disk-full, network loss)
Reason: each run exceeds an interactive session; they are release gates, not per-change gates.

NOT RUN: tool/package-dmg.sh notarization path
Reason: no Developer ID certificate on this host.
```

## What a session ends holding (§19.1)

The census is the falsifiable half of §19.1. Both hosts answer
`debugResourceCensus`; the two lifetimes it reports differ, and **both are
lawful** — §19.1's second table permits either, and the difference is recorded
here rather than papered over on the wire.

| | macOS | Windows |
|---|---|---|
| Overlay engines | built on first use, kept for the life of the process. Census settles at 3 and stays there | destroyed with each window on hide. Census returns to 0 |
| Preview texture | registered on show, **unregistered on hide** — a registered texture keeps its last uploaded contents, so re-showing drew the previous session's last camera frame until the new camera delivered | belongs to the window, so it goes with it |
| Event monitors | drag-end and menu-dismissal `NSEvent` monitors, plus the rolling left-button watch | low-level mouse and keyboard hooks, installed for exactly as long as a menu is open |
| Session rows | read from `RecordingSession` through a lock-guarded ledger; the camera and microphone are asked directly (`isConfigured`) | read from each owner's own predicate — `CaptureEngine::is_running`, `MediaWriter::is_open`, `VideoCompositor::is_initialized` |
| Verified | `swift test` covers the arithmetic and the ledger; the plugin's three contributors are covered only through Dart against a fake | **nothing** — never compiled |

Because the counts differ, §19.1's equality census is taken **after the first
cycle, not at launch**: a launch census on macOS is short by three engines that
the first session creates and every later one reuses. A launch census still
bounds every row of §19.1's *first* table, which must be zero on both platforms
in both places, and `resource_census_test.dart` asserts that separately.

## The movable control strip (§33.3)

| | macOS | Windows |
|---|---|---|
| Drag | `NSWindow.performDrag(with:)` from `beginMove` | `ReleaseCapture()` + `WM_NCLBUTTONDOWN`/`HTCAPTION` |
| Usable area | `NSScreen.visibleFrame` | `MONITORINFO.rcWork` |
| Re-clamp on a display change | `didChangeScreenParametersNotification` | `WM_DISPLAYCHANGE` and `WM_SETTINGCHANGE`/`SPI_SETWORKAREA` |
| Display id in a stored position | `CGDirectDisplayID` | `HMONITOR` |
| Scale change while dragging across monitors | one scale per display, resolved on show | **gap** — see below |
| Verified | `swift test` and a `flutter build macos --debug` | **nothing** — never compiled or run on this host |

Neither `displayId` is stable across a reboot or a change of display topology,
so a remembered position can resolve on a different physical display than the
one the strip was left on. The fraction still resolves against a real usable
area and is still clamped, so the strip is always reachable; one drag corrects
it. Stated in `../architecture/platform-channel-contract.md` → *strip-position
map*, and deliberately not fixed with a second id spelling.

**The Windows DPI gap, and why it is still open.** Dragging the strip from a
100% monitor to a 200% one does not re-scale the hosted overlay engine.
`WM_DPICHANGED` reaches top-level windows, but the Flutter view is a child HWND
parented in with `SetParent`, and moving the host window does nothing about
scale — so the strip renders at half size on the second monitor, and the next
content measurement can then scale stale logical points by the new monitor's
factor and double the *window* around content still drawn at the old one.

It is unfixed rather than half-fixed because the two plausible engine behaviours
want opposite remedies, and neither can be told apart without a Windows host:
if the embedder re-scales itself under the process's `PerMonitorV2` manifest,
the fix is to re-apply the frame at `last measured logical size × new scale`;
if it does not, that same resize makes it strictly worse. Whoever has a Windows
machine should drag the strip across a scale boundary, log the view's device
pixel ratio and the host window's DPI on each side, and only then choose.

Two halves of that question are already settled by reading the sources, and do
not need the machine (checked 2026-08-30):

- the process really is `PerMonitorV2`. `windows/runner/runner.exe.manifest`
  declares it, so Windows does notify the whole window tree and the host window
  does receive `WM_DPICHANGED`.
- the host already hands that message to the engine. `OverlayWindow::HandleMessage`
  forwards **every** message to `controller_->HandleTopLevelWindowProc` before its
  own switch, `WM_DPICHANGED` included, so "forward the DPI change to the view
  controller" is not the missing piece of the second remedy — only the forced
  re-measure after it would be.

What is still unknown, and is exactly what the two-monitor run has to answer, is
whether the Flutter embedder acts on that message for a view parented in with
`SetParent` — that is, whether the view's device pixel ratio actually changes.
Nothing in the sources decides it.

**Keyboard movement and `Reset position` exist on the wire and nowhere else.**
`OverlayCommand.resetStripPosition` and the eight nudge commands are declared,
both hosts answer them, and the application dispatches each into the one
`nudgeControlStrip(dx, dy)` call that clamps and snaps exactly as the end of a
drag does. **Nothing sends any of them.** There is no strip menu, no key binding
and no button: the whole path from a user's finger to `resetStripPosition` is
missing, and the same is true of every arrow.

This entry previously read "now exist", which was wrong in the way that matters
— a reader checking whether the accessibility path was covered would have
concluded it was. §33.3 and
`../adr/2026-08-30-movable-control-strip-and-input-menus.md` carry the same
correction; `../adr/README.md` already said it.

| | State |
|---|---|
| `OverlayCommand.resetStripPosition` / `nudgeUp…` etc. | declared |
| macOS host handler | implemented |
| Windows host handler | written, never compiled |
| Dart dispatch to `nudgeControlStrip` | implemented, tested |
| Anything that raises them | **missing** |

When it is built, the arrow keys carry a real limit that is stated in §33.3
rather than hidden: a key is only delivered to a focused window, and the strip's
panel is non-activating, so the arrows will work after the user has clicked the
strip — not while the recorded application is in front. Claiming a global hotkey
would be worse than the limit: a recorder that swallows the arrow keys of every
application it records is a bug. `Reset position` is raised by a click and needs
no focus at all, so it is the half that could ship on its own.

## Overlay window transparency

The display-mode camera preview is the composited picture-in-picture, so its
window has to be transparent everywhere the tile is not. Three things must all
hold, and only the first two are testable here:

| | Where | Covered by |
|---|---|---|
| The Dart tree paints no ground | `RelayTheme(ground: null)` in `camera_preview_window.dart` | `test/features/recorder/presentation/camera_preview_window_test.dart` |
| The tile fills its box in every preset | `camera_preview_surface.dart` | `test/design_system/design_system_test.dart` — mounted inside a `Stack` on purpose, because a loose parent is what collapsed it |
| The hosted Flutter view is not opaque | `controller.backgroundColor = .clear` in `OverlayWindows.makePanel` | **nothing.** `makePanel` is private and AppKit-bound, and the only Swift suite that runs is the pure `RecorderCore` package |

A `FlutterView` defaults to opaque black, so the third is what decides whether a
transparent Dart tree shows the desktop or a black square. It is confirmed by
eye on macOS only. Windows is a different mechanism entirely — its overlay
windows are deliberately **not** `WS_EX_LAYERED` (`overlay_windows.cpp`, with a
comment explaining that a layered window breaks the hosted child-HWND ANGLE
surface), and the circular tile is masked with `SetWindowRgn` instead, so the
corners are outside the window rather than transparent within it. That has never
been run.

## The overlay panels and the raster thread

A crash on 2026-08-30 (`EXC_BAD_ACCESS` at `0x0` in
`impeller::Canvas::SetupRenderPass`, on an overlay engine's raster thread,
during a recording) traced to an engine defect — flutter/flutter#185394, open,
no fix. `FlutterBackBufferCache` purges only on a head-size disagreement, so a
panel driven **A → B → A** can be handed a surface of the other size;
`TextureMTL::Wrapper` returns a non-null but invalid texture, `SetColorAttachment`
silently drops it, and the canvas reads a null texture.

The application's part is to never drive a panel back to a size it recently
left. `docs/adr/2026-08-24-overlay-panels-are-sized-once-per-show.md` established
that for the control strip; the input menu opted out of it, opening at an
estimate and being corrected to its measurement on every show. It now remembers
a measured size per content shape, so only the first sheet of a shape is ever
corrected.

| | Covered by |
|---|---|
| the shape key changes with every section that changes the height | `swift test` — `OverlayPlacementGeometryTests` |
| a remembered shape needs no resize | `swift test`, same file |
| the host's estimate matches what the sheet measures | `flutter test test/features/recorder/presentation/input_menu_size_test.dart` — it fails when a section is added to the sheet without a term in the estimate |
| the panel is actually driven through one size | **nothing** |

The last row cannot be closed here. `swift test` links `RecorderCore` against
Foundation only; it cannot open an `NSPanel`, host a `FlutterViewController` or
reach the engine's surface cache. `flutter build macos` compiles and does not
run. The AppKit half of these windows — `place`, `move`, `performDrag`, the
mouse-up watch, the back-buffer cache — has no automated coverage on this
machine and should not be claimed to have any.

Two related facts, both verified by disassembly on macOS 26.6.2 and worth
keeping because they are not documented anywhere else:

- **`NSWindow.performDrag(with:)` does not block.** It posts one send-only mach
  message to the window server and returns; the drag runs server-side and the
  application learns it ended through a local event monitor. Code that settled
  "after" it was settling at the *start* of the drag.
- **Flutter's platform-task run-loop source is registered in
  `kCFRunLoopCommonModes`**, and `NSEventTrackingRunLoopMode` is a common mode —
  so event tracking does *not* starve the engines. The one mode that does is
  `_NSMoveTimerRunLoopMode`, which this application never enters.

## Known gaps

- **Windows is written but not built.** No MSVC toolchain on the development
  host, and — the half that is actually actionable — the branch carrying the
  work has never been pushed, so CI's `native-windows` and `build-windows` jobs
  have never seen it. See *Not verified* above.
- ~~**`deviceId` on `startInputMetering` is not honoured by either platform.**~~
  **Closed.** Both hosts now take the id from the call — macOS at
  `RecorderMacosPlugin.startInputMetering` → `meter.start(kind:deviceId:)`,
  Windows at `meter_.Start(kind, StringAt(*arguments, "deviceId"))` — and a
  start naming a different device re-points the tap instead of opening a second
  one. Read off the source on both sides; measured on neither, because the
  Windows half has still never been compiled here and the macOS half needs a
  second microphone to tell the two taps apart.
- **`getInputDevices` can fail on Windows**, where the contract says it always
  answers: an absent or unrecognised `kind` and a full COM worker queue are both
  rejections there and empty lists (or impossible) on macOS.
- **Open specification decisions** are implemented conservatively and marked in
  code rather than silently resolved: §30.3 (non-16:9 sources), §30.4 (pause
  timeline — implemented as "paused time is excluded", the recommendation),
  §30.7 (main window changing display mid-recording), §30.8 / §30.9 (minimum OS
  versions).
- **Design gaps** the canvas does not cover — `preparing`, `stopping`,
  `finalizing`, `deleting` and the fatal capture errors — are built from
  existing components only, and marked `design gap:` in the source.
- **Soak tests (§24)** have not been run.
- **No licence file yet.** Without one the default is "all rights reserved", which
  blocks reuse — add one before making the repository public if that is not intended.

## macOS packaging notes

**The App Sandbox is off.** Recordings are written to `~/Movies/Relay`, which the
design and §18 treat as the user's own folder; a sandboxed build would write
into its container instead. Re-enabling the sandbox for Mac App Store
distribution means adding `com.apple.security.files.user-selected.read-write`
and holding a security-scoped bookmark for the folder chosen in Settings. The
camera and audio-input entitlements are already declared either way.

**Screen-recording permission does survive a rebuild**, with an Apple Development
signature. Measured on this host 2026-08-25: the Debug and Release bundles have
different `CDHash` values and the same designated requirement
(`identifier "com.relay.relay" … certificate leaf[subject.CN] = "Apple Development: …"`),
and TCC stores the requirement rather than the hash.

An earlier note here said the opposite. It was wrong for identity-signed builds; it
is correct only for ad-hoc ones (`CODE_SIGN_IDENTITY = -`), whose requirement is a
`cdhash`. `./tool/reset-permissions.sh` is for that case alone — on an
identity-signed build it deletes a working grant. Full write-up:
`macos-tcc-and-launchservices.md`.

Developer ID plus notarization is what a distributed DMG needs: a build signed with
a **Developer ID Application** certificate and notarized keeps its permission
across updates, which is what a distributed DMG needs. No Developer ID
certificate was available on this host, so that path is untested here.

Signing is configured in `macos/Runner/Configs/Signing.xcconfig`, overridable
per machine through a git-ignored `Signing.local.xcconfig`. Set
`CODE_SIGN_IDENTITY = -` there to build with no Apple account at all, at the
cost of re-granting screen recording after every rebuild (§23).
