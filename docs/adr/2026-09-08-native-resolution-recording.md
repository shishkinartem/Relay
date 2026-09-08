# Native-resolution recording, and one bitrate rule for both platforms

**Status:** Accepted
**Date:** 2026-09-08
**Amends:** `TECHNICAL_SPEC.md` §10 (resolution setting, output dimensions), §12
(capacity planning), §29, §31, and `CLAUDE.md`'s "Quality: 720p / 1080p"
invariant.

## Context

Recordings made on this machine looked soft, and text worst of all. Three
independent causes were stacked, and only the third is a matter of taste.

**1. macOS reported points as pixels.** `SCDisplay.width`/`height` and
`SCWindow.frame` are documented in the ScreenCaptureKit headers as **points**.
`CaptureSourceEnumerator` sent them as `pixelWidth`/`pixelHeight` — a channel key
the contract document defines as pixels, that Windows already filled with
physical pixels, and that the recorder sizes its canvas from.

On a 14-inch MacBook the panel is 1512 × 982 points over a 3024 × 1964 backing
store. The canvas rule fits the source into the preset box and never upscales, so:

| preset | canvas | fraction of the panel's real pixels |
|---|---|---|
| 720p | 1108 × 720 | 13.4 % |
| 1080p | 1512 × 982 | 25.0 % |

**"1080p" was 982 lines.** The clamp at `min(scale, 1.0)` meant the 1080p box was
never reached, so the preset silently resolved to the point grid — a 2:1
downsample of the backing store, performed by ScreenCaptureKit before anything
that understands glyphs saw the frame. macOS renders text hinted for the 2×
grid; halving it turns stems and hairlines into grey.

**2. The 1080p preset silently drew the 720p bitrate.** `videoBitrate` stepped on
`height >= 1000`. The canvas above is 982 — eighteen lines short — so a canvas
with 1.61× the pixels of 720p was encoded at 720p's 1.8 Mbps. In bits per pixel
per frame: 0.0651 at 720p, 0.0643 at 1080p, **0.0404** at the Retina canvas. A
38 % deficit, which reads as quantization mush on exactly the high-contrast text
edges the downsample had already damaged.

**3. The two platforms disagreed about bitrate by 2.5×.** Windows used 0.10 bits
per pixel with a `sqrt` frame-rate law; macOS used a two-value step function. The
same canvas encoded at 4.45 Mbps on Windows and 1.80 Mbps on macOS.

There was also no preset that could express "record what the display actually
shows". Every preset is a bounding box, and a bounding box is the wrong
instrument for a display denser than its point grid.

## Decision

**1. Source dimensions on the channel are backing-store pixels on both
platforms.** macOS converts: `CGDisplayModeGetPixelWidth`/`Height` for displays,
the holding screen's `backingScaleFactor` for windows. This alone makes 1080p
mean 1080p on a Retina Mac, and it is a contract fix rather than a feature —
macOS was the side violating a documented key.

**2. A third quality preset, `native`, which is the default for a fresh
install.** Its canvas is the source's own pixels, scaled by nothing. It crosses
the channel as `targetHeight: 0` — the sentinel for "no bounding box" — because
both hosts decode `quality` as an opaque string and size the canvas from the
number. Both hosts answer `0` explicitly; falling through to the box arithmetic
would compute a 0 × 0 box and clamp it to a 2 × 2 canvas.

**3. Native is capped at 3840 × 2160 pixels.** An encodability limit, not a
quality judgement: H.264 caps frame size in macroblocks, and a 5K panel's
5120 × 2880 needs a level above 5.2 that little hardware accepts. Past the cap
the canvas is scaled down proportionally — never cropped, never distorted — so
"native" stays honest on every display that can be encoded and degrades to
something playable on the ones that cannot, instead of failing `prepare` with an
encoder error nobody can act on.

**4. One bitrate rule, on both platforms:**

```text
bitrate = clamp(0.0645 × width × height × fps, 1.5 Mbps, 40 Mbps)
```

