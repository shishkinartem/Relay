# Compatibility matrix

"Supported" means built **and** the basic flow exercised, not merely compilable
(`code-quality.md`). Anything not verified says so.

| Platform | Minimum version | Display capture | Window capture | System audio | Microphone | Camera | Cursor | 30 FPS | 60 FPS |
|---|---|---|---|---|---|---|---|---|---|
| macOS | 13.5 *(provisional, §30.8)* | built + run | built + run | built | built | built | built | built | built |
| Windows | 10 build 19041 *(provisional, §30.9)* | run, defective | run, defective | run, defective | run, defective | run, defective | built, not checked | run, defective | built, not run |
| Linux | — | deferred (§2) | deferred | deferred | deferred | deferred | deferred | deferred | deferred |

Every Windows cell that says `run` was exercised on **2026-09-08** and again on
**2026-09-09**, on Windows 11 — see *The first Windows run* and *The second
Windows run* below for what each visit did, and for which of these cells rests on
the log and which on the tester's account of the files. `defective` is not `not
run` and it is not `built` either: the code path executed, and what came out was
wrong.

The 30 FPS cell moved on 2026-09-09, and downwards: it had been `built, not
measured` because the first run's video track stopped after nine frames and there
was no rate to measure. The second run has one. A 47-48 Hz source recorded at 30
was encoded at 24, and a window nobody was touching at five, so the cell is now
measured *and* wrong rather than unknown. Both are fixed in this change set, and
the fixes are the second set to be written against a Windows run and the second
set that **has not been re-run there** — so no cell moves back to `built + run` on
the strength of them.

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

## The first Windows run

2026-09-08, Windows 11, the `relay-windows-x64` build CI publishes. It is the
first time the application has been started on Windows at all, which is why the
row above changed shape rather than a single cell.

**It was not one session.** `relay.log` holds three process launches and three
recordings, and the distinction is worth making because two of the three ended
well:

| | Process | Recording | How it ended |
|---|---|---|---|
| 1 | started 18:29:30 | 18:29:52 → 18:33:00, three pauses, the last of them 2m20s long | `stopping → finalizing → ready`, renamed `recording-2026-09-08-2333` |
| 2 | the same process | 18:34:34 → 18:34:56, stopped **from `paused`** | `stopping → finalizing → ready`, renamed `recording-2026-09-08-2334` |
| 3 | started 18:37:00 | 18:37:05 → the log stops mid-recording at 18:37:11 | no stop was ever logged; the process died under it |
| — | started 18:37:15 | none | `incomplete_artifacts_found count=1`, fifty milliseconds after `platform_registered` |

All times are the log's UTC. The host runs five hours ahead of it, which the two
finalized recordings encode independently in their own names — `2333` and `2334`
are the local clock at 18:33 and 18:34 UTC — so the file names and the timestamps
disagree by five hours and neither is wrong. The date is the same in both:
2026-09-08.

**That is Windows evidence for two paths this file has never been able to
claim.** §18's finalize path ran twice and worked: the sink writer finalized, the
`.part` was renamed to its final name, and the application reached Ready — once
from `recording` and once from `paused`, which are two different entries into it.
The startup recovery scan works too: the third recording's process ended without
a stop, and the next launch's `findIncompleteArtifacts` found exactly the one
`.part` it had left behind. Pause and Resume also ran for the first time — five
pauses and four resumes across the two finished recordings, the fifth pause
running straight into the stop — with the session machine rejecting
`RecordingTicked` in `paused` throughout, which is most of what those 870 lines
actually are.

None of that says the *files* are good. They are not.

**Exercised, and on whose word.** The three recordings cover both capture
sources, and the log names neither. What it does show is that recording 2 is the
only one the source picker precedes — `selectingSource` at 18:34:05, ten seconds,
then back to `idle` — which is where the window-capture cell comes from: the
picker opening and closing is on the page, what was chosen in it is not. About
the inputs the log says **nothing whatever**: no camera state, no microphone, no
system audio, no device enumeration, and no per-session configuration beyond
`destination=telegram quality=native frameRate=30` at launch. Those three cells
rest on the tester's account of the run and on the files themselves — a track of
crackle is a microphone that ran, an inverted tile is a camera that ran — and not
on `relay.log`. This was the half of the diagnostics defect below that the
2026-09-09 change set did **not** close: the log carried what a session did, and
still not what it was configured to do. It is closed now — `session_source`,
written once per session, is in this change set and did not exist for either
Windows run. Not exercised at all in this one, and unmeasured: whether the cursor
is in the frame, and whether the file holds the frame rate it was configured for.
The video track stopped in all three recordings, so neither question had an answer
here; the frame rate got one the next day, and it is wrong twice over — see *The
second Windows run*.

**What came out:** eight defects, and a ninth that is why finding the other
eight took hours instead of minutes. The re-check column names the lettered
check in `windows-smoke-test.md` that settles each one on the next run.

| What the run showed | Cause | In this change set | Re-check |
|---|---|---|---|
| The video track **stops after eight or nine frames** and never advances again, in every one of the three recordings | one cause was found and is real: `VideoCompositor::Blit` treated every layer as required, so a camera surface that would not bind failed the whole frame — and then every frame after it. Whether it is the whole cause is *not* settled by this log; see *The stalled encoder* below | **fixed** — an optional layer that will not bind is dropped and counted, and the rest of the frame is still drawn (`video_compositor.cpp`) | A |
| The microphone track is **full of holes** — continuous crackling rather than speech | the drain ceiling took the *fastest* source's write head, so the mix encoded past the microphone's head, `AudioRingBuffer::Read` zero-filled the gap, and the real samples that arrived a moment later were behind an encode position that never goes back | **fixed** — the ceiling is the slowest head of the sources that are enabled and have actually started, less a 250 ms margin, with a floor so a stalled endpoint cannot stop the track (`audio_mixer.cpp`) | C |
| The camera picture is **vertically inverted** in the file | the frame is uploaded to a `D3D11_USAGE_DEFAULT` texture, which cannot be mapped, and the row order was never turned around on the way in | **fixed** — the masked, top-down rows are staged and uploaded in one `UpdateSubresource` (`camera_capture.cpp`) | B |
| The **main window stays on screen** during a recording, so it is in the recording | `SetMainWindowVisible` returned early on a null handle: the plugin registers before the runner's window exists, and the handle it was given at registration was never anything else | **fixed** — the handle is resolved lazily through a provider and re-asked when the memo goes stale (`overlay_windows.cpp`) | E |
| Rows in the strip's input sheet **mostly would not take a click**, and which ones did seemed random | the dismissal was a `Listener` *wrapped around* the sheet, and a hit-test path holds every listener from the pressed row up to the root: the same press both chose a row and dismissed the menu, and `HideInputMenu` then destroyed the window and its engine at once, so the pointer-up that completes the tap never landed (§33.4) | **fixed** — the dismissal is a sibling *beneath* the sheet in a `Stack`, whose hit test stops at the first child hit (`input_menu_window.dart`) | D |
| Toggling the camera **freezes the whole interface** for a moment | `setCameraEnabled` ran inline on the platform thread; turning the camera off joins the capture thread, and `ReadSample` blocks until the next frame. macOS had moved the same arm off its main thread for the same reason | **fixed** — the arm is posted to the plugin's serial COM worker, with the preview refresh hopped back to the platform thread (`recorder_windows_plugin.cpp`). It gains a rejection macOS does not have; see *Where the two halves actually diverge* | F |
| The header row has a **dead gap down its leading edge**, and a recovery offer outranks every session state | the header hardcoded macOS's reservation for the system window buttons, which a plain `WS_OVERLAPPEDWINDOW` does not draw over the view; and `hasRecoverableArtifacts` was checked ahead of the session state, so a scan that re-runs after every stop took the screen away from a live recording | **fixed** — the runner reports `WindowChrome` and the composition root maps it to the inset (`window_chrome.dart`, `app_panel.dart`); the recovery screen is gated to the launch states and a dismissal is remembered per path (`relay_app.dart`, `artifact_recovery.dart`) | H |
| The taskbar, Alt+Tab and Explorer all show the **Flutter logo** | `windows/runner/resources/app_icon.ico` was the template's | **fixed** — the icon is generated from the application's own mark at every size the file carries (`tool/make-windows-icon.py`) | G |
| **870 log lines, one warning and not a single error**, while the compositor was failing about twenty frames a second for most of two recordings | §26 requires capture and encoder errors to be logged. Non-fatal `RecorderErrorEvent`s were dispatched into the session and dropped; `recorder_stats` reported `encodedFrames` and not `capturedFrames`, so the log could not distinguish a stopped capture from a stopped compositor; and `FileLogSink` flushed only on rotation and close, so a process that died mid-recording lost its tail | **fixed** — `recorder_view_model.dart` logs every platform error, rate-limited per code with a `suppressed` count and never throttling a fatal one, and reports `capturedFrames` and `audioDiscontinuities`; `file_log_sink.dart` flushes warn and error records as they are written | the log itself |

The diagnostics defect is the one worth generalizing, because the information
was already crossing the channel. The plugin *did* report the composition
failure — a non-fatal `captureFailed` event, about twenty times a second — and
the application dispatched every one of them into the session and logged none.
Two of the recording defects become legible in a single `recorder_stats` line
once it carries both frame counts: `capturedFrames` climbing while
`encodedFrames` sits at nine is *composition*, not capture, and
`audioDiscontinuities` counts the holes in the microphone track. The upside-down
tile and the visible main window are things only an eye catches. A run that logs
its own failure is the difference between a triage that reads a log and one that
reads C++.

### The stalled encoder: one cause found, two profiles seen

The row above claims a cause, not a proof, and the difference is the whole
point of this subsection. The cause is real and is in the source: `Blit` failed
a frame over a layer the frame did not need. What the log cannot say is whether
that accounts for all three recordings, because the two profiles in it are a
factor of twenty apart.

| | Recordings 1 (18:29) and 3 (18:37) | Recording 2 (18:34) |
|---|---|---|
| `encodedFrames` | 9, then 8 — pinned from the first stats line to the last | 9 — pinned the same way |
| `droppedFrames` | 10 → 869 across ~46 s of recording, and 10 → 124 across 5 s: **about twenty a second**, steadily | 5 → 16 across ~16 s: **about one a second**, and not steadily — three bursts with fifteen flat seconds between them |
| `avDriftMs` | falls by ~1000 ms per second of recording | falls by ~1000 ms per second of recording |

The drift is what ties them together. Audio advanced a second per second in all
three recordings while video advanced not at all, so the video track stopped in
recording 2 exactly as it stopped in the other two; what differs between them is
only how many frames arrived to be dropped. In its first second recording 2's
counters moved like the other two's — fourteen frames, nine encoded and five
dropped, against nineteen and eighteen — and only then went nearly flat.

**The likely reading** is that a nearly static application window simply
delivered almost nothing to compose. `Windows.Graphics.Capture` delivers on
change, and a window nobody is touching changes rarely; the bursts in that column
are three moments when something in it redrew. On that reading the two profiles
are one defect seen at two capture rates, and the fix covers both.

**Nothing in the log proves it.** `recorder_stats` reported `encodedFrames` and
not `capturedFrames`, and a compositor failing every frame it is handed and a
capture handing it nothing are the same two numbers. That is why this row is not
written as settled.

**What settles it on the next run** is check A, and it needs one comparison:
`capturedFrames` climbing while `encodedFrames` stands still is composition, and
this fix is the right one. Both flat is a starved capture — a second defect
wearing the first one's symptoms, which nothing in this change set touches.

Keep the two claims apart when quoting this file. *The cause we found and fixed*
is a compositor that failed a whole frame over an optional layer; it was in the
source, it is gone, and it explains the two steady-drop recordings without
strain. *The evidence we will have next time* is the pair of counters that says
whether it explained the third one too.

**Answered 2026-09-09, and both readings were partly right.** The counters say
the compositor fix held — `droppedFrames` is 0 across that whole run and no
`capture_error` line appears in it — and they also say the second suspicion was
real: a nearly static window does starve the capture, `capturedFrames` standing
still for five seconds at a time while `avDriftMs` falls by a second per second.
The two profiles were two defects after all, wearing one symptom. The second one
is `RepeatLastComposedFrame`, in this change set. See *The second Windows run*.

```text
RUN 2026-09-09: every fix above, on Windows — closed
This block stood as NOT RUN for a day. The session that closes it is *The second Windows
run* below, and it settles the two rows that mattered: `droppedFrames` is 0 and there is
no `capture_error` line anywhere in it, so the compositor no longer fails a frame over an
optional layer, and `audioDiscontinuities` never rises, so the microphone track is not
being punched full of holes. What it does not settle is the eye half — the camera's
orientation and the cursor were not reported back, and the log cannot see either.

