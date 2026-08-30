import XCTest

@testable import RecorderCore

/// Overlay placement arithmetic (§5, §6).
///
/// The size rule here is a crash regression test, not a cosmetic one. Showing
/// the control strip used to apply the placement's requested size and then
/// immediately correct it to the size the strip had measured, so every session
/// after the first drove the panel through M → request → M in one main-loop
/// turn. Each of those is a blocking resize of a `FlutterView`, and alternating
/// two sizes like that can hand the engine a back buffer of the wrong size: the
/// render target then has no colour attachment and the rasterizer dereferences
/// a texture that was never created. `effectiveSize` is what collapses the
/// three sizes back to one.
final class OverlayPlacementGeometryTests: XCTestCase {
  private let requested = CGSize(width: 360, height: 46)
  private let measured = CGSize(width: 372, height: 50)

  // MARK: - one size per show

  func testAMeasuredSizeWinsOverTheRequestedOne() {
    let size = OverlayPlacementGeometry.effectiveSize(
      requested: requested, measured: measured)

    XCTAssertEqual(size, measured)
  }

  func testReShowingAtTheMeasuredSizeIsNotAResize() {
    // The panel is already at the measured size when a second session shows the
    // strip again. Resolving the size the same way both times is what makes the
    // re-show a no-op instead of a shrink immediately undone by a grow.
    let first = OverlayPlacementGeometry.effectiveSize(
      requested: requested, measured: measured)
    let second = OverlayPlacementGeometry.effectiveSize(
      requested: requested, measured: measured)

    let panel = CGRect(origin: .zero, size: first)
    let target = CGRect(origin: .zero, size: second)
    XCTAssertFalse(
      OverlayPlacementGeometry.needsResize(from: panel, to: target),
      "a re-show must not resize the panel")
  }

  func testTheRequestIsUsedUntilTheOverlayHasMeasuredItself() {
    let size = OverlayPlacementGeometry.effectiveSize(
      requested: requested, measured: nil)

    XCTAssertEqual(size, requested)
  }

  func testAMovedPanelIsNotTreatedAsAResizedOne() {
    // Moving a window does not recreate its rendering surface; only a size
    // change does. Anchoring re-runs on every show and can shift the origin.
    let current = CGRect(x: 0, y: 0, width: 372, height: 50)
    let moved = CGRect(x: 800, y: 1400, width: 372, height: 50)

    XCTAssertFalse(OverlayPlacementGeometry.needsResize(from: current, to: moved))
  }

  // MARK: - degenerate sizes never reach a window

  func testADegenerateMeasurementFallsBackToTheRequest() {
    for bad in [
      CGSize(width: 0, height: 0),
      CGSize(width: 372, height: 0),
      CGSize(width: -10, height: 50),
      CGSize(width: CGFloat.nan, height: 50),
      CGSize(width: 372, height: CGFloat.infinity),
    ] {
      let size = OverlayPlacementGeometry.effectiveSize(
        requested: requested, measured: bad)
      XCTAssertEqual(size, requested, "\(bad)")
    }
  }

  func testADegenerateRequestStillProducesADrawableSize() {
    // Both sides degenerate is a bug upstream, but the window still has to be
    // given something a surface can be created for.
    let size = OverlayPlacementGeometry.effectiveSize(
      requested: CGSize(width: 0, height: 0), measured: nil)

    XCTAssertTrue(OverlayPlacementGeometry.isDrawable(size))
  }

  func testAnUnplaceableAbsoluteFrameIsRejected() {
    XCTAssertFalse(
      OverlayPlacementGeometry.isPlaceable(
        CGRect(x: 10, y: 10, width: 0, height: 120)))
    XCTAssertFalse(
      OverlayPlacementGeometry.isPlaceable(
        CGRect(x: CGFloat.nan, y: 10, width: 100, height: 120)))
    XCTAssertTrue(
      OverlayPlacementGeometry.isPlaceable(
        CGRect(x: 10, y: 10, width: 100, height: 120)))
  }

  // MARK: - absolute frames

  func testAnAbsoluteFrameIsFlippedOntoTheDisplaysBottomLeftOrigin() {
    // The contract expresses frames top-left; AppKit is bottom-left. A camera
    // picture-in-picture 20pt from the bottom of a 1000pt display must land
    // 20pt from the bottom in AppKit coordinates too, or the preview and the
    // composited tile disagree (design `1p`).
    let display = CGRect(x: 0, y: 0, width: 1600, height: 1000)
    let tile = CGRect(x: 100, y: 880, width: 256, height: 100)

    let placed = OverlayPlacementGeometry.absoluteFrame(
      tile, inDisplayFrame: display)

    XCTAssertEqual(placed.origin.x, 100, accuracy: 0.001)
    XCTAssertEqual(placed.origin.y, 20, accuracy: 0.001)
    XCTAssertEqual(placed.size, tile.size)
  }