`0.0645` bits per pixel per frame is not a new number — it is what the shipped
step function already was, written as a rule instead of a staircase. It
reproduces both published anchors to under one percent (1280 × 720 at 30 fps →
1.783 Mbps against 1.800; 1920 × 1080 at 30 fps → 4.012 against 4.000), so §12's
table stays accurate and no existing recording profile moves perceptibly. Linear
in frame rate, which is the law §12's own table uses (4 → 8 → 16 Mbps across
30 → 60 → 120). The formula now lives in `RecorderCore` (Swift) and
`recorder_types.cpp` (C++) so both native suites execute it; on Windows it was
previously in `media_writer.cpp`, which no test target builds.

**5. A stored preset is never promoted.** `quality` is written on every save, so a
document holding `hd720` cannot be told apart from one nobody ever touched.
Migration `v3 → v4` is a deliberate no-op.

**6. The size estimate is taken from the canvas, not the preset.**
`RecordingSizeEstimator` used to be a function of `(quality, frameRate)`. Native's
bitrate is a function of the selected source's pixel count, which is not known
until a source is picked, so the signature had to change.

## Consequences

**Files get much larger, and that is the point.** On a 14-inch MacBook at 30 fps,
native is 3024 × 1964 at 11.49 Mbps ≈ **5.3 GB/hour**, against 0.85 GB/hour at
today's real 720p — about 6×.

**§16's Telegram ceiling becomes sharp.** 50 MB is roughly 35 seconds of native
recording. This is why item 6 above was not optional polish: guessing the preset's
number would have understated a native recording about six-fold on the one line
the user reads before pressing Start, and it is the number the size limit is
judged against. With no source selected the line is now absent rather than
confidently wrong.

**Memory rises with the canvas.** `queueDepth = 6` at 32BGRA is 4 bytes/pixel:
≈ 36 MB at 1512 × 982, ≈ 143 MB at 3024 × 1964, ≈ 199 MB at 4K.

**Software encoding at native 60 fps is a risk.** macOS is protected by
`AVVideoProfileLevelH264HighAutoLevel` picking a level; Windows sets
`eAVEncH264VProfile_High` with no level and lets the MFT choose, so 4K acceptance
is per-adapter. A software encoder at 3024 × 1964 at 60 fps will not keep up on
most machines; the bounded queue drops the newest frame rather than stalling, so
the failure mode is a stuttery file, not a crash. **Not measured on real
hardware** — recorded in `docs/development/compatibility-matrix.md`.

**Fragmented MP4 is unaffected in duration, larger in bytes.**
`docs/adr/2026-08-23-fragmented-mp4-on-both-platforms.md` fixes the interval at
2 seconds, so a crash still costs at most one fragment — about 2.9 MB at native
instead of 1.0 MB. Its "well under one percent" overhead claim gets safer, not
riskier, because fragment headers are roughly independent of bitrate.

**Windows output changes.** 1080p30 moves from 6.22 Mbps to 4.01. That is the
cost of the two platforms agreeing, and 4.01 is the number §12 publishes.

## Alternatives considered

**Add `sourcePixelWidth`/`sourcePixelHeight` as new channel keys and leave
`sourceWidth`/`Height` as points.** Rejected: a larger contract change on both
plugins and in the documentation, and it would leave a key named `pixelWidth`
permanently holding points.

**Keep the step function and raise its threshold.** Rejected: it cannot price a
native canvas at all, because the size is not known until `prepare`, and any step
mis-prices whatever lands just under it — which is the defect that produced cause
2 above.

**Move macOS up to Windows' 0.10 bits per pixel instead of the reverse.**
Rejected: it changes the 720p and 1080p files on macOS *and* leaves §12's table
describing neither platform.

**Promote existing `720p` users to native.** Rejected: it would multiply their
files several-fold without being asked, and §16's ceiling makes that a
consequence rather than a detail.

## Verification

- `swift test` — 236 tests, including the native canvas, the encoder cap, the
  degenerate-source fallback and the bitrate anchors.
- `./tool/validate.sh` — format, analyze, and every Dart/Flutter suite.
- **NOT RUN:** the Windows native suite (cmake + ctest) and any Windows runtime
  behaviour. The C++ changes here — `ResolveCanvasSize`'s native branch and the
  new `RecommendedVideoBitrate` — have tests written and never executed. See
  `docs/development/compatibility-matrix.md`.
- **NOT RUN:** real capture at native resolution against this host, so the
  encoder-throughput risk above is reasoned, not measured.