None of that was verified *here*, and the reason has not changed: no Windows host, and no
MSVC toolchain, Windows SDK or cmake on this machine. What each fix has by way of
automated coverage, which is what a re-run does not give you:

- the audio mixer's drain ceiling, resampler and ring buffer are now a second
  self-contained ctest binary (`windows/test/audio_mixer_test.cpp`, wired into
  `windows/test/CMakeLists.txt`). The defect was entirely inside two pure functions and
  no suite could have caught it while they were compiled by nothing but the application
  build;
- the compositor, the camera upload, the lazy main-window handle and the camera toggle's
  move onto the serial worker have **no automated coverage at all**.
  `video_compositor.cpp` needs D3D11, `camera_capture.cpp` needs Media Foundation, and
  `overlay_windows.cpp` and the plugin need a real HWND and a Flutter registrar, so none
  of them can be reached from `windows/test`, which links none of it. They are read, not
  measured;
- the Dart half runs everywhere and does have tests: the error throttle, the two new
  stats fields and the file sink's flush rule in
  `test/features/recorder/application/recorder_view_model_test.dart` (group
  *diagnostics (§26)*) and `test/core/logging/file_log_sink_test.dart` (group
  *durability*); the header inset in `test/app/window_chrome_wiring_test.dart` and
  `test/design_system/app_title_bar_test.dart`; the sheet's hit test in
  `test/features/recorder/presentation/input_menu_window_test.dart`; the recovery
  gating in `test/features/recorder/presentation/recovery_routing_test.dart`; and the
  icon file's own contents in `test/tools/windows_icon_test.dart`.

