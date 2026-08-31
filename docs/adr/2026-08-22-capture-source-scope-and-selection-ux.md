# Entire-screen capture in MVP, and a custom in-app source picker

**Status:** Accepted
**Date:** 2026-08-22

## Context

`TECHNICAL_SPEC.md` originally fixed the MVP capture source to **one selected
application window** (§2, §31) and listed whole-display capture under Deferred.

The connected design `Screen Recorder - Desktop MVP.dc.html` contradicts that on
three screens: the source picker (`1a`) lists screens before windows, the launch
screen (`1c`) offers a `Entire screen / A window` choice with **Entire screen
preselected**, and `1p` documents the entire-screen recording path as the default.
The design's own annotation flags the conflict: it "adds `CaptureSource.Display`
to MVP, which §2 lists as deferred".

The conflict was surfaced rather than silently resolved, per `CLAUDE.md`. The
product decision taken on 2026-08-22 is that entire-screen capture is always
available and is the default.

Separately, §30.1 left the source-selection mechanism open between a native system
picker and a custom application-owned list. Adding a second source type forces the
question, because the two source types must be chosen from one surface.

## Decision

1. **`CaptureSource.Display` is part of MVP, and is the default source.**
   Window capture remains fully supported. `CaptureSource.Region` stays deferred.
2. **Source selection uses a custom in-application list**, not a native system
   picker: displays first, then windows, each with a still thumbnail, title and
   subtitle, per design `1a`. Enumeration stays behind `CaptureSourceProvider`.
3. `TECHNICAL_SPEC.md` §1, §2, §4, §4.1, §5, §6, §29, §30 and §31 are updated to
   match. §30.1 is marked resolved.

## Alternatives considered

- **Keep window-only, treat the design as a gap.** Rejected: the product owner
  chose the design's behavior explicitly, and it is the more common recording
  need. Would have left three designed screens unimplementable.
- **Ship both source types but keep window as the default.** Rejected: it
  preserves the letter of the old §31 while still being a §2 scope change, and it
  contradicts the design without removing any work.
- **Native system picker** (macOS content-sharing picker / Windows picker).
  Rejected: the two platforms present different UX, the picker cannot be styled
  with the project design system, and thumbnail/selection presentation would
  diverge between platforms. The `CaptureSourceProvider` boundary keeps this
  reversible per platform.

## Consequences

**Architecture is unaffected.** §4 already carried `Display` as a planned variant
and §28 already forbade booleans such as `isFullScreen`. This is a scope change,
not an architecture change. `CaptureSourceType` remains a value object.

**Overlay exclusion becomes safety-critical rather than defense-in-depth.** With a
window source, `SCContentFilter(window:)` scopes every overlay out of capture
regardless. With a display source, they all sit inside the captured bounds by
definition, and `SCContentFilter(display:excludingWindows:)` /
`WDA_EXCLUDEFROMCAPTURE` are the *only* mechanism preventing them from being
recorded. §6 is updated to say so, and overlay-exclusion integration tests must
run against a display source.

There were two overlays when this was written — the control strip and the camera
preview. **There are three:** the input menu a chevron opens is a third
always-on-top window on exactly these terms (§6, §33.4). The rule was never about
a count, and is stated here without one so the next overlay is covered by it
rather than by an amendment: *every* application-owned always-on-top surface a
session puts on screen reaches the exclusion list.

**Capture volume rises.** A display source is typically larger than a window, so
downscaling to the 720p/1080p canvas does more work per frame. The §24 soak tests
gain a display-source scenario.

**§30.3 widens.** Non-16:9 handling now covers 16:10 and ultrawide displays, not
only oddly-shaped windows. It remains open.

**Camera preview placement gains a rule.** In display mode the preview window is
placed exactly where the compositor draws the PiP, so what the user sees matches
the file. See `2026-08-22-camera-pip-composition.md`.
