# Overlay panels never shrink

**Status:** Accepted
**Date:** 2026-08-31
**Amends:** `2026-08-24-overlay-panels-are-sized-once-per-show.md`

## Context

The 2026-08-24 ADR decided that **an overlay panel is driven through exactly one
size per show, and is never resized while it is off screen.** That rule was
implemented, shipped, and the user crashed again with the identical signature —
`SIGSEGV` at `0x0` inside `impeller::Canvas::SetupRenderPass()` on an
`io.flutter.raster` thread (flutter/flutter#185394).

Commit `b434e9f` replaced the rule. That commit's message carries the analysis;
this ADR exists because the decision it made has been the live one since, while
the ADR of record still states the superseded rule and `CLAUDE.md` forbids
narrowing an ADR in passing. Nothing here is new work — it is the write-up owed
for a decision already taken.

**Which engine died.** Thread ids are allocated monotonically and no engine is
ever torn down, so their order is fixed for the process. Both crash reports show
four `io.flutter.raster` threads and both fault on the fourth. Engines two and
three are created within ten ids of each other — the control strip and the
camera preview, at session start — while the fourth is created far later, and
only one engine is created lazily by a human gesture: the input menu, on the
first chevron pressed. Both crashes were on the input menu's engine.

**Why one-size-per-show was insufficient.** Two reasons, both structural:

- The size ledger it relied on was keyed at `showInputMenu` and never
  recomputed. Every sheet changes shape in place — shown loading, then loaded,
  then metered — so the loaded height was filed under the loading key.
- Even keyed correctly it could not close the class. One panel hosts three
  structurally different sheets, so microphone → camera → microphone is
  `A → B → A` on a **live** panel, which "one size per show" says nothing about.
  The ledger made the alternation sharper, not safer.

The 2026-08-24 rule was about a panel's size *within a show*. The fault is about
a panel's size across its whole life.

## Decision

> **A panel's rendered size, in physical pixels, is non-decreasing for the
> lifetime of its view, and never returns to a value it has held before.**

`OverlayPlacementGeometry.panelSizeAction` is the single implementation, and
`PanelSizeAction` its four answers: `move` (size unchanged), `grow` (larger than
anything rendered, applied as asked), `hold` (a shrink or a size seen before —
the frame is applied at the high-water size), and `rebuild` (the backing scale
changed, so the pixel history no longer applies).

**Why non-decreasing is sufficient.** A wrong-sized surface needs the cache head
to equal the request *and* a younger entry to differ. `FlutterBackBufferCache`
decides whether to purge by comparing the request against `_surfaces.firstObject`
— the *oldest* entry — and then hands back the *youngest* free surface with no
size check at all. Entries are appended in render order, so a younger entry
rendered under a non-decreasing sequence is at least as large as the head; if it
differs, it is larger, which means a larger render already happened and this
request is a shrink. Under the rule there are no shrinks, so the state is
unreachable.

**Pixels, not points.** The cache is keyed by the surface's pixel size, so a
panel crossing to a display with a different backing scale changes size without
changing a single point. That is the honest limit: closed for sizes we choose,
only reported for sizes the system imposes — which is what `rebuild` is.

**Every path that can resize a panel goes through one `apply`.** Two were absent
from every previous enumeration: `move`, which is a move in points and a resize
in pixels across a scale boundary, and `settlePreviewAfterMove`, which
recomputes a rectangle rather than preserving a size.

### The camera preview is exempt

In display mode the preview's window frame **is** the tile rect —
`compositedTileFrame()` returns exactly the rectangle the compositor draws into.
Holding it at a high-water size would draw a tile that is not the tile in the
file, which is the disagreement design `1p` exists to forbid (§7). The preview
therefore keeps resizing, and keeps the crash risk that comes with it
(`0b688d2`).

That is a stated trade, not an oversight. Neither crash was on this engine —
both were on the input menu's, which the rule does protect. The proper answer is
a fixed preview window with the tile drawn inside it, which is a larger change
than a correction should carry, and is still outstanding.

## What carries over from 2026-08-24

Everything except the headline rule. The earlier ADR remains the record of the
original crash and its analysis, and these of its decisions are unchanged and
still binding:

- a panel that does not yet exist is created at its resolved frame, with the
  controller's view sized **before** `contentViewController` is assigned — a
  `FlutterView` starts at `NSZeroRect`, so a panel built with the right
  `contentRect` otherwise comes back 0 × 0;
- a resize that is genuinely needed orders the panel front *before* resizing, so
  the frame the engine is forced to commit has a drawable to land in;
- a deferred measurement arriving after the panel was hidden is stored and
  applied by the next show;
- placement arithmetic lives in `RecorderCore` as pure functions, where
  `swift test` can execute it, and degenerate sizes are rejected there rather
  than written into a window;
- the session's display is pinned at the first show and used for every later
  placement in that session.

What is **withdrawn** is "exactly one size per show" as the rule that makes
#185394 unreachable. It was necessary and not sufficient; a panel may now be
resized more than once in a show, provided every resize grows.

## Consequences

- The input menu is held at its high-water size. Its window therefore stopped
  painting a ground, so the surplus is the user's screen rather than a pale
  rectangle beside the sheet, and a press in the surplus dismisses — an
  invisible region that silently ate clicks would be worse than the resize it
  replaced. The control strip's window stopped painting a ground for the same
  reason; its frame is drawn by the strip itself.
- The camera preview remains a feeder of the same class, mitigated but not
  fixed. Recorded in `../development/compatibility-matrix.md`.
- `../architecture/recording.md` states the current rule; a reader who finds
  "one size per show" anywhere else has found something stale.
- The policy is unit-tested in `OverlayPlacementGeometryTests`; **its
  application is not**, and cannot be here. `swift test` links `RecorderCore`
  against Foundation and cannot open an `NSPanel`, host a Flutter view or reach
  the engine's surface cache. That gap is exactly why the 2026-08-24 fix shipped
  looking right.

## Alternatives considered

- **Keep one-size-per-show and fix the ledger's key.** Rejected: it closes the
  estimate-to-measured correction within one show and leaves `A → B → A` across
  shows of different sheets in the same panel, which is where both crashes were.
- **A panel per sheet kind.** Would make each panel's size history monotonic by
  construction, but costs a raster thread, an IO thread and a Dart isolate per
  kind, for a rule that already closes the fault with none of that.
- **Pin the engine to Skia.** Avoids the Impeller path but gives up the renderer
  the toolchain defaults to, for a bug the application caused itself.
- **Apply the rule to the camera preview too.** Rejected above: it would trade a
  crash class neither crash was in for a guaranteed, visible defect in the file.