Re-running the session is what closed this, and the script for it was written in advance —
`docs/development/windows-smoke-test.md` gained a section of lettered checks, A through
H, one per fix, each saying what to do, what a fix looks like, what the original defect
looks like, and the log line that settles a disagreement between the two. Whether the
session followed it check by check is not recorded; what is recorded is that the log
carries the fields those checks read, which is why this block could be closed off the log
rather than off an impression. The list is deliberately not repeated here: the version that stood
in this block named four checks when eight things had been fixed, which is exactly how a
checklist kept in two files goes wrong.
```

## The second Windows run

2026-09-09, the same Windows 11 machine, the `relay-windows-x64` build carrying
the eight fixes above. `relay.log` is appended across runs rather than truncated
at launch, so it holds both visits; everything from `2026-09-09T19:33:17` down is
this one.

**The files are no longer broken in the way the first run's were, and the log is
what says so.** Across every session of this run:

- **no `capture_error` line at all**, and `droppedFrames=0` on every
  `recorder_stats` line. The first run dropped 869 frames in 46 seconds while the
  compositor failed about twenty a second. The stalled-encoder fix held, which is
  what check A was written to settle;
- **`capturedFrames` climbs**, which is the field that did not exist last time. It
  is what makes the rest of this section legible;
- **`audioDiscontinuities` sits at 3 — 4 in one session — from the first stats
  line of a session and never rises.** The perforated microphone track of the
  first run is exactly what a climbing count would look like, and it does not
  climb. This one holds whatever the strip said, because the build that ran opened
  both endpoints regardless of their flags and so fed both rings, and the drain
  ceiling that punched the holes is on the read side. It is the last run that can
  be read that way: since 2026-09-10 an input that is switched off is never opened
  at all (*Audio*, `../architecture/media-pipeline.md`), so the next run's count
  speaks only for the inputs that were on;
- §18's finalize path ran five more times and worked three more times, and the
  startup recovery scan found the first run's leftover `.part` and let the user
  discard it (`artifact_discarded recordingId=ff0a3497`, 19:33:20).

**What the log still cannot say** is what any of it recorded. No session names its
source, its size or its inputs, and `settings.json` ends the day with the
microphone, system audio and camera all off — which is the *last writer's* state,
from a file three processes were writing, not a record of any one session. That is
the gap `session_source` closes (`recorder_view_model.dart`, new in this change
set): one line per session carrying the source kind, its id, its pixel size and
the three effective input flags. It did not exist for this run, so the input cells
in the table at the top of this file still rest on the tester's account.

**Five recordings across at least four processes, three of them recording at
once.** All times are the log's UTC; the host runs five hours ahead, which is why
a run made on 2026-09-09 renames its files `recording-2026-09-10-…`.

| | Process | Recording | How it ended |
|---|---|---|---|
| 1 | launched 19:33:17 | 19:33:29 → 19:34:26, one 21 s pause | `stopping → finalizing → ready`, renamed `recording-2026-09-10-0034` |
| 2 | the same process | 19:34:43 → one of the stops below | `finalizing → failed` |
| 3 | a second process, whose launch is not in the log | 19:35:08 → one of the stops below | `finalizing → failed` |
| 4 | a third process, whose launch is not in the log | 19:38:00 → 19:38:14 | `stopping → finalizing → ready`, renamed `recording-2026-09-10-0038` |
| 5 | launched 19:38:30 | 19:38:42 → 19:38:56 | `stopping → finalizing → ready`, renamed `recording-2026-09-10-0038` again |

Three sessions were stopped in the space of six seconds — 19:38:14, 19:38:17 and
19:38:20 — and only the first of the three finalized. Which stop belongs to
recording 2 and which to recording 3 is not recoverable from the log; that the
three were running *at the same time* is, because no `recording → stopping` line
exists anywhere between 19:34:43 and 19:38:14.

Two details of that table are the log lying about itself, and both are worth
knowing before quoting it. Recordings 4 and 5 are renamed to the same name: the
`recording_renamed` line prints the name that was *asked for*, and
`LocalRecordingStore.rename` gives the colliding one a numeric suffix on disk, so
the second file is `recording-2026-09-10-0038-2`. And the missing launches are
missing because four processes were appending to one `relay.log`, each at its own
offset. Four lines in this half of the file are damaged: two are truncated
mid-field with another process's line spliced straight on — `recorder_stats
capturedFrames=155 encodedFrames=85 droppedFrames=0` runs into
`artifact_discarded` with no line break — and two survive only as tails, one of
them beginning `ts capturedFrames=1798`. Nothing in the application can suppress a
launch triple, so the two that are absent were almost certainly overwritten the
same way. **A multi-instance run damages the evidence it produces**, which is its
own reason to allow only one.

**What came out:** five defects, of which four are fixed here. The re-check column
names the lettered check in `windows-smoke-test.md` that settles each on the next
run.

| What the run showed | Cause | In this change set | Re-check |
|---|---|---|---|
| **Three Relay processes recording at once**, and two of the three finalizations then failed | nothing stopped a second launch. Windows starts a process per double-click; macOS is spared this by LaunchServices, which activates the running application instead, and has no Windows counterpart to inherit | **fixed** — a named `Local\RelayRecorderSingleInstance` mutex taken before COM and before the engine, with the second launch restoring and fronting the first (`windows/runner/main.cpp`) | I |
| **Relay leaves the taskbar for the length of a recording**, so it looks exactly as it would if it had crashed — which is why there were three of it | `SetMainWindowVisible(false)` used `SW_HIDE`. §6 asks for the panel off the screen and that delivers it, but it takes the taskbar button and the Alt+Tab entry with it | **fixed** — `SW_SHOWMINNOACTIVE`, and `SW_RESTORE` to bring it back. A minimized window is rendered by nothing, so it still cannot reach a display recording (`overlay_windows.cpp`) | J |
| **The control strip did not come back for the second recording in a process** — a recording with nothing on screen to stop it | **not settled by this log.** The leading suspect is the strip's Flutter engine being destroyed on hide and rebuilt on the next show, which is also what `../adr/2026-08-23-overlay-windows-as-secondary-flutter-engines.md` already said must not happen | **fixed on the leading suspect only** — every overlay is hidden rather than destroyed and the engines live for the process, as the ADR has it (`overlay_windows.cpp`) | K |
| **Video encoded at 24 fps from a 47-48 Hz source**, in a file declaring 30 — recording 1 captured 1,373 frames and encoded 689 in 29 seconds | the frame-rate gate accepted a frame when a whole interval had passed *since the last accepted one*. A source ticks on its own vblank and so arrives late on every deadline; the schedule was measured from those late arrivals and drifted later each time until two source periods fit in one gap. The 10 % tolerance it carried was far too small to cover an extra vblank | **fixed** — the gate is a deadline advanced by exactly one interval per accepted frame, in `NextFrameDeadline100ns` (`recorder_types.{h,cpp}`), with ctest cases | A |
| **Video encoded at five frames a second recording a static window** — recording 5 encoded 75 frames in 14.6 s, and `avDriftMs` fell by exactly 1000 ms per second for every second `capturedFrames` stood still | `Windows.Graphics.Capture` delivers a frame for a window only when its content *changes*, and nothing in the pipeline republished anything, so the video timeline stopped while the audio ran on. macOS is paced by ScreenCaptureKit's `minimumFrameInterval` and has no equivalent | **fixed** — the encoder repeats the last composed frame when the queue comes up empty and the timeline has fallen two intervals behind (`RepeatLastComposedFrame`, `recording_session.cpp`; the arithmetic is `RepeatFrameTimestamp100ns`, with ctest cases) | A |

Neither frame-rate row has a lettered check of its own. Check **A** is the one to
read, and to read literally: its *fixed* criterion is `encodedFrames` climbing by
roughly the frame rate every second with `avDriftMs` small and wandering. On
2026-09-09 `encodedFrames` climbed — the encoder no longer stops, which is what A
was written for — at 24 a second against a configured 30, with `avDriftMs` pinned
near +260 ms and collapsing by a second per second whenever the source went quiet.
A was passed on the letter and failed on the number.

### Why two finalizations failed: a mechanism, not a proof

The stops at 19:38:17 and 19:38:20 both went `finalizing → failed` with
`finalization_failed … code=finalizationFailed`, and each was preceded by
`platform_state state=failed` — so the *native* stop failed, not the Dart rename
after it. The log gives no reason beyond the code.

One line is suggestive. At 19:34:59.166, sixteen seconds into recording 2 and
while it was still running, the log carries
`artifact_discarded recordingId=34437467` — an id that appears nowhere else in the
file, and with no `incomplete_artifacts_found` in front of it.
`LocalRecordingStore.discardArtifact` is reachable from exactly one place, the
recovery screen's **Discard file**, and the scan behind that screen
(`findIncompleteArtifacts`) selects `.part` files on size alone: no ownership
check, no lock check, no age. **A second Relay launching while a first is
recording therefore finds the first's live `.part` and offers to discard it**, and
a `.part` deleted out from under a sink writer is the right shape for a `Finalize`
that fails.

That is a mechanism read off the source, not a proof about this run. Two
finalizations failed and only one discard is logged; the log is provably lossy
here, so a second discard may simply have been overwritten, or the two failures
may have a cause nothing recorded. Either way the condition is what check **I**
removes: with one Relay per user session there is no second scanner to offer
another session's file.

```text
NOT RUN, as of 2026-09-10: every fix in the table above, on Windows
Reason: no Windows host here, and no MSVC toolchain, Windows SDK or cmake on this machine
— unchanged. What each fix does have:

- the frame pacing is four pure functions in `recorder_types.cpp` — `FrameInterval100ns`,
  `FrameIsDue`, `NextFrameDeadline100ns`, `RepeatFrameTimestamp100ns` — and
  `windows/test/recorder_types_test.cpp` drives a steady source through exactly the gate
  `OnCapturedFrame` runs: 47, 48 and 60 Hz onto 30 fps, 60 onto 60, a source slower than
  the configured rate encoded whole, and ten seconds accumulating no drift; then the
  repeat's two-interval grace, a 20 Hz window that earns no repeats at all and a silent
  source held at the configured rate. They live there rather than in `RecordingSession`
  precisely so ctest can execute them — which nothing has yet, here or in CI, because this
  change set has not been pushed;
- the single-instance mutex, the minimize and the overlay hide/show have **no automated
  coverage at all**. `windows/runner/main.cpp` is the runner, and `overlay_windows.cpp`
  needs a real HWND and a Flutter registrar, so neither is reachable from `windows/test`.
  They are read, not measured;
- `session_source` is Dart and is tested — `test/features/recorder/application/
  recorder_view_model_test.dart`, group *diagnostics (§26)*.

Re-running the session is what closes this. `windows-smoke-test.md` gained checks I, J and
K for the three fixes that answer what a user saw; the two frame-rate rows are settled by
check A's numbers rather than by a check of their own.
```

## Input devices (§33.2)

What each platform reports in `selectableDeviceKinds` / `meterableDeviceKinds`.
The UI reads those capabilities, never the platform name.

| Platform | Camera choice | Microphone choice | System-audio choice | Metering |
|---|---|---|---|---|
| macOS | selectable | selectable | **none** — ScreenCaptureKit delivers the system mix, so there is no endpoint to pick | microphone only |
| Windows *(sheet opened once, 2026-09-08)* | selectable | selectable | selectable — WASAPI loopback is per render endpoint | microphone only |
| Linux | deferred (§2) | deferred | deferred | deferred |

Only the microphone is meterable on either platform. System audio carries no
level on purpose: a level is worth showing where the user can act on it, and
they can change neither the macOS endpoint nor what the machine is playing from
inside this application.

The Dart half of the contract is unit-tested by
`packages/recorder_platform_interface/test/contract_test.dart`, group
*input devices (§33.2)*. The table above is what each platform is contracted to
report (§33.8), not a measurement: live enumeration against attached hardware
was not exercised while it was written. The Windows half compiles in CI only —
never on this host — and nothing in this table has been measured on that side
either. The 2026-09-08 run did open the strip's input sheet, which is more than
this paragraph used to claim: a sheet cannot list rows without an enumeration
behind them, and defect D — rows that would not take a click — is an account of
pressing them. What the enumeration returned went unrecorded on both sides of
the channel, because the log carries no device fields at all, so the run
exercised this path without measuring one row of it. The 2026-09-09 run adds
nothing here: it opened the *source* picker four times and the log records no
device call at all. `session_source` is the first line that will say which inputs
a session actually had, and it did not exist for either visit. See *Not
verified*.

### Where the two halves actually diverge

Read off the sources, not intended behaviour — the table on 2026-08-30, the
`setCameraEnabled` row on 2026-09-09, the rows marked *2026-09-10* on that day.
Anything here that disagrees with
`../architecture/platform-channel-contract.md` is a gap in a platform, not a
second reading of the contract.

The 2026-09-10 rows come from an audit that read the whole Windows plugin against
every Accepted ADR, `TECHNICAL_SPEC.md` and the macOS sources, and returned
twenty-seven findings. **They are a selection, not the list.** What is here is
what a user could reach by using the application normally and what is still
standing after the 2026-09-10 change set; left out are the findings needing an
unreachable code path or a race the Dart side already blocks, the ones that change
set closed — those are recorded where they belong, in *The second Windows run* and
in the census table under *What a session ends holding* — and the four the audit
graded high, which are the subject of code changes rather than of a row. If any of
those four is still standing when this change set lands, it belongs here.

**A struck-through row has been closed since it was read**, and is kept rather
than deleted so that the divergence and the thing that answered it stay on the
record. Three are struck: the audio re-arm and the colliding recovery target,
found by the audit and closed by the change set that answered it, and
`startInputMetering`'s `deviceId`, closed long enough ago that *Known gaps* below
already recorded it while this table went on saying the opposite. The audit's own
dominant finding is the sentence worth keeping either way: **Windows reports the
state it was asked for, macOS the state it achieved.** Most of what follows is
that sentence in a different place — one instance fewer than when it was written,
because the input flags a Windows session announces are now the ones it achieved
rather than the ones it was configured with (`EmitInputs`, `OnInputLost`).

| Behaviour | macOS | Windows |
|---|---|---|
| ~~`startInputMetering`'s `deviceId`~~ *(read 2026-08-30, closed since)* | **honoured.** `InputMeter.openTap` resolves the id through `InputDeviceEnumerator.resolve(kind:requestedId:)` and falls back to the default only when it no longer resolves | **honoured.** The plugin arm passes `StringAt(*arguments, "deviceId")` into `meter_.Start`, and a start naming another device re-points the tap rather than opening a second one |
| `getInputDevices` with an absent or unrecognised `kind` | `[]` — `MediaDeviceKind(name:)` yields nil and the plugin answers with an empty list | **rejects** with `unknown` ("An input device kind is required.") |
| `getInputDevices` under load | always answers; no queue between the call and AVFoundation | **rejects** with `unknown` ("busy with an earlier request") once the 16-deep serial COM worker is full |
| `setCameraEnabled` under load | always answers; the arm runs on an unbounded `Task`, so a toggle can be slow and can fail on the device, but is never refused for being late | **rejects** with `unknown` ("The recorder is busy with an earlier request.") once that same 16-deep worker is full. The arm moved onto it on 2026-09-09 because turning the camera off joins the capture thread and `ReadSample` blocks until the next frame, which froze every overlay while it ran inline — the fix for defect F. Its sibling toggles, `setMicrophoneEnabled` and `setSystemAudioEnabled`, stayed inline: they only re-point the mixer and cannot block |
| `start`/`stopInputMetering` with an absent or unrecognised `kind` | silent no-op | **rejects** with `unknown`, before the meter is reached |
| `isAvailable` on a media-device map | **computed**: `isConnected && !isSuspended && !isInUseByAnotherApplication` | **constant `true`** for every row. Only `DEVICE_STATE_ACTIVE` endpoints are enumerated at all, and openability is never probed — so §33.7's "device busy or held exclusively by another application: the meter says so rather than reading zero" cannot be satisfied from this field on Windows |
| `isSystemDefault` | the device `AVCaptureDevice.default(for:)` would return | audio: the endpoint `GetDefaultAudioEndpoint(…, eConsole)` names. Cameras: **index 0**, because Media Foundation names no default and the recorder opens the first source |
| Metering across `pause` | keeps reporting; `pause()` touches the clock and the state only | keeps reporting; packets are metered and simply not written |
| A meter whose endpoint will not open *(2026-09-10)* | **says so, once.** `InputMeter.openTap` reports a typed non-fatal error and then `stopTicker()`, under a comment naming the reason: a device that will not open is not a device that is quiet | **ticks zeroes.** The meter keeps emitting samples at ~20 Hz, `PlatformInputMeter.isSilentFor` trips after ~3 s, and the sheet renders **Test — no sound**. A refused privacy setting and a microphone another application holds both read as a working microphone in a quiet room. This is the second mechanism failing §33.7's "device busy or held exclusively by another application: the meter says so rather than reading zero" — the `isAvailable` row above is the first |
| ~~Toggling an input back on after its stream has dropped~~ *(2026-09-10, closed the same day)* | **re-arms it.** `setMicrophoneEnabled` guards on `!microphone.isRunning` and restarts a stopped stream; a restart that fails puts the toggle back to off and re-reports. System audio is applied optimistically and reverted the same way | **Closed — Windows re-arms it too.** Both toggles now call `RecordingSession::StartAudioInput`, which opens the endpoint when that input is switched on and is not already capturing (`capture->running()`, the guard macOS spells `!microphone.isRunning`) — the same call `Start` makes, so an input opens the same way whenever it is switched on. `AudioCapture::Start` joins the exited thread and re-arms its stop event first, which is what makes the object a dropped device left behind restartable at all: assigning over a joinable `std::thread` is a `std::terminate`. A restart that fails reports and clears the flag through `OnInputLost`, so the strip shows the input as unavailable rather than lit and silent. Read off the source; never run |
| A live device swap that will not open *(2026-09-10)* | **no notice.** `selectInputDevice` cannot fail on the wire; the failure travels as a non-fatal `microphoneUnavailable`/`cameraUnavailable`, which `_degrade` turns into unavailable-and-off for the rest of the session — while the previous device is still being recorded perfectly | **rejects the call**, so the sheet shows §33.7's notice — *That microphone would not open. Still using the previous one.* — and the input keeps working. The two halves are wrong in opposite directions: the notice §33.7 asks for exists only on Windows, and the input §33.7 says keeps running dies only on macOS |
| When the camera is opened *(2026-09-10)* | in `prepare`, beside the microphone, so the tile is live before `start` | in `Start`. With the countdown on (§10) the preview tile is dead for the whole 3/5/10 s pre-roll — which is the interval that exists so the tile can be framed and dragged — and a camera that will not open reports `cameraUnavailable` after the count rather than before it, so the strip changes state under the user mid-count |

Two findings are deliberately not rows. A second `pause` against an
already-paused Windows session succeeds where macOS throws `invalidState`, which
has no reachable symptom today because the view model's in-flight set drops the
overlapping command first; it is a missing backstop, to close on the next Windows
change. And the 16-deep serial COM worker can refuse **eleven** calls, not the two
this table names — `stop` among them, with a bare `unknown` the application cannot
tell from a broken recorder. Reaching sixteen outstanding tasks needs a pile-up,
so the two documented rows stay the documented ones; the count is here so nobody
reads the table as exhaustive.

### Beyond the input devices

The 2026-09-10 audit looked wider than §33.2, and these are its findings that are
not about devices at all. They live in this section because this is where the file
keeps platform divergences, not because they belong to the heading above.

| Behaviour | macOS | Windows |
|---|---|---|
| When the `.part` file appears | at `start()`. `prepare` constructs the `AVAssetWriter` and creates nothing; `startWriting()` is inside `start()` | at `prepare`. `MediaWriter::Open` calls `BeginWriting()` there, so the fMP4 header is on disk before the countdown begins. Every cancelled countdown then leaves a few hundred bytes of `recording-<id>.part`, which `findIncompleteArtifacts` reports (it skips only zero-byte files) and `MediaWriter::Probe` refuses to repair — so the user is offered, and must dismiss, an unrecoverable repair for a recording they cancelled before it started, once per cancellation. The *whether* of this was an open question in *Not verified* below; the audit settles the mechanism and leaves the byte count to the next run |
| A write that fails during the final drain | consulted. `finishWriting()` runs only `if writer.status == .writing`, and AVAssetWriter surfaces a failed append through that status | **discarded.** The drain loop `break`s on a failed `WriteVideoFrame` without an error event, the file is finalized short, and `droppedFrames` does not move because the queue was popped rather than dropped. A disk that fills in the last second produces a truncated recording and a clean Ready screen |
| ~~Recovering onto a name that already exists~~ *(2026-09-10, closed the same day)* | **refuses.** `recover(path:)` checks `fileExists` before touching anything and moves the artefact back if the probe fails | **Closed — refuses too, and atomically.** `RecoverArtifact` renames the artefact with `MoveFileExW(…, 0)`: without `MOVEFILE_REPLACE_EXISTING` the move itself fails on an occupied name, so there is no `bFailIfExists` argument left to get wrong and no window between a check and the move. The probe now runs under the final name and the artefact is moved back untouched when nothing readable is in it, which is also how macOS orders it (`../adr/2026-09-10-recovery-renames-the-artefact.md`). Read off the source; neither Windows visit reached the recovery path at all |
| The Circle preset on an adapter with no `ALPHA_STREAM` | not possible. `VideoCompositor` masks unconditionally through Core Image; there is no capability gate and no fallback | **square in the file, circle in the preview.** The D3D11 fallback is deliberate and commented — a rounded tile with square corners rather than no tile — but nothing tells Dart, nothing is logged, and §33.5's rule that the crop is identical in the preview and in the file is broken silently. Narrow: mainstream drivers report the cap |
| The Windows 11 capture highlight border | no counterpart; ScreenCaptureKit draws none | **drawn, and unannounced.** `CaptureEngine::Start` asks for `IsBorderRequired(false)` inside a `try` whose `catch` is empty, commented *cosmetic only, and access-gated on some builds: never fatal* — right about fatality, and the throw is the likely path rather than the exception, because the gate is the `graphicsCaptureWithoutBorder` restricted capability an unpackaged Flutter runner does not declare. The system then draws the highlight into the desktop composition the capture reads, so it is in the file as well as on the screen, for the whole session, and nothing in the application, the log or the user-facing docs says to expect it |

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
observers need real hardware to arrive or leave, and the Windows half — which
compiles in CI since 2026-08-31 — has never had a device arrive or leave under
it. The 2026-09-08 recordings ran the application, not this code path: on
Windows the watcher is registered by the first `getInputDevices`, which the
input sheet did make, and then nothing was plugged in or unplugged.

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
`IsCursorCaptureEnabled` requires. Windows compiles under MSVC in CI, but that
minimum has never been checked against a running application.

## Native unit tests

The pure half of each platform — the wire contract, the picture-in-picture
geometry, the canvas arithmetic and the session clock — is now separated from
the Flutter- and OS-bound half so it can be executed on its own.

| Platform | Where | How to run | State |
|---|---|---|---|
| macOS | `packages/recorder_macos/macos/recorder_macos/core` | `swift test` | green — **run the command for the count**, do not quote one from here. It has been hand-copied to three files and drifted three ways |
| Windows | `packages/recorder_windows/windows/test` | `cmake -S … -B build/win-tests && ctest --test-dir build/win-tests` | **never compiled on this host** — `cmake`, `ctest` and `cl` are all absent. CI configures, builds and runs it under MSVC on windows-2022, and it has been **green since `d187db7`** (2026-08-31); before that it had failed on every run the repository had |

Both suites assert the same properties on purpose. The two platforms hand-write
the same wire spellings and re-implement the same geometry, and nothing in the
Dart layer can observe them disagreeing — mirroring the assertions is the only
thing that catches drift. It already has: `ResolvePipRect` and
`CameraOverlayConfiguration.effectiveAspectRatio` handled a malformed aspect
ratio differently (a square tile against a 0.0001-ratio sliver) and were aligned
on the default 16:9.

## Not verified

```text
NOT RUN 2026-09-08: the Windows half of the native-resolution change
`docs/adr/2026-09-08-native-resolution-recording.md` touches three C++ files —
`recorder_types.{h,cpp}` (the `native` branch of `ResolveCanvasSize`, the 3840x2160 cap
and the new `RecommendedVideoBitrate`), `media_writer.{h,cpp}` (the old per-writer bitrate
deleted, the call re-pointed) and `recorder_windows_plugin.cpp` (the `targetHeight` default
and the advertised `qualities`). Nine ctest cases were written for them and **none has been
executed here**: `recorder_types.h` includes `windows.h`, so the suite cannot even be
configured on macOS. CI's `native-windows` and `build-windows` jobs are the first thing
that will run any of it.