  func testAnAbsoluteFrameIsResolvedAgainstTheDisplaysOwnOrigin() {
    // A second display sits at a non-zero origin in the global coordinate
    // space, and the contract's frame is relative to the display, not to it.
    let display = CGRect(x: -1728, y: 240, width: 1728, height: 1117)
    let tile = CGRect(x: 10, y: 10, width: 200, height: 100)

    let placed = OverlayPlacementGeometry.absoluteFrame(
      tile, inDisplayFrame: display)

    XCTAssertEqual(placed.origin.x, -1718, accuracy: 0.001)
    XCTAssertEqual(placed.maxY, 240 + 1117 - 10, accuracy: 0.001)
  }

  // MARK: - anchored docks

  func testATopCenterDockSitsInsideTheUsableAreaNotOverTheMenuBar() {
    // `visibleFrame`, so the strip lands under the menu bar. On a notched
    // display the menu bar area is the notch, and a strip docked into it puts
    // its trailing controls behind dead pixels.
    let visible = CGRect(x: 0, y: 76, width: 1728, height: 1000)

    let frame = OverlayPlacementGeometry.anchoredFrame(
      size: CGSize(width: 372, height: 50), anchor: "topCenter", margin: 6,
      inVisibleFrame: visible)

    XCTAssertEqual(frame.maxY, visible.maxY - 6, accuracy: 0.001)
    XCTAssertEqual(frame.midX, visible.midX, accuracy: 0.001)
  }

  func testABottomCenterDockMeasuresItsMarginFromTheBottom() {
    let visible = CGRect(x: 0, y: 76, width: 1728, height: 1000)

    let frame = OverlayPlacementGeometry.anchoredFrame(
      size: CGSize(width: 372, height: 50), anchor: "bottomCenter", margin: 6,
      inVisibleFrame: visible)

    XCTAssertEqual(frame.minY, visible.minY + 6, accuracy: 0.001)
  }

  // MARK: - measured growth

  func testGrowingTheStripKeepsItsTopEdgeAndCentre() {
    // Pausing widens the strip: a `Paused` tag and a labelled `Resume` button
    // replace the pause icon. It has to grow about the point it is docked to,
    // or the controls move out from under the pointer.
    let visible = CGRect(x: 0, y: 0, width: 1728, height: 1117)
    let current = CGRect(x: 678, y: 1061, width: 372, height: 50)

    let grown = OverlayPlacementGeometry.resizedKeepingTopCenter(
      current, to: CGSize(width: 460, height: 50), inVisibleFrame: visible)

    XCTAssertEqual(grown.midX, current.midX, accuracy: 0.001)
    XCTAssertEqual(grown.maxY, current.maxY, accuracy: 0.001)
  }

  func testAStripWiderThanItsDisplayIsPulledBackOnScreen() {
    // Trailing controls past the edge are controls a click never reaches.
    let visible = CGRect(x: 0, y: 0, width: 400, height: 1000)
    let current = CGRect(x: 14, y: 940, width: 372, height: 50)

    let grown = OverlayPlacementGeometry.resizedKeepingTopCenter(
      current, to: CGSize(width: 900, height: 50), inVisibleFrame: visible)

    XCTAssertEqual(grown.minX, visible.minX, accuracy: 0.001)
  }

  func testATallStripStaysInsideTheUsableArea() {
    let visible = CGRect(x: 0, y: 76, width: 1728, height: 1000)
    let current = CGRect(x: 678, y: 1026, width: 372, height: 50)

    let grown = OverlayPlacementGeometry.resizedKeepingTopCenter(
      current, to: CGSize(width: 372, height: 2000), inVisibleFrame: visible)

    XCTAssertGreaterThanOrEqual(grown.minY, visible.minY - 0.001)
  }

  func testASubPixelDifferenceIsNotWorthAResize() {
    let current = CGRect(x: 0, y: 0, width: 372, height: 50)
    let target = CGRect(x: 0, y: 0, width: 372.2, height: 50.1)

    XCTAssertFalse(OverlayPlacementGeometry.needsResize(from: current, to: target))
  }

  // MARK: - the remembered spot (§33.3)

  private let stripSize = CGSize(width: 372, height: 50)

  func testAFractionIsMeasuredFromTheTopOfTheUsableArea() {
    // The contract's fraction is top-left, AppKit is bottom-left. `y: 0` is the
    // top of the usable area, so a strip stored at the top lands there and not
    // on the Dock.
    let visible = CGRect(x: 0, y: 76, width: 1728, height: 1000)

    let top = OverlayPlacementGeometry.fractionalFrame(
      size: stripSize,
      ratio: OverlayStripRatio(displayId: "1", x: 0, y: 0),
      inVisibleFrame: visible)

    XCTAssertEqual(top.maxY, visible.maxY, accuracy: 0.001)
    XCTAssertEqual(top.minX, visible.minX, accuracy: 0.001)
  }

