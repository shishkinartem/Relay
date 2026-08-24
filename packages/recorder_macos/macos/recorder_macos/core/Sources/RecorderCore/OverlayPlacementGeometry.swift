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
}