Reasoned, not measured, on either platform: whether a software H.264 encoder keeps up with
a 3024x1964 canvas at 60 fps. The bounded queue drops the newest frame rather than
stalling, so the predicted failure mode is a stuttery file rather than a stopped recording
— but nobody has watched it happen.
```

```text
CONFIRMED 2026-09-08: `swift test` compiles only RecorderCore, not the plugin's own sources
The native-resolution change edited `Sources/recorder_macos/CaptureSourceEnumerator.swift`,
`swift test` passed 236 tests, and `flutter build macos --release` then failed on that very
file: `CGDisplayModeGetPixelWidth/Height` are renamed by API notes and are an *error* to
call from Swift against the macOS 26.4 SDK (use `CGDisplayMode.pixelWidth/.pixelHeight`).

The Swift suite builds the `core` package alone — that split is why it can run without
Flutter at all — so the twelve files under `Sources/recorder_macos/` (the plugin,
`RecordingSession`, `OverlayWindows`, `CaptureSourceEnumerator`, `VideoCompositor`, …) are
compiled by **nothing but the application build**. A green `swift test` says nothing about
them. Treat `flutter build macos --release` as the compile gate for that half, the way
CI's `build-windows` is for the C++ half.
```

**How to change any of this:** `docs/development/windows-smoke-test.md` is the ordered script for
a Windows run, written for a machine with no development tools. CI now publishes
`relay-windows-x64` on every green run, so getting a build no longer needs a Windows dev setup.
It has been followed twice, on 2026-09-08 and 2026-09-09 — *The first Windows run* and *The
second Windows run* are what those found — and it has gained a lettered check per fix each
time: A through H after the first visit, I through K after the second.

```text
NOT RUN 2026-09-08: whether the published Windows build starts on a clean machine
`windows/CMakeLists.txt` is the stock Flutter template: it never calls
`InstallRequiredSystemLibraries` and nothing overrides `CMAKE_MSVC_RUNTIME_LIBRARY`, so
`relay.exe` and all four plugin DLLs link `/MD` against the VC++ 2015-2022 redistributable —
which is NOT an OS component (the UCRT is; this is not). Nothing in the repository copies those
DLLs and, until now, nothing named them as a prerequisite.