  func testAFractionIsResolvedAgainstASecondDisplaysOwnOrigin() {
    // A second display sits at a non-zero origin in the global space; the
    // fraction is of that display's usable area, not of the desktop.
    let visible = CGRect(x: -1728, y: 240, width: 1728, height: 1000)

    let frame = OverlayPlacementGeometry.fractionalFrame(
      size: stripSize,
      ratio: OverlayStripRatio(displayId: "7", x: 0.5, y: 0.25),
      inVisibleFrame: visible)

    XCTAssertEqual(frame.minX, -1728 + 864, accuracy: 0.001)
    XCTAssertEqual(frame.maxY, 240 + 1000 - 250, accuracy: 0.001)
  }

  func testShowingAFractionAndReadingItBackReportsTheSameSpot() {
    let visible = CGRect(x: 0, y: 76, width: 1728, height: 1000)
    let stored = OverlayStripRatio(displayId: "1", x: 0.31, y: 0.44)

    let frame = OverlayPlacementGeometry.fractionalFrame(
      size: stripSize, ratio: stored, inVisibleFrame: visible)
    let readBack = OverlayPlacementGeometry.positionRatio(
      of: frame, inVisibleFrame: visible, displayId: "1")

    XCTAssertEqual(readBack?.x ?? -1, stored.x, accuracy: 0.0001)
    XCTAssertEqual(readBack?.y ?? -1, stored.y, accuracy: 0.0001)
    XCTAssertEqual(readBack?.displayId, "1")
  }

  func testAFractionOutsideTheUnitSquareIsPulledBackRatherThanRejected() {
    // A resolution change leaves a stored fraction slightly off. It is a
    // rounding artefact, not a lost spot — the reading the Dart side takes.
    let visible = CGRect(x: 0, y: 0, width: 1000, height: 800)

    for ratio in [
      OverlayStripRatio(displayId: "1", x: 1.4, y: -0.2),
      OverlayStripRatio(displayId: "1", x: .nan, y: .infinity),
    ] {
      let frame = OverlayPlacementGeometry.fractionalFrame(
        size: stripSize, ratio: ratio, inVisibleFrame: visible)

      XCTAssertTrue(visible.contains(frame), "\(ratio) resolved to \(frame)")
    }
  }

  func testAFractionThatWouldHangOffTheEdgeIsClampedInside() {
    // `x: 1` is the right-hand edge of the usable area, and the strip has a
    // width: placing its *left* edge there would put every control past the
    // display. §33.3 clamps on every show for exactly this.
    let visible = CGRect(x: 0, y: 0, width: 1000, height: 800)

    let frame = OverlayPlacementGeometry.fractionalFrame(
      size: stripSize,
      ratio: OverlayStripRatio(displayId: "1", x: 1, y: 1),
      inVisibleFrame: visible)

    XCTAssertEqual(frame.maxX, visible.maxX, accuracy: 0.001)
    XCTAssertEqual(frame.minY, visible.minY, accuracy: 0.001)
  }

  func testAStripWiderThanTheDisplayKeepsItsLeadingEdgeOnScreen() {
    // Pause and Stop are at the leading end; pinning there is what keeps them
    // clickable on a display too narrow for the whole strip.
    let visible = CGRect(x: 0, y: 0, width: 300, height: 800)

    let frame = OverlayPlacementGeometry.clamped(
      CGRect(x: 900, y: 400, width: 372, height: 50), inVisibleFrame: visible)

    XCTAssertEqual(frame.minX, visible.minX, accuracy: 0.001)
    XCTAssertEqual(frame.width, 372, accuracy: 0.001)
  }

  func testAZeroSizedUsableAreaNamesNoFractionAndPlacesNoStripOutsideIt() {
    // A display that reports nothing usable is the `DisplayGeometry.unknown`
    // case one layer down. Reading a position must say "cannot", not invent a
    // 0,0 that would be stored as the user's chosen spot.
    let empty = CGRect(x: 0, y: 0, width: 0, height: 0)

    XCTAssertNil(
      OverlayPlacementGeometry.positionRatio(
        of: CGRect(x: 10, y: 10, width: 372, height: 50),
        inVisibleFrame: empty, displayId: "1"))

    let frame = OverlayPlacementGeometry.fractionalFrame(
      size: stripSize,
      ratio: OverlayStripRatio(displayId: "1", x: 0.5, y: 0.5),
      inVisibleFrame: empty)
    XCTAssertEqual(frame.origin, empty.origin)
  }

  func testAPositionWithNoDisplayToNameIsNotReported() {
    XCTAssertNil(
      OverlayPlacementGeometry.positionRatio(
        of: CGRect(x: 10, y: 10, width: 372, height: 50),
        inVisibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
        displayId: ""))
  }

