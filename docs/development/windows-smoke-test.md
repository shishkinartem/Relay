# Running Relay on Windows for the first time

Nobody has ever started this application on Windows. CI compiles it and runs its native unit
tests; neither tells you a recording comes out. This is the script for the first person to try,
written for a machine with **no development tools installed**.

Work through it in order and stop at the first step that fails — later steps assume the earlier
ones worked. Everything here is a thing that has never been observed, so a failure is
information, not a surprise.

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

## What to send back

The log, which holds the structured record of everything above:

```
%APPDATA%\com.relay.relay\relay.log
```

Paste that path into Explorer's address bar. Send the file, plus a note of which numbered step
first behaved differently from the description.

Settings live beside it in `settings.json`, and recordings in `%USERPROFILE%\Videos\Relay`.

## What this cannot tell us

Multi-monitor strip placement and DPI behaviour need a physical two-monitor machine. Anything
about a display that is not attached is untested either way. And a green run of this script does
not make the compatibility matrix's runtime rows verified — it makes exactly the rows it covers
verified, which is a different and much shorter list.