The first person to run Relay on Windows is the most likely to be on a clean VM, and the failure
mode is a missing-DLL dialog that reads as "Relay is broken". README.md now states the
prerequisite; bundling it instead (`InstallRequiredSystemLibraries` + an `install(FILES ...)`)
remains the better fix and is not done.

Windows N/KN also lack the Media Feature Pack; the plugin links mfplat/mfreadwrite/mf/mfuuid as
imports, so the process fails to start rather than degrading.
```

```text
NOT RUN 2026-09-08: whether a cancelled pre-roll leaves a `.part` on Windows
macOS opens the AVAssetWriter inside `start()`, so cancelling the countdown creates no file.
Windows opens the sink writer and calls `BeginWriting()` back in `Prepare` (`media_writer.cpp`),
so the file exists before the count even begins. Recovery is protected only by
`findIncompleteArtifacts` discarding zero-length files — and whether the writer has flushed
anything into it by cancel time is unknown. Still unknown after 2026-09-08: those three
recordings all started, and not one of them cancelled a countdown.

If it can be non-empty, a cancelled countdown would offer the user a "repair" for a recording
that never started. Verify on the next Windows run: start a countdown, cancel it, relaunch,
and see whether the recovery screen appears. Still not verified after 2026-09-09 either —
`settings.json` came back with `countdownSeconds: 0`, so no countdown ran. The 2026-09-10
audit closes everything about this except the byte count: `findIncompleteArtifacts` skips
only zero-byte files, and `MediaWriter::Probe` requires `duration_ms > 0`, so a `.part`
carrying nothing but an fMP4 header is offered *and* refused. Whether `BeginWriting()`
flushes those bytes before the user can press Cancel is the one thing left to measure.
```

```text
NOT RUN 2026-09-08: the control-strip countdown rewind, on either platform
`docs/adr/2026-09-08-pre-recording-countdown.md` adds one line to
`OverlayWindows.hideControlStrip`: `lastStripState.removeValue(forKey: "countdownMs")`.
`OverlayWindows` sits outside `RecorderCore`, so `swift test` cannot reach it and it has no
unit coverage — the never-shrink ADR records the same limitation for the placement code.

