# The camera PiP takes the camera's own shape, and is smaller

**Status:** Accepted
**Date:** 2026-08-23
**Supersedes:** the geometry table in
`docs/adr/2026-08-22-camera-pip-composition.md`

## Context

`docs/adr/2026-08-22-camera-pip-composition.md` fixed the picture-in-picture at
**square, `0.22 x canvas width`**. Every webcam this application will meet is
wider than it is tall — 16:9 or 4:3 — so a square tile can only be filled by
cropping the frame or by stretching it, and the two implementations disagreed
about which:

- macOS aspect-**filled** the square and cropped the sides off, so a third of
  the frame never reached the file;
- Windows letterboxed into it, so the square was part empty;
- the live preview drew the camera texture stretched to fill its window,
  because a platform texture has no intrinsic size — which is what the user
  actually saw, and reported, as "the camera is squeezed".

At `0.22` the tile was also large: 422 px across a 1920-wide canvas, a fifth of
the width of the recording.

## Decision

The tile follows the camera.

| Parameter | Was | Now |
|---|---|---|
| Width | `0.22 × canvas width` | `0.16 × canvas width` |
| Shape | square, 1:1 | the camera's own aspect ratio |
| Fallback shape | — | `16:9`, until the camera reports |
| Composition | fill + crop (macOS) | aspect-fit, never cropped, never distorted |

`CameraOverlayConfiguration` gains `followsSourceAspectRatio` (default true).
`aspectRatio` stays, as the shape used when the camera's own is not known yet
and as the shape when following is switched off. Everything remains
configuration; nothing is a compositor constant, as §7 and §28 require.

The host resolves the tile, because only the host knows what the camera
produces. Dart places the preview from the fallback shape and sends the
configuration with it; the platform re-resolves the rectangle against the
camera's real aspect ratio, moving only the height and only away from the
corner the tile is anchored to. The compositor resolves the same rectangle from
the same configuration and the frame it is about to draw, so the preview and
the picture-in-picture stay the same object (design `1p`).

The camera's shape is read from the capture device's **active format**, not
from a captured frame: the preview is placed as soon as the camera starts,
which is before the first frame arrives.

## Alternatives considered

- **Keep the square and crop.** Rejected: it is the behaviour that was
  reported as broken, and it silently discards a third of the frame — the same
  thing §10 forbids for the capture source.
- **Keep the square and letterbox.** Rejected: no distortion, but a tile that
  is a third empty, and the empty part is not neutral — it is the desktop
  showing through a frame that claims to be the camera.
- **Make the tile 16:9 and letterbox anything else.** Rejected as the default:
  it is right for almost every camera and wrong for the 4:3 ones, for no gain
  over following the source. It remains available as
  `followsSourceAspectRatio: false`.
- **Report the camera's shape to Dart and place from there.** Rejected: it
  needs a new platform call and a round trip before the preview can be shown,
  to arrive at the rectangle the compositor is going to compute anyway.

## Consequences

The camera reaches the file whole, at its own proportions, at every canvas
size, on both platforms — and the preview shows exactly that.

A 4:3 camera makes a taller tile than a 16:9 one at the same width. The margin
is measured from the canvas edges, so the tile still sits in its corner; only
its height differs.

The two platforms now compose the picture-in-picture the same way. macOS
changed from fill-and-crop to fit, which is what Windows already did.
