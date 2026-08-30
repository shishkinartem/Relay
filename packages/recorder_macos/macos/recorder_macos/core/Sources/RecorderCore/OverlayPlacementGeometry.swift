import Foundation

/// Where an overlay panel goes, resolved without touching AppKit (§5, §6).
///
/// Split out of `OverlayWindowController` so the arithmetic can be executed by
/// `swift test`. The host is then left with the parts that genuinely need
/// AppKit: choosing the screen, creating the panel and ordering it front.
///
/// The size rule below is the one that matters most. A window hosting a Flutter
/// view blocks the platform thread on every resize until that engine commits a
/// frame at the new size, so the number of sizes a panel is driven through per
/// show is not a detail — it is the difference between one committed frame and
/// three. Re-showing the control strip used to apply the placement's *requested*
/// size and then immediately correct it to the measured one, which drove the
/// panel M → request → M inside a single main-loop turn. Resolving the size once,
/// here, is what makes a re-show a no-op instead.
public enum OverlayPlacementGeometry {
  /// The size a panel must actually be shown at.
  ///
  /// A measurement the overlay has already reported always wins: it is the size
  /// the panel is currently at, and the size it will be corrected back to the
  /// moment the overlay measures itself again. Applying the request first only
  /// adds a resize that is immediately undone.
  ///
  /// A measurement is only trusted when it describes a real window; anything
  /// degenerate falls back to the request, which the caller supplies from the
  /// contract.
  public static func effectiveSize(requested: CGSize, measured: CGSize?) -> CGSize {
    guard let measured, isDrawable(measured) else {
      return isDrawable(requested) ? requested : CGSize(width: 1, height: 1)
    }
    return measured
  }

  /// A key for "the sheet's content has the same shape as last time".
  ///
  /// The host opens the input menu at an estimated size and the engine corrects
  /// it a turn later, once it has measured its own text. Correcting *once* is
  /// safe. Correcting back to a size the panel recently left is not: the engine
  /// caches the surfaces it renders into by size, and a request that returns to
  /// an earlier size can be handed a surface of the other one — the render
  /// target built from it has no colour attachment, and the raster thread reads
  /// a null texture (flutter/flutter#185394). This project has already crashed
  /// that way, and `docs/adr/2026-08-24-overlay-panels-are-sized-once-per-show.md`
  /// records the same fault on the control strip.
  ///
  /// So the host remembers what each *shape* of sheet measured, and opens the
  /// next one of that shape at the remembered size. The key is deliberately not
  /// a height: it is the set of things that change the height, so a sheet whose
  /// content differs is never opened at another sheet's size.
  ///
  /// Kept here, in the pure package, because it is a decision rather than a
  /// value — and because nothing else in this area can be executed by a test.
  public static func menuContentKey(
    kind: String?,
    rowCount: Int,
    loading: Bool,
    hasLevel: Bool,
    hasNotice: Bool,
    presetCount: Int,
    cornerCount: Int,
    canResetPosition: Bool
  ) -> String {
    // The row *count* rather than the rows: two microphones and two cameras
    // lay out to the same height, and a device renamed does not resize a sheet.
    // A loading sheet is one row whatever the list holds, so it is its own key
    // rather than a row count of zero — an empty list is a different sheet.
    return [
      kind ?? "unknown",
      loading ? "loading" : "rows:\(rowCount)",
      hasLevel ? "level" : "-",
      hasNotice ? "notice" : "-",
      "presets:\(presetCount)",
      "corners:\(cornerCount)",
      canResetPosition ? "reset" : "-",
    ].joined(separator: "/")
  }

  /// Whether a size can be given to a window that hosts a rendering surface.
  ///
  /// Zero, negative and non-finite are all rejected together: each of them
  /// produces a view whose drawable cannot be created, and a renderer handed a
  /// surface that does not exist has nowhere to draw.
  public static func isDrawable(_ size: CGSize) -> Bool {
    return size.width.isFinite && size.height.isFinite && size.width >= 1
      && size.height >= 1
  }

  /// Whether an absolute frame from the contract can be placed as it stands.
  public static func isPlaceable(_ frame: CGRect) -> Bool {
    return frame.origin.x.isFinite && frame.origin.y.isFinite
      && isDrawable(frame.size)
  }

  /// An absolute frame, resolved against the display's **full** frame.
  ///
  /// The contract expresses frames top-left, AppKit is bottom-left. An absolute
  /// frame names a rectangle inside the captured canvas — the camera
  /// picture-in-picture — and the capture covers the whole display, menu bar
  /// included, so the full frame is the right reference and `visibleFrame`
  /// would shift the tile off the composited one.
  public static func absoluteFrame(_ frame: CGRect, inDisplayFrame display: CGRect)
    -> CGRect
  {
    return CGRect(
      x: display.origin.x + frame.origin.x,
      y: display.origin.y + display.height - frame.origin.y - frame.height,
      width: frame.width,
      height: frame.height)
  }

