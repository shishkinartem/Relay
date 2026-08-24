# Camera PiP geometry and mirroring

**Status:** Superseded in part
**Date:** 2026-08-22
**Superseded by:** `docs/adr/2026-08-23-camera-pip-follows-source-aspect.md`,
which replaces the size and shape rows of the table below. The placement rule,
the corner radius and the mirroring split still stand.

## Context

`TECHNICAL_SPEC.md` §7 fixed the camera PiP position (lower-right, composited into
the final video) but left size, margin, shape, corner radius and mirroring open as
§30.2. Without those values the compositor cannot be written, and the design
`1h` supplies a concrete proposal for all five.

## Decision

Adopt design `1h` as the `CameraOverlayConfiguration` defaults:

| Parameter | Value |
|---|---|
| Width | `0.22 × canvas width` |
| Shape | square, 1:1 |
| Corner radius | `0` |
| Margin from edges | `0.01 × canvas width` |
| Preview | mirrored |
| Final output | not mirrored |

These are **defaults of a configuration object**, not compositor constants, as §7
and §28 require.

Placement rule for the live preview: in display mode the preview window is drawn
at the same position and size as the composited PiP, so the user sees what lands
in the file. In window mode the PiP position is inside a window the user may not
be looking at, so the preview is placed independently.

## Alternatives considered

- **Circular mask.** Rejected: the Industry design system is square-cornered
  throughout, and a circular mask adds an alpha-mask stage to the compositor for
  no product benefit.
- **Absolute pixel sizes.** Rejected: 720p and 1080p, and display versus window
  canvases, would each need their own numbers. Ratios collapse that to one
  configuration.
- **Mirror both preview and output**, or neither. Rejected: mirroring the preview
  matches what users expect of a camera view of themselves; not mirroring the
  output matches what they expect to publish. The split is the convention.

## Consequences

The compositor can be implemented and unit-tested from configuration alone, at any
canvas size. Making the PiP movable/resizable (deferred in §2) later means varying
these same fields, not changing the composition model.

Mirroring being asymmetric means preview and output are not pixel-identical; any
visual regression test comparing them must account for the horizontal flip.
