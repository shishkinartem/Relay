# The camera picture-in-picture is dragged by hand and sized by preset

**Status:** Accepted
**Date:** 2026-08-30
**Accepted:** 2026-08-30 by the product owner, after reviewing the design
**Amends:** `TECHNICAL_SPEC.md` §2 (Deferred), §7, and one of the core product
invariants in `CLAUDE.md`
**Builds on:** `docs/adr/2026-08-23-camera-pip-follows-source-aspect.md`

## Context

§2 lists *movable/resizable camera PiP* as deferred, and §7 fixes the tile in
the lower right at `0.16 × canvas width`, in the camera's own shape.

That default is good and this ADR does not change it. It is not right for every
recording: the lower-right corner is where many applications put the thing being
demonstrated, and `0.16` is large for a dense dashboard and small for a talking
head. A user notices either *while recording*, not before.

The first draft of this decision gave the tile eight resize handles and a free
width in `[0.08, 0.50]`. Reviewed, that was the wrong control: a number the user
has to discover by dragging, with no way to say the two things they actually
want to say — "small square" and "small circle". Freedom was standing in for an
answer.

## Decision

**Position is dragged. Size and shape are three presets. There are no resize
handles.**

| Preset | Shape | Width | Frame |
|---|---|---|---|
| **Camera** — the default | the camera's own aspect ratio | the camera's own width mapped onto the canvas, capped at `0.16 × canvas width`, floored at `0.08` | whole, never cropped |
| **Square · small** | 1:1 | `0.10 × canvas width` | centre-cropped |
| **Circle · small** | 1:1, masked to a circle | `0.10 × canvas width` | centre-cropped |

"The camera's own width" sets the *default*, not a licence to upscale: a
1280 × 720 camera on a 1920-wide canvas asks for `0.66` and gets the `0.16` cap,
so an ordinary session looks exactly as it does today. A camera that asks for
less than the cap gets what it asks for, down to the floor, and is never scaled
past its own pixels.

`CameraOverlayConfiguration` keeps its role as the single resolved description
of the tile — every value configuration, no compositor constants (§7, §28). The
preset is a value object, `CameraPipPreset { camera, square, circle }`, that
resolves to the aspect ratio, the width ratio, the corner radius and the fit
mode. The existing fields do not go away; the preset is what writes them.

Position stays free, as a fraction of the canvas, dragged from the live preview
in display mode where the preview *is* the tile (design `1p`). It is clamped to
the margin, snaps to a corner within 2% of the canvas width, and keeps its shape
while it moves. In window mode the preview is not the tile (design `1e`), so
position there is chosen from the four corners in the camera menu instead.

### This changes a product invariant, deliberately

`CLAUDE.md` and §7 both say: *the camera frame is never cropped and never
distorted, in the file or in the preview.* Square and Circle crop — a 16:9
sensor cannot fill a square any other way, and letterboxing inside the square
would leave a tile that is a third desktop.

The rule becomes:

> The camera frame is **never distorted**, and is cropped **only** by an
> explicit shape preset — identically in the preview and in the file.

Two consequences follow, and both are load-bearing: the default still never
crops, and no crop ever happens without the user having chosen the shape that
causes it. The preview shows the same crop as the output, so `1p`'s promise —
what you see is what lands in the file — survives.

## Alternatives considered

- **Free resize handles** (the first draft). Rejected on review: it asks the
  user to arrive at "small square" by dragging a corner, and it cannot express a
  circle at all. Kept only as the thing the presets replace.
- **Presets plus handles.** Rejected: the handles are then a second way to do
  the same thing that also silently leaves the preset behind, so the menu and
  the tile disagree about what shape it is.
- **Presets, with position fixed to the four corners.** Rejected as too little:
  the case that motivates the request is a corner already occupied by the
  content, and a corner-only tile cannot move out of it.
- **Letterbox inside the square and circle instead of cropping.** Rejected: the
  empty part of the tile is not neutral, it is the desktop showing through
  something that claims to be the camera — and a circle with letterbox bars is
  not a circle of anybody.
- **More sizes (S/M/L per shape).** Rejected for now: three presets answer the
  request, and each additional one has to earn a row in a menu that is open over
  someone's recording. `widthRatio` remains configuration, so a fourth preset is
  a table entry, not a redesign.

## Consequences

§2's deferred list loses an entry. §7's table becomes a set of presets with
stated bounds rather than a fixed geometry. `CLAUDE.md`'s invariant list needs
the amended wording above. All three are updated on acceptance.

The compositor on both platforms must accept a geometry update mid-session —
today `CameraOverlayConfiguration` is delivered once, at `prepare`, and neither
`VideoCompositor.swift` nor `video_compositor.cpp` expects it to change. The
update is applied between frames, never during one.

The circle needs a mask in both compositors and in the preview, and the three
must agree to the pixel or `1p` stops being true.

The preview window becomes interactive: a non-activating always-on-top panel
that receives drags without taking key focus from the application being
recorded, and still never appears in the recording (§6).

Preset resolution and placement are pure geometry, unit tested at every canvas
size and at both bounds, as the existing geometry already is.