  /// An anchored dock, resolved against the display's **usable** area.
  ///
  /// `visibleFrame`, not `frame`: the control strip has to land under the menu
  /// bar and above the Dock rather than on top of them. On a notched display
  /// the menu bar area *is* the notch, and a strip docked into it puts its
  /// right-hand controls behind dead pixels where clicks never arrive. Windows
  /// docks against `rcWork` for the same reason.
  public static func anchoredFrame(
    size: CGSize, anchor: String, margin: Double, inVisibleFrame visible: CGRect
  ) -> CGRect {
    let x = visible.origin.x + (visible.width - size.width) / 2
    let y =
      anchor == "bottomCenter"
      ? visible.origin.y + margin
      : visible.origin.y + visible.height - size.height - margin
    return CGRect(origin: CGPoint(x: x, y: y), size: size)
  }

  /// A resize that grows the panel about its own top centre, kept on screen.
  ///
  /// A strip wider than the display it is docked on would otherwise put its
  /// trailing controls past the edge, where they cannot be clicked.
  public static func resizedKeepingTopCenter(
    _ current: CGRect, to size: CGSize, inVisibleFrame visible: CGRect
  ) -> CGRect {
    let centerX = current.midX
    let top = current.maxY
    let x = min(
      max(centerX - size.width / 2, visible.minX),
      max(visible.maxX - size.width, visible.minX))
    let y = min(
      max(top - size.height, visible.minY),
      max(visible.maxY - size.height, visible.minY))
    return CGRect(origin: CGPoint(x: x, y: y), size: size)
  }

  /// Whether two frames differ by enough to be worth a resize.
  ///
  /// Only the size is consulted. Moving a window does not recreate its
  /// rendering surface; resizing one does, which is the operation this whole
  /// type exists to ration.
  public static func needsResize(from current: CGRect, to target: CGRect) -> Bool {
    return abs(current.width - target.width) > 0.5
      || abs(current.height - target.height) > 0.5
  }

  /// How close to an edge or to the centre a drag has to end to land on it.
  ///
  /// §33.3's 24 points. A snap is a hint, not a constraint: it only ever moves
  /// the strip to a spot the clamp below would have allowed anyway.
  public static let stripSnapDistance: Double = 24

  /// The remembered spot, resolved against the display's **usable** area.
  ///
  /// `visibleFrame` for the same reason `anchoredFrame` uses it: the fraction
  /// was recorded against the usable area, and resolving it against the full
  /// frame would walk the strip under the menu bar and into the notch a little
  /// further on every session. The result is clamped, so a fraction arrived at
  /// on a display of a different shape still lands somewhere clickable.
  ///
  /// The contract's fraction is top-left and AppKit is bottom-left — the flip
  /// `absoluteFrame` documents — so `y: 0` is the **top** of the usable area.
  public static func fractionalFrame(
    size: CGSize, ratio: OverlayStripRatio, inVisibleFrame visible: CGRect
  ) -> CGRect {
    let x = unitFraction(ratio.x)
    let y = unitFraction(ratio.y)
    let left = visible.minX + x * visible.width
    let top = visible.maxY - y * visible.height
    return clamped(
      CGRect(
        x: left, y: top - size.height, width: size.width, height: size.height),
      inVisibleFrame: visible)
  }

  /// Where a frame sits, as the fraction the contract stores.
  ///
  /// The inverse of `fractionalFrame` against the same usable area, so a strip
  /// that is shown and then read back reports the fraction it was shown at.
  ///
  /// Null for a usable area nothing can be a fraction of. A caller that cannot
  /// read a position keeps whatever it had stored: failing to ask is not the
  /// user having dragged the strip back (§33.3).
  public static func positionRatio(
    of frame: CGRect, inVisibleFrame visible: CGRect, displayId: String
  ) -> OverlayStripRatio? {
    guard !displayId.isEmpty, visible.width > 0, visible.height > 0,
      frame.minX.isFinite, frame.maxY.isFinite
    else { return nil }
    return OverlayStripRatio(
      displayId: displayId,
      x: unitFraction((frame.minX - visible.minX) / visible.width),
      y: unitFraction((visible.maxY - frame.maxY) / visible.height))
  }

  /// A frame pulled back inside the display's usable area.
  ///
  /// Applied on every show, every drag end and every display change (§33.3), so
  /// the menu bar, the notch and the Dock stay uncovered continuously rather
  /// than only at the moment the strip was first docked. A strip wider than the
  /// usable area is pinned to its leading edge rather than centred on nothing:
  /// the controls that matter — Pause and Stop — are at that end.
  public static func clamped(_ frame: CGRect, inVisibleFrame visible: CGRect)
    -> CGRect
  {
    let x = min(
      max(frame.minX, visible.minX), max(visible.maxX - frame.width, visible.minX))
    let y = min(
      max(frame.minY, visible.minY),
      max(visible.maxY - frame.height, visible.minY))
    return CGRect(origin: CGPoint(x: x, y: y), size: frame.size)
  }