  // MARK: - snapping (§33.3)

  func testADragEndingNearAnEdgeLandsOnIt() {
    let visible = CGRect(x: 0, y: 76, width: 1728, height: 1000)

    let left = OverlayPlacementGeometry.snapped(
      CGRect(x: 18, y: 500, width: 372, height: 50), inVisibleFrame: visible)
    XCTAssertEqual(left.minX, visible.minX, accuracy: 0.001)

    let right = OverlayPlacementGeometry.snapped(
      CGRect(x: 1728 - 372 - 9, y: 500, width: 372, height: 50),
      inVisibleFrame: visible)
    XCTAssertEqual(right.maxX, visible.maxX, accuracy: 0.001)

    let top = OverlayPlacementGeometry.snapped(
      CGRect(x: 700, y: visible.maxY - 50 - 11, width: 372, height: 50),
      inVisibleFrame: visible)
    XCTAssertEqual(top.maxY, visible.maxY, accuracy: 0.001)

    let bottom = OverlayPlacementGeometry.snapped(
      CGRect(x: 700, y: visible.minY + 23, width: 372, height: 50),
      inVisibleFrame: visible)
    XCTAssertEqual(bottom.minY, visible.minY, accuracy: 0.001)
  }

  func testADragEndingNearTheHorizontalCentreLandsOnIt() {
    let visible = CGRect(x: 0, y: 0, width: 1728, height: 1000)
    let centred = visible.midX - 372 / 2

    let frame = OverlayPlacementGeometry.snapped(
      CGRect(x: centred + 20, y: 500, width: 372, height: 50),
      inVisibleFrame: visible)

    XCTAssertEqual(frame.midX, visible.midX, accuracy: 0.001)
  }

  func testThereIsNoVerticalCentreToSnapTo() {
    // §33.3 snaps to the edges and to the *horizontal* centre. A strip left in
    // the middle of the screen stays exactly where it was let go.
    let visible = CGRect(x: 0, y: 0, width: 1728, height: 1000)
    let dropped = CGRect(x: 200, y: visible.midY - 25 + 3, width: 372, height: 50)

    let frame = OverlayPlacementGeometry.snapped(
      dropped, inVisibleFrame: visible)

    XCTAssertEqual(frame.minY, dropped.minY, accuracy: 0.001)
  }

  func testADragEndingBeyondTheDistanceIsLeftWhereItWas() {
    let visible = CGRect(x: 0, y: 0, width: 1728, height: 1000)
    let dropped = CGRect(x: 25, y: 500, width: 372, height: 50)

    let frame = OverlayPlacementGeometry.snapped(
      dropped, inVisibleFrame: visible)

    XCTAssertEqual(frame.minX, dropped.minX, accuracy: 0.001)
  }

  func testAnEdgeTakesATieAgainstTheCentre() {
    // On a display barely wider than the strip, the leading edge and the centre
    // line are both in range and exactly as far away. Pulling the strip off the
    // edge is the wrong half of that tie, so the edges are tried first.
    let visible = CGRect(x: 0, y: 0, width: 372 + 20, height: 1000)
    let dropped = CGRect(x: 5, y: 500, width: 372, height: 50)

    let frame = OverlayPlacementGeometry.snapped(dropped, inVisibleFrame: visible)

    XCTAssertEqual(frame.minX, visible.minX, accuracy: 0.001)
  }

  func testASnapNeverPushesTheStripOffTheUsableArea() {
    // The strip is wider than the display, so the centre line it is closest to
    // hangs off both edges at once. A snap is a hint; the clamp is not.
    let visible = CGRect(x: 0, y: 0, width: 300, height: 800)
    let dropped = CGRect(x: -30, y: 400, width: 372, height: 50)

    let frame = OverlayPlacementGeometry.snapped(
      dropped, inVisibleFrame: visible)

    XCTAssertEqual(frame.minX, visible.minX, accuracy: 0.001)
    XCTAssertGreaterThanOrEqual(frame.minY, visible.minY - 0.001)
  }

  func testADragOntoADisplayIsStoredAgainstThatDisplay() {
    // The strip belongs to whichever display holds its centre when the drag
    // ends — deliberately not §5's current display.
    let second = CGRect(x: -1728, y: 240, width: 1728, height: 1000)
    let dropped = CGRect(x: -1000, y: 700, width: 372, height: 50)

    let ratio = OverlayPlacementGeometry.positionRatio(
      of: dropped, inVisibleFrame: second, displayId: "69733382")

    XCTAssertEqual(ratio?.displayId, "69733382")
    XCTAssertEqual(ratio?.x ?? -1, (dropped.minX - second.minX) / second.width,
      accuracy: 0.0001)
  }
}
