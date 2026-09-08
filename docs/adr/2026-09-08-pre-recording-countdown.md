# A pre-recording countdown, drawn on the control strip

**Status:** Accepted
**Date:** 2026-09-08
**Amends:** `TECHNICAL_SPEC.md` §6, §10, §19, §29, §31.
**Constrained by:** `docs/adr/2026-08-31-overlay-panels-never-shrink.md` and
`docs/adr/2026-08-23-overlay-windows-as-secondary-flutter-engines.md`, neither of
which this reopens.

## Context

Start was immediate. There was no way to press Start, put the recorder's panel
away, arrange the screen and *then* begin — the first seconds of every recording
were the seconds spent getting out of the way of the recording.

Nothing in the repository had a countdown: not `TECHNICAL_SPEC.md`, not §30's
open decisions, not any ADR. It is new product scope.

Two constraints shaped every part of the answer:

**The strip must not change size.** §6: *"The strip must present the same size in
every session state, and it must be the compact one."* And
`2026-08-31-overlay-panels-never-shrink.md`: *"A panel's rendered size, in
physical pixels, is non-decreasing for the lifetime of its view, and never
returns to a value it has held before."* That ADR exists because the process
died twice — `SIGSEGV` inside `impeller::Canvas::SetupRenderPass()` — when a
panel hosting a Flutter view alternated sizes. A countdown that widened the strip
and narrowed it again is exactly the `A → B → A` it was written to prevent.

**There is no Dart-side clock.** The elapsed time is a `tick` event from the
native side. Nothing in `lib/` drives a periodic timer, and there was no seam a
test could substitute for one.

## Decision

**1. The countdown is drawn in the strip's existing clock slot, in the clock's
own format.** A three-second pre-roll draws `00:00:` dim and `03` inked, then
`02`, `01`, and then the strip is recording and the same eight cells read
`00:00:00`. It never renders `00`: reaching zero *is* `RecordingStarted`.

This satisfies the size rule **by construction** rather than by argument. The two
spans joined are exactly `formatClock`'s output — there is a test asserting that
for every second from 0 to 3600 — so the strip measures an identical `Size`,
macOS answers `hold`, and Windows is never asked to resize.

**2. Colour carries the state, because geometry is not available.** The ground
washes `accent200`, the frame goes `accent`, and the status dot is filled but
`accent` rather than `recordingIndicator` — whose own doc reserves it for the
live dot, and painting a pre-roll red asserts a recording that does not exist.
Two axes from one ramp: the frame says "no frames are being written", which
paused says too; the ground says "and none have been yet", which only the
pre-roll says.

**3. The same two squares, two meanings each.** Pause becomes `Start now`
(`AppIcons.record`, primary); Stop becomes `Cancel countdown`
(`AppIcons.close`). The mark changes because a stop square during a pre-roll
claims there is something to stop — cancelling leaves no file, stopping writes
one, and that difference outranks glyph constancy. **No new `OverlayCommand`**:
the branch is in the view model, so the enum on the wire is identical on both
platforms.

**4. The three input toggles and their chevrons stay drawn, and go inert.** This
is geometry, not taste. `_InputToggle` returns the bare toggle when its menu
callback is null, so nulling the callbacks would drop three carets and about 57
points of width. An `inert` flag disables them in place instead; `AppIconButton`
renders a disabled control at the same width and height, so the measurement is
byte-identical.

**5. A new sealed state, `SessionCountingDown` — not a flag on
`SessionActive`.** `SessionActive` already derives three phases from two
booleans, and it is what the overlay push and every strip command test for. A
pre-roll wearing that type would make Pause, Stop-as-stop and all three input
toggles live over a session that has not started.

**6. The wait sits between `setMainWindowVisible(false)` and
`_recorder.start()`.** The only point satisfying all three constraints at once:
the panel is already hidden, the strip is already up to draw the count, and
nothing is encoded — `startWriting` and the ticker are both inside the
platform's `start()`, so elapsed still begins at zero.

It is between two awaits and inside **neither** `.timeout`. A wait the user asked
for is not a platform call that stopped responding, and folding a ten-second
pre-roll into the eight-second `platformCallTimeout` would report a capture
failure for a countdown that worked.

**7. The seam is a function-typed field, `Future<void> Function(Duration)
_delay`.** Matching `_clock`'s precedent exactly. `test/architecture_test.dart`
scans `/application/` files for concrete-typed fields; a generic function type
does not match, which is why `_clock` passes today and why a
`final CountdownController _countdown;` would have tripped the gate.

**8. One wait per second, raced against a wake, not one wait for the whole
span.** The number has to change, and both exits have to be noticed between two
of them. Racing rather than awaiting means Cancel and `Start now` answer on the
press instead of at the next second boundary — up to a full second of a dead
control on a floating window over someone else's work reads as a crash.

**9. Cancel is its own event, not a stop and not a failure.** `StopRequested`
means "write the file out"; there is nothing to write. `CaptureFailed` routes to
the capture-failure screen, which would put an error in front of someone who
simply changed their mind. `CountdownCancelled` goes to `SessionIdle`, and
`_beginRecording`'s existing `finally` restores the panel and removes the
overlays — persisting the strip position and the camera tile exactly as an
ordinary end does. It also aborts *then* releases, sequenced, because Windows
refuses a release while it still considers the session live.

