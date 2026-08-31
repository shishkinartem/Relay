# The control strip moves, and each input discloses its devices

**Status:** Accepted
**Date:** 2026-08-30
**Accepted:** 2026-08-30 by the product owner, after reviewing the design
**Amends:** the placement rule in `TECHNICAL_SPEC.md` §6

## Context

Two requirements land on the same window.

The strip is docked to the top centre of the current display's usable area and
stays there for the whole session. Whatever is at the top centre of the screen
is covered for as long as the recording runs — which, for the applications
people record, is the tab bar, the toolbar, or the thing they are demonstrating.
There is no way to move it.

Separately, `docs/adr/2026-08-30-input-device-selection.md` gives each input a
list of devices, and the strip is where the inputs live. The obvious move is to
put the list in the strip. The strip cannot grow: §6 fixes it at one size in
every session state, because its host window is sized to what the strip measures
and a window that resizes under the pointer slides every remaining control out
from under the click that is already happening.

## Decision

### The strip is movable

The whole strip background is a drag handle; the controls keep their own hit
targets and are not part of it.

| Rule | Value |
|---|---|
| Drag threshold | 4 px before a press becomes a drag |
| Default position | top centre, margin 6 — unchanged |
| Stored as | a fraction of the display's **usable** area, plus the display id |
| Clamped | to `NSScreen.visibleFrame` / `MONITORINFO.rcWork`, always |
| Snap | within 24 px of a usable-area edge or of the horizontal centre |
| Keyboard | arrows move 8 px, Shift-arrows 32 px, while the strip has focus |
| Reset | an item in the strip's own menu, and automatically when the stored spot no longer exists |

A press under the threshold is still a click, so a slow click on a control is
not eaten by a drag; once the threshold is crossed, no control fires from that
gesture.

Position is a fraction of the usable area rather than a point, so a display that
changes resolution, or a different machine, reproduces the same relative spot
instead of an absolute one that may now be off-screen. Clamping to the usable
area is what keeps §6's real constraint — never over the menu bar, never over
the notch, never under the Windows taskbar — true continuously rather than only
at the moment the strip is first shown.

Dragging onto a second display is allowed. The strip belongs to whichever
display holds its centre when the drag ends, and the stored fraction is recorded
against that display. This is deliberately *not* tied to §5's current display:
§5 defines where recorder UI is placed by default, and the user overriding that
placement is the whole point.

### Devices are disclosed from a separate panel

Each selectable input grows a chevron on the trailing edge of its 32 px square.
It opens an **action sheet** — a list of that input's devices, with labels.

The sheet is its own always-on-top window, not part of the strip:

- the strip keeps one size in every state, as §6 requires;
- nothing resizes under the pointer;
- the sheet can be taller than the strip, which a device list needs to be.

It is therefore a third overlay kind, and §6's exclusion rule applies to it in
full: it is passed to the capture filter's exclusion list and **must never
appear in the captured video**. The overlay-exclusion integration test covers
all three surfaces, against a display source.

| Case | Behaviour |
|---|---|
| Placement | below the strip when there is room, above it otherwise; aligned to the chevron; clamped to the usable area |
| Focus | a non-activating panel — opening it must not take key focus from the application being recorded |
| Closes on | choosing an item, Esc, a click outside, the strip moving, the display configuration changing, the session ending |
| Two chevrons | one sheet at a time; a second chevron replaces the first |
| Contents | `System default` first, then devices, current one checked, then `Off` — which is the existing toggle |
| Still loading | one disabled row, `Looking for devices…` |
| Nothing found | `No microphone found`, not an empty panel |
| Device appears or disappears while open | the list re-renders; if the selected device went away, the fallback is shown selected and the sheet stays open |
| Kind not selectable on this platform | no chevron is drawn; the control stays a plain toggle |

The strip's own menu — reached from the strip background, not from an input —
would carry `Reset position` and nothing else.

**It has not been built.** `OverlayCommand.resetStripPosition` is declared, both
hosts answer it and the Dart side dispatches it; there is no menu, no key
binding and no button that raises it, so the command is unreachable in the
shipped application. The same is true of the eight nudge commands. Recorded as an
open gap in `../development/compatibility-matrix.md` → *The movable control
strip*, and in `TECHNICAL_SPEC.md` §33.3 — not as a shipped affordance.

## Alternatives considered

- **Grow the strip and render the list inside it.** Rejected: it breaks §6's
  one-size rule, and the failure mode is the one §6 was written about — the
  window resizes during the click that opened the menu and the remaining
  controls move out from under the cursor.
- **A native menu (`NSMenu` / `TrackPopupMenu`).** Rejected: two different
  looks, neither of them the design system's, and on macOS a menu tracking loop
  takes over the event stream of a panel that is meant to stay non-activating.
- **A small grip glyph as the only drag handle.** Rejected: a grip on a 48 px
  strip is a target of a few millimetres on a window that floats over someone
  else's work. The whole background drags — which is also the platform
  convention — and a grip glyph stays as the hint that it does.
- **Remember the position in absolute screen points.** Rejected: it survives
  nothing. A resolution change, an undocked monitor or a different machine puts
  the strip somewhere that no longer exists, and the only recovery is a reset
  the user has to discover.
- **Let the strip float free, unclamped.** Rejected: it is how a control strip
  ends up half under the notch, and §6's placement rule exists precisely
  because that region is not neutral space.

## Consequences

`OverlayWindowKind` gains a third member, and every place that enumerates the
overlays — exclusion, teardown, the `excludedWindowIds` contract — must grow
with it. A missed one is a menu that appears in the recording.

Strip position and device choices are user state: `AppSettings` gains fields and
a schema version, with a migration, per §15.

The drag, snap and clamp arithmetic is pure. It belongs beside
`OverlayPlacementGeometry` in `RecorderCore` and its Windows counterpart, so it
is executed by `swift test` / `ctest` rather than only by a person with two
monitors.

Command serialization from §6 — one command at a time, a refused pause treated
as a lost click — now has to cover device selection too: a swap issued while
another swap is in flight is dropped, not queued.