  /// Where a drag ends: on the nearest edge or centre line it came close to.
  ///
  /// Horizontally the candidates are both edges of the usable area and its
  /// centre; vertically only the edges, because §33.3 snaps to the *horizontal*
  /// centre alone. The nearest candidate within the distance wins, and an edge
  /// takes a tie, so a strip almost as wide as the display is not pulled off an
  /// edge it was already flush with by a centre line at the same remove.
  ///
  /// Clamped afterwards: on a display narrower than the strip the centre
  /// candidate hangs off both edges at once, and a snap must never be the thing
  /// that puts a control out of reach.
  public static func snapped(
    _ frame: CGRect, inVisibleFrame visible: CGRect,
    within distance: Double = stripSnapDistance
  ) -> CGRect {
    let origin = CGPoint(
      x: snap(
        frame.minX,
        to: [
          visible.minX, visible.maxX - frame.width,
          visible.midX - frame.width / 2,
        ], within: distance),
      y: snap(
        frame.minY, to: [visible.minY, visible.maxY - frame.height],
        within: distance))
    return clamped(
      CGRect(origin: origin, size: frame.size), inVisibleFrame: visible)
  }

  /// The strip moved by a keyboard nudge, settled exactly as a drag end is.
  ///
  /// §33.3's arrow keys, deferred from the drag itself: the same snap and the
  /// same clamp, because a strip that lands somewhere a drag could not is a
  /// second placement rule nobody asked for.
  ///
  /// The contract's deltas are top-left — a positive `dy` is *down* — and
  /// AppKit is bottom-left, the flip `absoluteFrame` documents. A non-finite
  /// delta moves nothing: a NaN origin makes AppKit place a panel nowhere.
  public static func nudged(
    _ frame: CGRect, dx: Double, dy: Double, inVisibleFrame visible: CGRect
  ) -> CGRect {
    guard dx.isFinite, dy.isFinite else {
      return clamped(frame, inVisibleFrame: visible)
    }
    return snapped(
      CGRect(
        x: frame.minX + dx, y: frame.minY - dy, width: frame.width,
        height: frame.height), inVisibleFrame: visible)
  }

  /// Where the input menu goes, relative to the strip that raised it (§33.4).
  ///
  /// Below the strip when there is room under it, above it otherwise;
  /// horizontally centred on the control that asked for it, and clamped to the
  /// usable area. "Below" is a *smaller* y here, AppKit being bottom-left.
  ///
  /// `anchorX` is the pressed control's centre in screen coordinates — only
  /// Flutter knows where a chevron ended up inside the strip, so it travels
  /// with the command that opened the menu. Without one the menu centres on the
  /// strip, which is where a menu raised by anything but a chevron belongs.
  ///
  /// The clamp is what answers §33.7's "sheet would extend past the usable
  /// area": it flips first, and only then pins, so a menu taller than either
  /// side still lands somewhere clickable rather than half off the display.
  public static func inputMenuFrame(
    size: CGSize, anchorX: CGFloat?, stripFrame: CGRect, gap: Double,
    inVisibleFrame visible: CGRect
  ) -> CGRect {
    let center = anchorX.flatMap { $0.isFinite ? $0 : nil } ?? stripFrame.midX
    let below = stripFrame.minY - gap - size.height
    let above = stripFrame.maxY + gap
    let y = below >= visible.minY ? below : above
    return clamped(
      CGRect(
        x: center - size.width / 2, y: y, width: size.width,
        height: size.height), inVisibleFrame: visible)
  }

  /// The nearest candidate within `distance`, or the value unchanged.
  private static func snap(
    _ value: CGFloat, to candidates: [CGFloat], within distance: Double
  ) -> CGFloat {
    let limit = CGFloat(distance)
    var best = value
    var bestDelta = CGFloat.infinity
    for candidate in candidates where candidate.isFinite {
      let delta = abs(candidate - value)
      // `<=` accepts a candidate exactly at the distance, `<` keeps the first
      // one on a tie — which is why the edges are listed before the centre.
      if delta <= limit && delta < bestDelta {
        best = candidate
        bestDelta = delta
      }
    }
    return best
  }

  /// A fraction pulled into `[0, 1]`, with anything unrepresentable read as 0.
  ///
  /// A fraction slightly outside the unit square is a rounding artefact of a
  /// display that changed shape, not a lost spot — the same reading the Dart
  /// side takes. A non-finite one is neither, and it must not reach a window:
  /// a NaN origin makes AppKit place a panel nowhere.
  private static func unitFraction(_ value: CGFloat) -> CGFloat {
    guard value.isFinite else { return 0 }
    return min(max(value, 0), 1)
  }
}

/// Where the control strip sits, as a fraction of one display's usable area.
///
/// The wire shape of §33.3's stored position, mirroring
/// `OverlayStripPosition` on the Dart side. A fraction rather than a point,
/// because a point survives neither a resolution change nor an undocked
/// monitor; [displayId] is the display holding the strip's centre when the drag
/// ended, not §5's current display.
public struct OverlayStripRatio: Equatable {
  public let displayId: String

  /// Top-left as a fraction of the usable area, each in `[0, 1]`.
  public let x: CGFloat
  public let y: CGFloat

  public init(displayId: String, x: CGFloat, y: CGFloat) {
    self.displayId = displayId
    self.x = x
    self.y = y
  }
}