**10. Default off, with `Off / 3s / 5s / 10s` in the launch screen's Advanced
section.** Start has always been immediate, and a recorder that waits when nobody
asked it to is a recorder that missed the thing you were pointing at. Off also
keeps the camera light from burning for the extra seconds — macOS opens the
camera at `prepare`, which is before the count begins — and it is what keeps
every existing `requestStart()` test asserting the shipped sequence.

## Consequences

**The payload gains one key both hosts forward untouched.** `countdownMs` on the
strip's state map. Both hosts pass the map through without reading a key, and
`fromMap` defaults an absent key to null, so the wire is compatible in both
directions.

**`countdownRemaining` must be in `==` and `hashCode`, and that is the single
most fragile line here.** `OverlayPresenter.push` drops a snapshot equal to the
last one, and during a pre-roll every other field is identical between ticks —
`elapsed` is zero throughout. Omitted, the strip renders the first number and
never changes, with no error anywhere. There is a contract test asserting two
states differing only in the countdown are unequal.

**The strip is pushed twice around `showControlStrip`, and both are load-bearing.**
macOS replays its last snapshot before the panel is placed and rewinds only the
recording fields on hide, so without a push *before* the show the strip opens
claiming to be recording — red dot, `00:00:00` — for the whole pre-roll. Windows
destroys the strip window on hide and keeps no snapshot, so only the push
*after* the show lands there. `OverlayPresenter.showControlStrip` now clears its
dedupe, or the second push would be swallowed as "no change".

**One macOS-only native line.** `hideControlStrip` must `removeValue(forKey:
"countdownMs")` — removed rather than nulled, since `[String: Any]` cannot hold
nil and an `NSNull` would decode as a *present* value and open the next
session's strip mid-countdown. It sits outside `RecorderCore`, so it has no unit
coverage and cannot have any; **check it by hand with two sessions back to
back**, the second with the countdown off.

**Windows needs no equivalent** — `HideControlStrip` destroys the window and
keeps no snapshot.

**The camera preview is up during the pre-roll, and had to be.** Windows applies
`WDA_EXCLUDEFROMCAPTURE` over its excluded set once, at `Start`; a preview
created after that is never in the set and would be composited into the file. So
it must exist before `start()`, which means it exists during the count whether or
not we want it there. It is also the right answer: macOS has already opened the
camera at `prepare`, so the light is on regardless, and framing the tile is part
of what these seconds are for.

**A new sealed subclass is a compile error in two exhaustive switches** — the
machine's dispatch and the app's screen router — until both arms exist. That is
the safety net working.

## Alternatives considered

**A fourth overlay window showing a large numeral.** Rejected. It needs a fourth
Flutter engine, a fourth entrypoint, roughly 150 lines of Swift and 150 of C++, a
new model, a new client stream and a new contract section — on a Windows plugin
that compiles and passes its unit tests and **has still never been run**. That is
the "expensive to reverse" scope `CLAUDE.md`'s change discipline says not to take
without cause, for a three-second wait.

**A `Stack` with an `Opacity(0)` clock behind the numeral.** Rejected. It
preserves width only because a zero-opacity widget is still laid out — one
refactor away from a strip that changes size, and a size change there can kill
the process.

**A native `Recorder.startAfter(Duration)`.** Rejected: two implementations, two
cancellation paths racing `abort`, and a new event type, for a delay that has no
reason to leave Dart. `CLAUDE.md`'s "high-throughput raw media stays native" does
not reach a three-second wait.

**Escape to cancel.** Rejected: the strip is a non-activating panel, so Escape
only reaches it once it has been clicked. Promising a key that usually does
nothing is worse than not offering one.

**Counting on the Start button instead.** Rejected: the main window is hidden
during the pre-roll, which is the point of it.

## Verification

- `./tool/validate.sh` — format, analyze, and every Dart/Flutter suite.
- The size rule is asserted twice, and both are release gates: the strip
  measures the same `Size` at 10, 3 and 1 seconds as it does recording
  (`design_system_test.dart`), and the strip window reports the same
  `contentSize` with all three carets still in the tree
  (`control_strip_window_test.dart`).
- `splitClock(d).head + splitClock(d).seconds == formatClock(d)` for every
  second from 0 to 3600.
- Machine coverage for every transition and every rejection out of
  `countingDown`, including that `SessionReset` stays rejected.
- View-model coverage for the ordering, both pushes around the show, a
  ten-second pre-roll not tripping the platform timeout, cancel reaching
  `abort` then `releaseSession` and ending in `idle` rather than `failed`, a
  cancelled pre-roll offering nothing to recover, a double Cancel aborting once,
  and `Start now`.
- **NOT RUN:** the macOS `hideControlStrip` rewind — `OverlayWindows` sits
  outside `RecorderCore`, so `swift test` cannot reach it. Verify by hand with
  two consecutive sessions.
- **NOT RUN:** the Windows native suite, and any Windows runtime behaviour.
- **NOT RUN:** `flutter test test/tools/render_screens_test.dart --run-skipped`
  — the design-review renders were not regenerated, and the countdown has no
  drawn state on the canvas.
