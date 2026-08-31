import XCTest

@testable import RecorderCore

/// The window that carries the camera preview, and the tile drawn inside it
/// (§33.5, flutter/flutter#185394).
///
/// The preview was the last panel still being resized during a session: its
/// window frame *was* the tile rect, and the tile is `0.16 x canvas` at the
/// camera's own shape on one preset and a `0.10` square on the other two — so
/// `Camera → Square → Camera`, one press each way, drove a hosted `FlutterView`
/// through size A → B → A. That is the shape `FlutterBackBufferCache` can hand
/// the wrong surface for, and the raster thread then reads a null texture.
///
/// The window is now sized once to what *every* preset needs and only moved.
/// These cases pin the two decisions that makes: how big it has to be, and
/// where it goes so the tile is still exactly where the compositor draws it.
final class CameraPreviewWindowGeometryTests: XCTestCase {
  private let canvas = (width: 1920.0, height: 1080.0)

  /// A 16:9 camera on a 1080p canvas: the `camera` tile is 307.2 x 172.8 and
  /// both small tiles are 192 x 192.
  private func bounds(
    aspectRatio: Double? = 16.0 / 9.0, sourceWidth: Int? = nil,
    encoderCanvasWidth: Double = 0
  ) -> CGSize {
    CameraOverlayConfiguration().boundingTileSize(
      canvasWidth: canvas.width, canvasHeight: canvas.height,
      encoderCanvasWidth: encoderCanvasWidth, sourceAspectRatio: aspectRatio,
      sourceWidth: sourceWidth)
  }

  // MARK: - how big the window has to be

  func testTheWindowHoldsTheWidestPresetAndTheTallestOne() {
    let size = bounds()

    // Width from `camera`, height from the square — neither preset alone.
    XCTAssertEqual(size.width, 307.2, accuracy: 0.001)
    XCTAssertEqual(size.height, 192, accuracy: 0.001)
  }

  func testEveryPresetFitsInsideTheOneWindow() {
    let size = bounds()

    for preset in [CameraPipPreset.camera, .square, .circle] {
      let tile = CameraOverlayConfiguration().sized(for: preset).rect(
        canvasWidth: canvas.width, canvasHeight: canvas.height,
        sourceAspectRatio: 16.0 / 9.0)
      XCTAssertLessThanOrEqual(tile.width, size.width + 0.001, "\(preset)")
      XCTAssertLessThanOrEqual(tile.height, size.height + 0.001, "\(preset)")
    }
  }

  func testATallCameraMakesTheWindowTallerThanAnySquare() {
    // A portrait sensor: the `camera` preset keeps its shape, so it is the
    // tallest of the three rather than the square being it.
    let size = bounds(aspectRatio: 3.0 / 4.0)

    XCTAssertEqual(size.width, 307.2, accuracy: 0.001)
    XCTAssertEqual(size.height, 307.2 * 4 / 3, accuracy: 0.001)
  }

  func testASensorNarrowerThanTheCapShrinksOnlyTheCameraPreset() {
    // The cap is resolved against the encoder canvas, where the sensor's own
    // pixels are the thing being compared. The square is a fixed fraction and
    // does not move, so it becomes the widest preset.
    let size = bounds(sourceWidth: 160, encoderCanvasWidth: 1920)

    XCTAssertEqual(size.width, 192, accuracy: 0.001)
    XCTAssertEqual(size.height, 192, accuracy: 0.001)
  }

