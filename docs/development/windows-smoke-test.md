# Running Relay on Windows for the first time

This was written before anybody had started the application on Windows, as the script for the
first person to try, on a machine with **no development tools installed**. It has since been run
three times — 2026-09-08, 2026-09-09 and, reported on 2026-09-24, a third time — and each visit
added the lettered checks further down for the fixes it prompted. CI compiles the application and
runs its native unit tests; neither tells you a recording comes out, which is why this script
still exists.

Work through it in order and stop at the first step that fails — later steps assume the earlier
ones worked. A failure is information, not a surprise.

## Before you start

Install the **Microsoft Visual C++ 2015–2022 Redistributable (x64)** from Microsoft. This is not
optional: `relay.exe` and every plugin DLL link against `vcruntime140.dll`,
`vcruntime140_1.dll` and `msvcp140.dll`, and nothing in the build ships them. Without it the app
does not start — you get a missing-DLL dialog, which looks like Relay being broken.

On Windows **N** or **KN** editions, also install the **Media Feature Pack**. The recorder links
Media Foundation as an import, so without it the process fails to start rather than degrading.

You need Windows 10 build 19041 (2004) or newer, x64. The plugin checks that number itself and
refuses to run below it.

## Getting the build

1. Open the repository's **Actions** tab on GitHub and pick the newest green run of **CI**.
2. Scroll to **Artifacts** and download **`relay-windows-x64`**. You must be signed in to
   GitHub — artifacts are not served anonymously. They expire after 14 days.