This entry said *macOS* until 2026-09-10, on the ADR's word that Windows needed no
equivalent because it destroyed the strip window and kept no snapshot. It keeps one now:
`OverlayWindows::HideControlStrip` rewinds `isStopping`, `isPaused` and `elapsedMs` and
erases `countdownMs` from `last_strip_state_` before hiding, which is the same three-field
rewind and the same erasure. It has the same coverage as the macOS line — none — and is
reachable by no suite on this host, so it is one question on two platforms now.

Miss it and the *next* session's strip opens accent-washed showing a stale count with dead
controls until the first real push: self-correcting in milliseconds on a fast machine, and
not on a slow one. **Verify by hand: two sessions back to back, the second with the
countdown off.** On Windows that is check K's *partly fixed* case.

Also unverified against a running application, on either platform: that the strip does not
resize between counting down and recording. It is asserted twice in widget tests — the
rendered `Size` and the reported `contentSize` — which is the executable form of the rule,
but the rule exists because a real window hosting a real Flutter view crashed.
```

```text
VERIFIED IN CI 2026-08-31: the Windows native build and the native unit tests
Both jobs are green on `d187db7` — the first time either has ever passed. Recorded at
length because this file confidently said the opposite, and was wrong in both directions.

- `build-windows` (`flutter build windows --release`, MSVC on windows-2022) had failed on
  **every run this repository has ever had**. The entry that stood here guessed the cause
  and guessed it wrong: it said the compile was "a push away" and that CI had simply never
  seen the work. CI had seen it, five times, and it did not compile. Two first-compile
  defects, both fixed in `d187db7` — `media_writer.cpp` never included `audio_mixer.h`,
  where `kMixSampleRate` and `kMixChannels` are defined, and `IntAt`/`DoubleAt` in
  `recorder_windows_plugin.cpp` declared a variable named `small`, which `rpcndr.h` —
  reached through `windows.h` — defines as `char`.
- `native-windows` (cmake + ctest) now passes too. `SessionClock.PausedIntervalsAreSubtracted`
  was the cause and was the only one: it asserted 5 s where `capture - start - paused_total`
  gives 6 s (10 s of wall time, 4 s of it paused). The expectation was wrong, not the clock
  — §9 and every sibling case subtract the pause, as does the macOS `SessionClock`. The
  strip-geometry and device cases added since compile and pass.

**What this settles, and what it does not.** The Windows half now compiles, links and
passes its pure-arithmetic suite against a real MSVC toolchain and Windows SDK, which is
more than this file could claim before. What it does not settle was demonstrated on
2026-09-08, when the application was run on Windows for the first time and produced three
recordings that were broken in eight separate ways (*The first Windows run*). A compiler
proves the code is well-formed, not that a recording comes out — this section said exactly
that, and the run is the receipt. Every runtime row in this section that those recordings
did not touch stays unverified. The DPI question under *The movable control strip* still needs a
physical two-monitor machine, which CI's single virtual display cannot provide.

NOT RUN: the Windows native build on the development host
Reason: no MSVC toolchain, no Windows SDK and no cmake on this machine (macOS). Unchanged,
and now the lesser gap — CI covers the compile on every push.

NOT RUN: recovering a fragmented `.part` on Windows
Reason: same. docs/adr/2026-08-23-fragmented-mp4-on-both-platforms.md changes the sink
writer's container type so an aborted `.part` is recoverable. Half of that is no longer
unrun: on 2026-09-08 a process did die mid-recording, and the next launch's
`findIncompleteArtifacts` found the `.part` it left (*The first Windows run*). Finding is
not repairing. Nothing in that log calls `recoverArtifact`, so whether the fragmented
container actually yields a playable file on this platform is still unknown — and it is
the half the ADR is about. Take it on the next run: kill Relay mid-recording, relaunch,
press `Try to repair`, and play what comes out. Since 2026-09-10 that run answers a second
question with it: `RecoverArtifact` renames the artefact rather than copying it
(`../adr/2026-09-10-recovery-renames-the-artefact.md`), so confirm the `.part` is gone
afterwards and the recovery card does not come back — then put an `.mp4` of the target
name in the folder first and confirm the repair fails with the artefact still on disk.

NOT RUN: Windows native input-device enumeration and metering (§33.2)
Reason: same. input_devices.cpp/.h and the plugin arms that call them have never
been through a compiler on this host, so the endpoint enumeration, the camera
enumeration through Media Foundation, the default-first ordering, the
reference-counted meter, the IMMNotificationClient watcher and every divergence
listed under *Where the two halves actually diverge* are read off the source and
not measured. windows/test/recorder_types_test.cpp covers the pure half only; it is
green in CI and has not been compiled here — run it with
`ctest --test-dir build/win-tests -C Debug --output-on-failure` on a Windows host.
The count is deliberately not quoted: it has been hand-copied into three files
before and drifted three ways.

NOT RUN: Windows debugResourceCensus (spec 19.1)
Reason: same — compiled in CI, never run. `RecordingSession::DebugCensus()`,
`OverlayWindows::DebugCensus()`, `InputMeter::DebugCensus()`, the `ResourceCensus`
struct in recorder_types.{h,cpp} and the plugin's `debugResourceCensus` arm are all
read off the source and not measured. The `ResourceCensus` and
`MeteringSubscriptions::Total` cases added to windows/test/recorder_types_test.cpp
cover the arithmetic and the released-rows rule; like the rest of that suite they
pass in CI and have not been compiled here.

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
`debugResourceCensus`, and the two lifetimes it reports **agreed on 2026-09-10**
for the first time — see the note under the table for what they used to be and
why the change was not a tidying-up.

| | macOS | Windows |
|---|---|---|
| Overlay engines | built on first use, kept for the life of the process. Census settles at 3 and stays there | the same, since 2026-09-10. `OverlayWindow::Hide` takes the window off the screen and leaves the HWND, the hosted engine and its widget tree standing, which is what `../adr/2026-08-23-overlay-windows-as-secondary-flutter-engines.md` said all along — *created lazily … and reused for the process lifetime* |
| Preview texture | registered on show, **unregistered on hide** — a registered texture keeps its last uploaded contents, so re-showing drew the previous session's last camera frame until the new camera delivered | the same, and for the same reason. It used to belong to the window and go with it; now `Hide` calls `ReleasePreviewTexture` explicitly and clears the pixel buffer with it, because a retained window would otherwise have reintroduced exactly the stale-frame defect the macOS cell describes |
| Event monitors | drag-end and menu-dismissal `NSEvent` monitors, plus the rolling left-button watch | low-level mouse and keyboard hooks, installed for exactly as long as a menu is open |
| Session rows | read from `RecordingSession` through a lock-guarded ledger; the camera and microphone are asked directly (`isConfigured`) | read from each owner's own predicate — `CaptureEngine::is_running`, `MediaWriter::is_open`, `VideoCompositor::is_initialized` |
| Verified | `swift test` covers the arithmetic and the ledger; the plugin's three contributors are covered only through Dart against a fake | **nothing at runtime** — it compiles in CI and `windows/test` covers the census arithmetic, but no census has ever been taken from a running plugin |

Because `overlayEngines` is not zero after a cycle, §19.1's equality census is
taken **after the first cycle, not at launch**: a launch census is short by the
three engines the first session creates and every later one reuses. A launch
census still bounds every row of §19.1's *first* table, which must be zero on both
platforms in both places, and `resource_census_test.dart` asserts that separately.
That rule used to be a macOS rule with a Windows exemption; it is now simply the
rule.