  func testThePresetsSizeThemselvesTheWayDartBuildsThem() {
    // `sized(for:)` mirrors `CameraOverlayConfiguration.forPreset` in
    // `recorder_platform_interface`, which is the authority.
    let camera = CameraOverlayConfiguration().sized(for: .camera)
    XCTAssertEqual(camera.widthRatio, 0.16)
    XCTAssertTrue(camera.followsSourceAspectRatio)
    XCTAssertEqual(camera.fit, .contain)

    for preset in [CameraPipPreset.square, .circle] {
      let small = CameraOverlayConfiguration().sized(for: preset)
      XCTAssertEqual(small.widthRatio, 0.10, "\(preset)")
      XCTAssertEqual(small.aspectRatio, 1, "\(preset)")
      XCTAssertFalse(small.followsSourceAspectRatio, "\(preset)")
      XCTAssertEqual(small.fit, .cover, "\(preset)")
    }
    XCTAssertEqual(
      CameraOverlayConfiguration().sized(for: .circle).cornerRadiusRatio, 0.5)
    XCTAssertEqual(
      CameraOverlayConfiguration().sized(for: .square).cornerRadiusRatio, 0)
  }

  func testAPresetKeepsWhereTheTileWasPutAndOnlyChangesItsSize() {
    let placed = CameraOverlayConfiguration().moved(to: CGPoint(x: 0.4, y: 0.3))

    let square = placed.sized(for: .square)

    XCTAssertEqual(square.position?.x, 0.4)
    XCTAssertEqual(square.position?.y, 0.3)
    XCTAssertEqual(square.marginRatio, placed.marginRatio)
  }

  // MARK: - where the window goes

  private let display = CGRect(x: 0, y: 0, width: 1920, height: 1080)

  func testTheTileIsCentredInTheWindowWhereThereIsRoom() {
    let tile = CGRect(x: 800, y: 500, width: 192, height: 192)

    let window = OverlayPlacementGeometry.previewWindowFrame(
      tile: tile, size: CGSize(width: 307.2, height: 192), inDisplayFrame: display)

    XCTAssertEqual(window.midX, tile.midX, accuracy: 0.001)
    XCTAssertEqual(window.midY, tile.midY, accuracy: 0.001)
    XCTAssertTrue(window.contains(tile))
  }

  func testAWindowThatWouldHangOffTheDisplayIsPulledBackOn() {
    // Near an edge but with slack to spare: the window comes back onto the
    // display and the tile is still wholly inside it, just off-centre.
    let tile = CGRect(x: 8, y: 500, width: 192, height: 192)

    let window = OverlayPlacementGeometry.previewWindowFrame(
      tile: tile, size: CGSize(width: 307.2, height: 192), inDisplayFrame: display)

    XCTAssertEqual(window.minX, display.minX, accuracy: 0.001)
    XCTAssertTrue(window.contains(tile))
  }

  func testTheWidestPresetFlushToTheMarginStaysFlush() {
    // No slack at all on this axis: the window is exactly as wide as the tile,
    // so there is one place it can be and the display clamp must not move it.
    let tile = CGRect(x: 1920 - 19.2 - 307.2, y: 19.2, width: 307.2, height: 172.8)

    let window = OverlayPlacementGeometry.previewWindowFrame(
      tile: tile, size: CGSize(width: 307.2, height: 192), inDisplayFrame: display)

    XCTAssertTrue(window.contains(tile))
    XCTAssertEqual(window.minX, tile.minX, accuracy: 0.001)
  }

  func testHoldingTheTileBeatsStayingOnTheDisplay() {
    // A tile that is not wholly on the display being measured against — which
    // is what a drag towards a second screen looks like, because the canvas
    // stays the session's display (§5) while the window follows the pointer.
    // Pulling the window back onto that display would leave part of the tile
    // outside the window drawing it, and a tile with a piece missing is a
    // worse fault than a transparent edge hanging off a screen (design `1p`).
    let tile = CGRect(x: 1850, y: 500, width: 192, height: 192)

    let window = OverlayPlacementGeometry.previewWindowFrame(
      tile: tile, size: CGSize(width: 307.2, height: 192), inDisplayFrame: display)

    XCTAssertTrue(window.contains(tile))
    XCTAssertGreaterThan(
      window.maxX, display.maxX,
      "the window is allowed off the display; the tile is not allowed out of it")
  }

