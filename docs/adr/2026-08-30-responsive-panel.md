# The panel has a width range, and the layout answers to it

**Status:** Accepted
**Date:** 2026-08-30
**Accepted:** 2026-08-30 by the product owner, after reviewing the design
**Amends:** the fixed-panel constraint the design canvas states for every screen

## Context

The design draws every screen in a 420 × 560 utility panel, and the macOS
window enforces exactly that: `contentMinSize` and `contentMaxSize` share a
width of 420, and the zoom button is disabled. Height is free above 460; width
is not free at all.

Windows was never given the same treatment. `windows/runner/main.cpp` still
creates the Flutter template's default window — 1280 × 720 — and `AppPanel`
fills whatever it is handed. The result is the 420-wide design stretched across
1280 points: a `Start recording` button a metre wide, two window thumbnails
occupying half a screen each, and captions in a column of whitespace. The same
build looks considered on one platform and unfinished on the other, which is
the one thing a cross-platform MVP cannot afford.

A fixed width is also what makes the source picker hard to use. Fifteen windows
in a two-column grid at 420 px is a long scroll with small thumbnails, on
machines whose displays have room for four columns and no way to ask for them.

## Decision

The panel gets a width **range**, and the layouts inside it respond to their own
constraints rather than to a constant.

| | Value |
|---|---|
| Minimum width | 420 — the design's width, and still the reference layout |
| Preferred width | 420 at first launch, then whatever the user last left it at |
| Maximum width | 960; beyond that a utility panel is a window pretending to be an application |
| Minimum height | 460, unchanged |
| Windows | opens at the same preferred size as macOS, with the same limits |

Three breakpoints, expressed as constraints and never as a device or platform
check:

| Width | Layout |
|---|---|
| `< 560` | the reference layout, exactly as drawn |
| `560 – 767` | the source grid takes three columns; labelled control rows keep their single column |
| `≥ 768` | the source grid takes four columns; control rows may pair up where the design has room for it |

Rules that hold at every width:

- No horizontal scrolling, ever. A layout that does not fit reflows or wraps.
- Type sizes, spacing tokens, hairlines and the blueprint marks do not scale
  with width. The grid changes; the objects on it do not.
- The two overlay windows are unaffected: the control strip is sized to its
  content (§6) and the camera preview to the camera's shape (§7). Neither is
  part of this range.
- Every reflowing screen is rendered at all three widths by the design-review
  render, so a breakpoint that breaks a screen is visible without a person
  resizing a window.

## Alternatives considered

- **Keep 420 fixed and make Windows match it.** Rejected, though it is the
  cheapest fix and would have removed the platform difference in one line. It
  leaves the source picker unusable on a large display, and it makes the
  product feel like it does not know what monitor it is on.
- **Let the panel grow without limit.** Rejected: past roughly 960 the content
  is a column of controls in an ocean, and every additional pixel makes it
  worse rather than better.
- **Scale the whole design with the width.** Rejected: a design system with
  fixed tokens is the point of having one, and text that grows with a window is
  a zoom control, not a layout.
- **Breakpoints by platform** — a wider default on Windows because its windows
  are usually larger. Rejected outright: it is the OS conditional §28 forbids,
  wearing a layout costume.

## Consequences

`MainFlutterWindow` loses its fixed `contentMaxSize` and regains its zoom
button. `windows/runner/main.cpp` stops using the template's size.

Every screen has to be re-checked against the connected design at the reference
width and then at the two wider ones. The design canvas gains the wide variants
for the screens that reflow; the rest are stated as unchanged.

The design's own note that the panel never grows past 420 × 560 is superseded by
this ADR, for the panel only. Where a screen has no wide variant, the reference
layout centred in the available width is the specified behaviour — not an
invented one.