**The counts used to differ, and this file used to say so.** Until 2026-09-10 the
Windows host destroyed each overlay window and its engine on hide, so
`overlayEngines` returned to 0 and `registeredTextures` went with it — read as a
lawful second reading of §19.1's second table, which permits either lifetime. What
made it not lawful was the ADR, which had specified the reuse from the start, and
what made it not free was the second Windows run: the control strip did not come
back for the second recording in a process, and a rebuilt engine per session is
the leading suspect. Two documents were still describing the old lifetime while
this was being written, and both were corrected in the same change set:
`../architecture/platform-channel-contract.md`, whose census section is what a
census assertion would be written from and which had recorded the two lifetimes as
a lawful choice; and `../adr/2026-09-08-pre-recording-countdown.md`, which said
Windows *needs no equivalent* of the countdown rewind because it keeps no
snapshot, and now carries an amendment saying it keeps one.

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
| Windows host handler | written, compiled in CI, never run |
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

The camera preview was the last panel still alternating, and was exempted from
the rule on purpose: its window frame *was* the tile rect, so holding it at a
high-water size would have drawn a tile that is not the tile in the file. It is
no longer exempt. The window is sized once to the bounding size of all three
presets (`CameraOverlayConfiguration.boundingTileSize`) and the tile is drawn as
a rectangle inside it, which the preview engine is told through
`cameraPreviewState`'s `content*` keys; `Camera → Square → Camera` is now three
moves and no resize.

| | Covered by |
|---|---|
| the shape key changes with every section that changes the height | `swift test` — `OverlayPlacementGeometryTests` |
| a remembered shape needs no resize | `swift test`, same file |
| the host's estimate matches what the sheet measures | `flutter test test/features/recorder/presentation/input_menu_size_test.dart` — it fails when a section is added to the sheet without a term in the estimate |
| one window size holds every camera preset, and where it goes | `swift test` — `CameraPreviewWindowGeometryTests` |
| the preview draws its tile at the rectangle it was given, and takes no press outside it | `flutter test test/features/recorder/presentation/camera_preview_window_test.dart` |
| a sheet placed for a size the panel is then held at still lands under the strip | `swift test` — `OverlayPlacementGeometryTests`, which walks `panelSizeAction → appliedSize → inputMenuFrame` and then re-applies the rule to the frame that produced |
| the panel is actually driven through one size | **nothing** |
| a press in the preview window's transparent surplus reaches the application underneath | **nothing** — see below |

The last two rows cannot be closed here. `swift test` links `RecorderCore`
against Foundation only; it cannot open an `NSPanel`, host a
`FlutterViewController` or reach the engine's surface cache. `flutter build
macos` compiles and does not run. The AppKit half of these windows — `place`,
`move`, `performDrag`, the mouse-up watch, the back-buffer cache — has no
automated coverage on this machine and should not be claimed to have any.

The surplus row is new with the fixed-size preview window and is worth stating
plainly. The panel is `isOpaque = false` over a `FlutterViewController` whose
`backgroundColor` is `.clear`, and macOS routes mouse events past fully
transparent parts of such a window — so a press in the surplus should reach
whatever is underneath. The Dart side no longer mounts any hit-testable widget
there, which is the half that *is* covered. Whether the window server actually
lets the press through has been verified by eye on neither this machine nor any
other; if it does not, the symptom is a rectangle beside the camera tile that
swallows clicks during a recording.

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

- **Windows is built, run twice, and defective.** It compiles and passes its
  native suite in CI (green since `d187db7`), and it has now been run twice on
  Windows 11: three recordings on 2026-09-08 and five on 2026-09-09. The first
  visit's files had a video track that stopped after eight or nine frames, a
  perforated microphone track, an upside-down camera tile and the main window in
  the picture; eight fixes answered those and the second visit cleared the two
  the log can see — `droppedFrames` 0 throughout, no `capture_error` line,
  `audioDiscontinuities` flat. The second visit found its own five, of which the
  worst were procedural rather than in the pipeline: nothing stopped a second
  launch, three Relays recorded at once and two of the three finalizations
  failed. Four of those five are fixed in this change set, and **none of it has
  been re-run there**. This bullet has been wrong twice before — it once said the
  work had never been pushed, and then that there had been "one session". See
  *The first Windows run*, *The second Windows run* and *Not verified*.
- **A `.part` is selected for recovery on its size alone, and discarding one is
  unguarded across processes.** `findIncompleteArtifacts`
  (`local_recording_store.dart`) takes every `.part` in the folder with a non-zero
  size — no ownership, no lock, no age — and `discardArtifact` deletes whatever
  path it is handed, so a scan can offer, and a press can delete, an artefact a
  live sink writer is still filling. That is the mechanism under *Why two
  finalizations failed*, and it is **untouched by this change set**: the
  single-instance mutex removes the one trigger anybody has observed — a second
  Relay launching while a first records — and leaves the selection rule and the
  delete exactly as they were. Trigger removal is not a fix, and the mutex is
  Windows-only: macOS takes none, and LaunchServices activating the running
  application is a convention about launching rather than a lock on the folder —
  `open -n`, or the executable inside the bundle, starts a second instance that
  scans the same directory. The guard belongs on the artefact — an exclusive open,
  an owning-process id or a minimum age — and none of the three is written.
  How far a delete would actually get on Windows against a file the writer holds
  open is itself unmeasured: the run's one `artifact_discarded` line is logged
  whether or not anything was deleted.
- ~~**`deviceId` on `startInputMetering` is not honoured by either platform.**~~
  **Closed.** Both hosts now take the id from the call — macOS at
  `RecorderMacosPlugin.startInputMetering` → `meter.start(kind:deviceId:)`,
  Windows at `meter_.Start(kind, StringAt(*arguments, "deviceId"))` — and a
  start naming a different device re-points the tap instead of opening a second
  one. Read off the source on both sides; measured on neither. The 2026-09-08
  recordings logged nothing about devices at all — and the sheet whose rows
  would not take a click (defect D) is a reason to doubt that any selection
  reached the platform — while the macOS half needs a second microphone to tell
  the two taps apart.
- **`getInputDevices` can fail on Windows**, where the contract says it always
  answers: an absent or unrecognised `kind` and a full COM worker queue are both
  rejections there and empty lists (or impossible) on macOS. `setCameraEnabled`
  joined it on 2026-09-09, for the queue half only: the contract gives that call
  a `null` reply and no rejection, and on Windows it now shares the same 16-deep
  worker. `../architecture/platform-channel-contract.md` documents the
  `getInputDevices` divergence and not yet this one.
- **`cameraPreviewMoved` is written on both hosts and exercised on one.** The
  application no longer pulls the tile's position back at teardown, so a host
  that does not raise this event stops remembering drags (§33.5). macOS raises
  it from `OverlayWindowController.onCameraPreviewMoved`; Windows raises it from
  `SetCameraMovedHandler`, four lines beside the compositor call that was
  already there — compiled in CI, read off the source, run nowhere.
- **The camera preview's window is larger than its tile on macOS only.** The
  fixed-size window and the `content*` keys it needs exist to remove a
  `Camera → Square → Camera` resize on a hosted `FlutterView`
  (flutter/flutter#185394). Windows sends none of the four keys and its preview
  window stays the tile: its overlay windows are a different mechanism —
  child-HWND ANGLE surfaces masked with `SetWindowRgn`, deliberately not layered
  — so it has no alternation to remove. The Dart reader defaults to *the window
  is the picture*, which is what Windows means.
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