  func testAWindowOnASecondDisplayIsMeasuredAgainstThatDisplay() {
    let second = CGRect(x: -1920, y: 240, width: 1920, height: 1080)
    let tile = CGRect(x: -1920 + 19.2, y: 240 + 19.2, width: 192, height: 192)

    let window = OverlayPlacementGeometry.previewWindowFrame(
      tile: tile, size: CGSize(width: 307.2, height: 192), inDisplayFrame: second)

    XCTAssertTrue(window.contains(tile))
    XCTAssertGreaterThanOrEqual(window.minX, second.minX - 0.001)
    XCTAssertGreaterThanOrEqual(window.minY, second.minY - 0.001)
  }

  // MARK: - the rectangle the preview engine is told to draw in

  func testTheContentRectIsTheTileInTheWindowsOwnPointsTopLeftFirst() {
    // AppKit measures from the bottom, Flutter from the top, and every
    // rectangle that crosses the channel is expressed top-left.
    let window = CGRect(x: 100, y: 200, width: 307.2, height: 192)
    let tile = CGRect(x: 157.6, y: 200, width: 192, height: 192)

    let content = OverlayPlacementGeometry.contentRect(of: tile, inWindow: window)

    XCTAssertEqual(content.minX, 57.6, accuracy: 0.001)
    XCTAssertEqual(content.minY, 0, accuracy: 0.001)
    XCTAssertEqual(content.width, 192, accuracy: 0.001)
    XCTAssertEqual(content.height, 192, accuracy: 0.001)
  }

  func testTheContentRectFollowsTheWindowThatWasActuallyApplied() {
    // The no-shrink rule can hold a panel larger than the request, so the tile
    // is measured against the panel's real frame. A rect taken from the
    // requested one would draw the tile where it is not.
    let tile = CGRect(x: 157.6, y: 300, width: 192, height: 192)
    let held = CGRect(x: 100, y: 200, width: 400, height: 400)

    let content = OverlayPlacementGeometry.contentRect(of: tile, inWindow: held)

    XCTAssertEqual(content.minX, 57.6, accuracy: 0.001)
    XCTAssertEqual(content.minY, 600 - 492, accuracy: 0.001)
  }

  func testATileDraggedAndPutBackIsTheSameRectangleAgain() {
    // The round trip the drag makes: window frame plus content offset is the
    // tile on screen, which is what `settlePreviewAfterMove` reads back.
    let tile = CGRect(x: 640, y: 360, width: 192, height: 192)
    let window = OverlayPlacementGeometry.previewWindowFrame(
      tile: tile, size: CGSize(width: 307.2, height: 192), inDisplayFrame: display)
    let content = OverlayPlacementGeometry.contentRect(of: tile, inWindow: window)

    let restored = CGRect(
      x: window.minX + content.minX,
      y: window.maxY - content.minY - content.height,
      width: content.width, height: content.height)

    XCTAssertEqual(restored.minX, tile.minX, accuracy: 0.001)
    XCTAssertEqual(restored.minY, tile.minY, accuracy: 0.001)
    XCTAssertEqual(restored.width, tile.width, accuracy: 0.001)
    XCTAssertEqual(restored.height, tile.height, accuracy: 0.001)
  }

  // MARK: - the rule this exists to satisfy

  func testCameraSquareCameraNeverAsksThePanelForASecondSize() {
    // The alternation itself. One window size for all three presets means the
    // no-shrink rule sees one `grow` and then only moves — which is what
    // `panelSizeAction` needs to never hand back a stale surface.
    let size = bounds()
    var highWater: CGSize?
    var actions: [OverlayPlacementGeometry.PanelSizeAction] = []

    for _ in 0..<3 {
      let action = OverlayPlacementGeometry.panelSizeAction(
        requested: size, highWater: highWater, scale: 2, renderedScale: 2)
      if case .grow(let grown) = action { highWater = grown }
      actions.append(action)
    }

    XCTAssertEqual(actions.first, .grow(size))
    XCTAssertEqual(actions.dropFirst().filter { $0 != .move }, [])
  }
}