3. Unzip it anywhere. Keep the folder together: `relay.exe` is a launcher and needs its
   neighbours (`flutter_windows.dll`, the plugin DLLs, `data\`). Moving the `.exe` out on its own
   will not work.
4. Run `relay.exe`. SmartScreen will object to an unknown publisher — **More info** → **Run
   anyway**. The project configures no Authenticode certificate.

## The script

Each step says what to do and what should happen. Note anything that differs, however small.

### 1. It starts

The window opens at 420 × 560 on the **Recorder** screen: a source row, Quality, Frame rate,
three input rows, Advanced, a destination row, and **Start recording**.

*If it does not start at all, the redistributable above is the first thing to suspect.*

### 2. The source list is right

Press **Change**. Expect **displays first, then windows** — that ordering is part of the
contract, not a preference.

Check the size shown beside each display against Windows' own **Settings → System → Display →
Display resolution**. They must match. Relay reports physical pixels; if it shows something
smaller, it is reporting a scaled size and the recording will be soft.

### 3. Quality defaults to Native

On the Recorder screen, **Native** should be selected, and the line under Start should read
`~ N GB / hour at these settings` with a number that matches the display you picked — roughly
7 GB/hour for a 4K screen at 30 fps, roughly 2 GB/hour for 1080p.

### 4. A plain recording

Turn the camera **Off** and leave Countdown at **Off** for this first pass, so only one thing is
new at a time. Press **Start recording**.

- The Relay window disappears.
- **The control strip appears** — a small always-on-top bar with a red dot, a clock, three input
  toggles and two squares. This has never been seen on Windows; if there is no strip, stop here
  and say so, because there is then no way to stop the recording except Task Manager.
- The clock counts up.
- Press the strip's last square (**Stop**).
- The window returns on the **Ready** screen, showing the file name, its length, resolution and
  size, and a row reading **ON THIS COMPUTER** with a folder path.

Press **Open folder**. Explorer should open `%USERPROFILE%\Videos\Relay`. Play the file. Check:
it plays, the picture is the screen you chose, and **text in it is sharp** — that is the whole
point of the Native default.

### 5. The strip's controls

Record again. This time, while recording:

- Press each of the three input toggles and watch them change state.
- Press the chevron beside the microphone. A device list should open **below the strip**, not
  inside it.
- Press the pause square, then again to resume. The clock must stop and continue, and **no
  control may move** while it does.
- Drag the strip by its background to another part of the screen, then stop and start a new
  recording — it should come back where you left it.

### 6. The countdown

Set **Advanced → Countdown → 3s**. Press Start.

The strip should appear counting `00:00:03`, `00:00:02`, `00:00:01`, tinted, with its last two
squares reading *Start now* and *Cancel countdown*. Recording begins at zero.

Do it again and press **Cancel countdown** midway. Expect: the Relay window comes back, no file
is produced, and nothing is offered for recovery. **Then quit and start Relay again** — if it
offers to repair an unfinished recording, that is a known-suspected defect
(`docs/development/compatibility-matrix.md`) and worth reporting.

### 7. The camera

Turn the camera **On** and record a display. A captioned **Camera preview** box should appear.
Stop, and check the finished file: the camera should be composited into the picture, in the
lower right by default.

Then record a **window** instead of a display, camera still on. The preview box appears
elsewhere on screen — check there is no blank slab of background around it.

### 8. Sending

Connect a destination in **Settings** (Telegram or WebDAV) and press **Send** on a short
recording. Watch the progress, and check the file arrives.

Then turn **Keep a copy on this computer** on, send again, and confirm the local file survives.

## Checking the 2026-09-09 fixes

The first Windows run, on 2026-09-08, produced a file with about nine frames of video, a microphone track that
scraped continuously, an upside-down camera tile, a sheet whose rows mostly would not take a
click, a main window that never left the screen, and the Flutter logo for an icon. Eight fixes
went in for that; `docs/development/compatibility-matrix.md` records what each one was.

Run the numbered script above first — it is what catches a fix that broke something else. Then
run these, which are aimed at the specific defects. Each says what to do, what a fix looks like,
and the line in the log that settles it either way, so a disagreement between what you saw and
what the log says is itself worth reporting.

The log gained fields for exactly this. A `recorder_stats` line now reads:

```
recorder_stats capturedFrames=… encodedFrames=… droppedFrames=… audioDiscontinuities=… avDriftMs=… encoder=… hardwareEncoding=…
```

`capturedFrames` and `audioDiscontinuities` are new, and so is the `capture_error` line — the
application used to discard every non-fatal platform error without a word.

### A. The encoder no longer stops when the camera starts

**The one that matters.** Camera **On**, microphone **On**, system audio **On**, record a
display for about thirty seconds, moving a window around so the screen is genuinely changing.
Stop, and play the file.

- **Fixed:** the video runs the whole thirty seconds, not a third of a second. In the log,
  `encodedFrames` climbs by roughly the frame rate every second, and `avDriftMs` stays small —
  tens of milliseconds, wandering either way.
- **Not fixed:** `encodedFrames` stops at some small number and never moves again while
  `droppedFrames` climbs, and `avDriftMs` falls by almost exactly 1000 every second. That is the
  original defect unchanged.
- **Partly fixed:** `encodedFrames` climbs *and* there is a
  `capture_error code=cameraUnavailable … could not be drawn into the recording` line. The video
  track was rescued but the tile still cannot be bound — send that line, it names the reason.

Then repeat the whole thing with the camera **Off**. Video must be healthy either way; if it is
healthy only without the camera, the fix did not take.

### B. The camera is the right way up

With the camera on, look at the **Camera preview** box, then at the finished file.

- **Fixed:** you are upright in both.
- **Not fixed:** upside down in both — the preview and the file share one pixel path, so they
  agree or something else is wrong. If they *disagree*, say so explicitly; that is a different
  defect from the one that was fixed.

A rectangular panel with a circular picture inside it and a `Camera preview` caption is **not** a
bug — that is the window-mode preview by design (design `1e`). Only the orientation is under test.

### C. The microphone does not scrape

Record thirty seconds while talking, with system audio on and something playing. Listen to the
file on headphones.

- **Fixed:** speech, with no continuous buzz or crackle underneath it.
- **Not fixed:** a rasp or click running through the whole track. Check `audioDiscontinuities` in
  the log: it should be zero or nearly zero across the session. A number climbing steadily is the
  ring buffer still being punched full of holes, and it is the measurement that tells us whether
  to look at the drain or at the endpoint.

Also record with **system audio off, microphone on**, and then with **microphone off, system
audio on**. Each alone must still produce sound: the drain now waits for the slowest source, and
a source that is switched off must not be waited for at all. A track that is silent or stalls in
one of these two is a regression, not the old bug.

### D. Rows in the strip's sheet take a click

While recording, press the chevron beside the **camera**. In the sheet:

- press a **shape preset** — Camera, Square, Circle. The tile must change shape, and the sheet
  behave the same way each time.
- press each **device row**, and the **Off** row.
- press the sheet's **surplus** — the empty area below the last row, if there is any. That, and
  only that, should close the sheet.

**Fixed:** every row does what it says on the first press. **Not fixed:** a press closes the
sheet without applying anything, and which rows work seems random — that is the original defect.

### E. The main window leaves the screen while recording

Start a recording and look at the desktop.

- **Fixed:** the Relay window is gone — not blank, not frozen, gone — and comes back on the
  **Ready** screen when you stop.
- **Not fixed:** it stays on screen showing `PREPARING / Getting ready to record.` while the
  strip counts up. That is the frozen frame of a window that was never hidden.

Also check the taskbar: Relay's button should still be there while the window is hidden.

### F. The controls feel responsive

Subjective, but the comparison is the point. While recording with the camera on, toggle the
camera off and on a few times, and press Pause/Resume.

- **Fixed:** each press acts immediately, and nothing else on screen freezes while it does.
- **Not fixed:** a visible hitch of a few hundred milliseconds, especially when turning the
  camera **off** — that is the capture thread being joined on the UI thread, and it should no
  longer happen there.

### G. The icon is Relay's

Look at the taskbar button, **Alt+Tab**, the window's own title bar, and `relay.exe` in Explorer
(switch Explorer to **Large icons** as well as **Details**).

**Fixed:** the Relay mark — a blue rounded square with a white record frame — at every size.
**Not fixed:** the Flutter logo anywhere, or a blurry or clipped mark at one particular size. Say
which size and which place; the sizes come from different entries in the icon file.

### H. The header has no dead gap, and recovery does not hijack the screen

On the **Recorder** screen, look at the top-left of the panel, under Windows' own title bar. The
word **Recorder** should sit near the left edge with a normal small margin — not pushed inward by
a wide empty strip, which is the room macOS needs for its window buttons and Windows does not.

Then: force-quit Relay mid-recording (**Task Manager → End task**) and start it again. It should
offer to repair the unfinished recording **at launch**, and once you dismiss or repair it, that
offer must not come back over a later recording or over the Ready screen.

## Checking the 2026-09-10 fixes

The second Windows run, on 2026-09-09, recorded video and audio cleanly — that part is done. What
it exposed instead was three ways to end up with no way back to the application: a second copy of
Relay could be launched over the first, Relay left the taskbar entirely while recording, and the
control strip did not come back for a second recording in the same process. These three checks are
aimed at those.

Reading the log for them needs one thing said first: **`relay.log` is a single file appended across
every run.** It is not truncated at launch. Find the *last* line reading

```
environment_loaded source=… keys=…
```

and read from there down; everything above it is an earlier session. That line, with
`settings_loaded` and `platform_registered` immediately after it, is what one launch of Relay looks
like in the log, and checks I and K both turn on counting them.

One line is new since the last build, written once where each session is prepared:

```
session_source recordingId=… sourceType=… sourceId=… pixelWidth=… pixelHeight=… microphone=… camera=… systemAudio=…
```

The previous log could not say what a session had recorded — display or window, which one, how big
— or which inputs were live for it, and both facts had to be asked for by hand while triaging.

### I. Only one Relay runs at a time

With Relay already open, go back to the unzipped folder and run `relay.exe` again. Then try it once
more from a shortcut or the taskbar, if you made one.

- **Fixed:** no second window appears. The copy already running comes to the front, and if it was
  minimized it restores.
- **Not fixed:** a second Relay window opens beside the first. Two processes then share one
  `settings.json`, one log file and one recordings folder, and the last one to write wins — which
  is a defect that produces confusing results everywhere else in this script, so stop here.

**The line that settles it:** the launch triple above. Count the `environment_loaded` /
`settings_loaded` / `platform_registered` blocks in the log — there must be exactly one per launch
you *meant*. A second block seconds after the first, with no crash and no relaunch between them, is
a second process however the screen looked.

### J. Relay keeps its taskbar button while recording

Start a recording and look at the taskbar, not the desktop. This is the second half of check E: E
asks whether the window leaves the screen, this one asks whether the application leaves with it.

- **Fixed:** the Relay window is off the screen, and Relay is still listed in the taskbar. It now
  minimizes rather than hides, so the button stays put for the whole recording. Leave it alone
  while recording — you are only checking that it is there.
- **Not fixed:** no Relay button anywhere in the taskbar between Start and Stop. That is the state
  that makes a missing control strip unrecoverable: with no strip and no taskbar button, Task
  Manager is the only way to end the recording, and the file is lost with it.

**The line that settles it:** none — nothing in the log observes the taskbar, and this one is
decided by your eyes. `session_phase from=preparing to=recording` dates the moment the window left
the screen, so if the button disappeared at some *other* moment, say which.

### K. The strip comes back for the second recording

Record for ten seconds and stop. Then, **without quitting Relay**, record again. Then a third time.
The strip's engine used to be destroyed and rebuilt for every session, which is the leading suspect
for the strip being invisible on the second recording in a process.

- **Fixed:** the strip appears every time, where you left it, with the clock starting from zero.
  Its toggles and its Stop square work on the third recording exactly as on the first.
- **Not fixed:** the first recording shows the strip and a later one does not — you are recording
  with nothing on screen to stop it. Say which attempt was the first to go dark, and whether
  quitting and relaunching Relay makes the strip come back for one more recording.
- **Partly fixed:** the strip appears but arrives blank, frozen, or still showing the previous
  session's clock. That is the same window with a stale engine rather than a missing one, and it is
  worth reporting as a different thing.

**The line that settles it:** `session_source`. One per session, so two of them under a single
launch triple is proof that both recordings ran in the same process, which is the case under
test; if a crash restarted Relay in between there is a second launch triple, and the check did
not actually run. With the strip missing, a `session_phase from=preparing to=recording` that
arrives anyway means the session is healthy and only the window is not showing, whereas
`strip_command_timed_out` or `strip_command_failed` means the host stopped answering, which is a
different fault.

## Checking the 2026-09-24 fixes

The third run reported the build as much better, and four things with it. Two had causes that
could be read off the source and are fixed; the other two could not, and the checks for them ask
for what would settle them rather than for a verdict.

### L. The source list shows pictures

Press **Change** on the Recorder screen.

- **Fixed:** every display and every window has a small picture of itself above its name.
- **Not fixed:** the picture area is an empty frame — no hatching, no picture. The thumbnails were
  being produced all along; GDI leaves the alpha byte of every pixel at 0, the PNG kept it, and a
  PNG whose alpha is 0 is drawn as fully transparent.
- **Partly fixed:** displays have pictures and some windows do not. That is expected for a window
  that refuses to paint itself into a bitmap, and the list is allowed to show those without one —
  say which applications.

### M. The camera moves over a still window

Turn the camera **On**, pick a **window** as the source — one you will not touch, a document or
a settings page — and record for twenty seconds while moving your head and hands. Keep the mouse
off that window. Then play the file.

- **Fixed:** the camera tile moves as smoothly in the file as it did in the preview, the whole
  time.
- **Not fixed:** the tile stands still, or jumps only when something in the window changes — the
  cursor passing over it, a caret blinking. That was the cause: for a window, Windows delivers a
  frame only when the window's content changes, and the recorder held the whole last picture —
  camera tile included — rather than just the window.

Then, still over the still window, turn the camera **off** mid-recording: the tile must leave the
file at that moment, not at the next change in the window.

### N. The controls in the first seconds

Not fixed — this one needs measuring first. The report was that the controls lag at first and
then seem to warm up. Two causes fit that and the log can tell them apart, so note:

- **which controls**: the control strip during a recording, the main window, or the camera sheet;
- **when**: right after launch, during the countdown, in the first seconds of the *first*
  recording only, or of every recording;
- **how**: a single freeze of a second or so, or several seconds of everything feeling sluggish.

A single freeze at the moment the countdown ends, on every recording, points at `start`: it runs
on the one Win32 thread that takes the input for every Relay window, and it opens the camera and
both audio endpoints there before it returns. Sluggishness on the first recording only, gone by the second, points at
the strip's and the preview's own Flutter engines, which are created on their first show and then
kept for the life of the process. The first is a code change with a known shape; the second needs
the timing before anything is worth changing.

### O. A window recording's size

Record a window with Quality on **Native**, then compare the file's resolution (Explorer →
right-click → **Properties → Details**) with that session's `session_source` line.

- **Expected:** the file is exactly `pixelWidth × pixelHeight` — the window's own pixels, not
  stretched to the screen and not scaled up. A small window makes a small video, which a player
  may then blow up to fill its own window; that is the player.
- **Also expected:** if the window changes size *during* the recording, the picture is fitted into
  the size it had at the start, with black bars and scaled to fit. The output never changes size
  mid-file.

The third run reported that a Telegram window "did not swell" when recorded and a File Explorer
window did. What "swelled" means is not yet known, and it may be either expectation above. A
screenshot of each file playing, and the two `session_source` lines, would settle it.

## What to send back

The log, which holds the structured record of everything above:

```
%APPDATA%\com.relay\relay\relay.log
```

**Two folders, not one.** `com.relay` and `relay` are separate directories: Windows builds the
path by joining the executable's `CompanyName` and `ProductName`, which are `com.relay` and
`relay` (`windows/runner/Runner.rc`). It is not the macOS-style `com.relay.relay`.

To get there: press **Win + R**, paste the line above, press Enter — that opens the log in
whatever handles `.log` (Notepad, usually). To open the *folder* instead, paste
`%APPDATA%\com.relay\relay` into Explorer's address bar, or into Win + R. Explorer expands
`%APPDATA%` for you; you never need to know your own user name.

If the folder does not exist, Relay has not started successfully even once — that is itself the
finding, and it points at the redistributable in *Before you start*.

Send the file, plus a note of which numbered step — or which lettered check — first behaved
differently from the description.

Send it even when everything looked right. `recorder_stats` and `capture_error` now carry the
numbers that separate "the recording worked" from "the recording worked this time": a fault that
degrades instead of failing is one the log reports and the screen does not. `session_source` says
what each of those recordings was actually of, which is what makes the rest of the log readable
weeks later.

`settings.json` sits in the same folder. Recordings go to `%USERPROFILE%\Videos\Relay`, which
Explorer also reaches as **Videos → Relay** in the sidebar.

## What this cannot tell us

Multi-monitor strip placement and DPI behaviour need a physical two-monitor machine. Anything
about a display that is not attached is untested either way. And a green run of this script does
not make the compatibility matrix's runtime rows verified — it makes exactly the rows it covers
verified, which is a different and much shorter list.
