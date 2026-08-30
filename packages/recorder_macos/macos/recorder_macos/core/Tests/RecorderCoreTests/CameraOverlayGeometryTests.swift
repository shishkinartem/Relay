import XCTest

@testable import RecorderCore

/// The camera picture-in-picture rectangle (§7, §33.5, design `1p`).
///
/// The invariant, as amended by
/// `docs/adr/2026-08-30-user-adjustable-camera-pip.md`: the frame is never
/// distorted, and is cropped only by an explicit shape preset — identically in
/// the preview and in the file. The default is still the lower-right corner at
/// 0.16 of the canvas width, in the camera's own shape, with a 0.01 margin.
///
/// This is the Swift half of arithmetic that exists in three languages. The
/// authority is `CameraOverlayConfiguration.resolveRect` in
/// `recorder_platform_interface`; these cases pin the mirror to it, clamp and
/// corner snap included.
final class CameraOverlayGeometryTests: XCTestCase {
  private let canvas = (width: 1920.0, height: 1080.0)

  func testTheDefaultTileMatchesTheSpecifiedProportions() {
    let overlay = CameraOverlayConfiguration()
    let rect = overlay.rect(canvasWidth: canvas.width, canvasHeight: canvas.height)

    XCTAssertEqual(rect.width, canvas.width * 0.16, accuracy: 0.001)
    XCTAssertEqual(overlay.marginRatio, 0.01)
    XCTAssertEqual(overlay.corner, "bottomRight")
  }

  func testTheTileSitsInTheLowerRightWithAMarginOnBothEdges() {
    let overlay = CameraOverlayConfiguration()
    let rect = overlay.rect(canvasWidth: canvas.width, canvasHeight: canvas.height)
    let margin = canvas.width * 0.01

    // The margin is a fraction of the *width* on both axes, so the visual gap
    // is equal on the two edges the tile is anchored to.
    XCTAssertEqual(canvas.width - rect.maxX, margin, accuracy: 0.001)
    XCTAssertEqual(canvas.height - rect.maxY, margin, accuracy: 0.001)
  }

  func testTheTileTakesTheCameraShapeRatherThanItsOwn() {
    var overlay = CameraOverlayConfiguration()
    overlay.aspectRatio = 16.0 / 9.0
    overlay.followsSourceAspectRatio = true

    // A 4:3 camera in a 16:9 tile can only be fitted by cropping or stretching.
    // Taking the camera's shape removes the choice, which is what "never
    // cropped and never distorted" means in practice.
    let rect = overlay.rect(
      canvasWidth: canvas.width, canvasHeight: canvas.height,
      sourceAspectRatio: 4.0 / 3.0)

    XCTAssertEqual(rect.width / rect.height, 4.0 / 3.0, accuracy: 0.0001)
  }

  func testAPortraitCameraIsNotForcedIntoALandscapeTile() {
    var overlay = CameraOverlayConfiguration()
    overlay.followsSourceAspectRatio = true

    let rect = overlay.rect(
      canvasWidth: canvas.width, canvasHeight: canvas.height,
      sourceAspectRatio: 9.0 / 16.0)

    XCTAssertEqual(rect.width / rect.height, 9.0 / 16.0, accuracy: 0.0001)
    XCTAssertGreaterThan(rect.height, rect.width, "a portrait tile stays tall")
  }

  func testTheFallbackRatioIsUsedWhenTheCameraShapeIsUnknown() {
    var overlay = CameraOverlayConfiguration()
    overlay.aspectRatio = 16.0 / 9.0
    overlay.followsSourceAspectRatio = true

    // Before the first camera frame there is no source ratio to follow. The
    // configured fallback is what Dart used to place the preview window, so
    // using anything else here would put the preview and the composited tile
    // in different places.
    let rect = overlay.rect(
      canvasWidth: canvas.width, canvasHeight: canvas.height,
      sourceAspectRatio: nil)

    XCTAssertEqual(rect.width / rect.height, 16.0 / 9.0, accuracy: 0.0001)
  }

  func testFollowingIsHonouredOnlyWhenItIsSwitchedOn() {
    var overlay = CameraOverlayConfiguration()
    overlay.aspectRatio = 16.0 / 9.0
    overlay.followsSourceAspectRatio = false

    let rect = overlay.rect(
      canvasWidth: canvas.width, canvasHeight: canvas.height,
      sourceAspectRatio: 1.0)

    XCTAssertEqual(rect.width / rect.height, 16.0 / 9.0, accuracy: 0.0001)
  }

  func testADegenerateSourceRatioFallsBack() {
    var overlay = CameraOverlayConfiguration()
    overlay.aspectRatio = 16.0 / 9.0

    // A camera that reports a zero or negative dimension would otherwise
    // divide the tile height by zero and produce a rectangle nothing can draw.
    for bad in [0.0, -1.5] {
      let rect = overlay.rect(
        canvasWidth: canvas.width, canvasHeight: canvas.height,
        sourceAspectRatio: bad)
      XCTAssertTrue(rect.height.isFinite && rect.height > 0)
      XCTAssertEqual(rect.width / rect.height, 16.0 / 9.0, accuracy: 0.0001)
    }
  }

  func testAMalformedFallbackRatioFallsBackToSixteenByNine() {
    // The same malformed configuration must draw the same tile on both
    // platforms. It did not: this clamped to 0.0001 and produced a sliver,
    // while `ResolvePipRect` on Windows produced a square. Dart cannot see the
    // difference, so nothing would ever have reported it.
    var overlay = CameraOverlayConfiguration()
    overlay.aspectRatio = 0
    overlay.followsSourceAspectRatio = false

    let rect = overlay.rect(canvasWidth: canvas.width, canvasHeight: canvas.height)
    XCTAssertTrue(rect.height.isFinite)
    XCTAssertEqual(rect.width / rect.height, 16.0 / 9.0, accuracy: 0.0001)
  }

  func testEveryCornerAnchorsToItsOwnTwoEdges() {
    let margin = canvas.width * 0.01

    for corner in ["topLeft", "topRight", "bottomLeft", "bottomRight"] {
      var overlay = CameraOverlayConfiguration()
      overlay.corner = corner
      let rect = overlay.rect(
        canvasWidth: canvas.width, canvasHeight: canvas.height)

      if corner.hasSuffix("Left") {
        XCTAssertEqual(rect.minX, margin, accuracy: 0.001, "\(corner) left edge")
      } else {
        XCTAssertEqual(
          canvas.width - rect.maxX, margin, accuracy: 0.001, "\(corner) right edge")
      }
      if corner.hasPrefix("top") {
        XCTAssertEqual(rect.minY, margin, accuracy: 0.001, "\(corner) top edge")
      } else {
        XCTAssertEqual(
          canvas.height - rect.maxY, margin, accuracy: 0.001, "\(corner) bottom edge")
      }
    }
  }

  func testTheTileStaysInsideTheCanvas() {
    var overlay = CameraOverlayConfiguration()
    overlay.followsSourceAspectRatio = true

    for ratio in [0.5, 1.0, 4.0 / 3.0, 16.0 / 9.0, 2.35] {
      let rect = overlay.rect(
        canvasWidth: canvas.width, canvasHeight: canvas.height,
        sourceAspectRatio: ratio)
      XCTAssertGreaterThanOrEqual(rect.minX, 0, "ratio \(ratio)")
      XCTAssertGreaterThanOrEqual(rect.minY, 0, "ratio \(ratio)")
      XCTAssertLessThanOrEqual(rect.maxX, canvas.width, "ratio \(ratio)")
      XCTAssertLessThanOrEqual(rect.maxY, canvas.height, "ratio \(ratio)")
    }
  }

  func testDecodingFromDartKeepsEveryValue() {
    // Nothing here is a compositor constant: every number arrives from Dart as
    // configuration (§28). A dropped key would silently substitute a default
    // and move the tile.
    let overlay = CameraOverlayConfiguration(map: [
      "preset": "square",
      "widthRatio": 0.25,
      "aspectRatio": 4.0 / 3.0,
      "followsSourceAspectRatio": false,
      "cornerRadiusRatio": 0.5,
      "marginRatio": 0.05,
      "corner": "topLeft",
      "fit": "cover",
      "positionX": 0.25,
      "positionY": 0.75,
      "mirrorPreview": false,
      "mirrorOutput": true,
    ])

    XCTAssertEqual(overlay.preset, .square)
    XCTAssertEqual(overlay.widthRatio, 0.25)
    XCTAssertEqual(overlay.aspectRatio, 4.0 / 3.0)
    XCTAssertFalse(overlay.followsSourceAspectRatio)
    XCTAssertEqual(overlay.cornerRadiusRatio, 0.5)
    XCTAssertEqual(overlay.marginRatio, 0.05)
    XCTAssertEqual(overlay.corner, "topLeft")
    XCTAssertEqual(overlay.fit, .cover)
    XCTAssertEqual(overlay.position?.x, 0.25)
    XCTAssertEqual(overlay.position?.y, 0.75)
    XCTAssertFalse(overlay.mirrorPreview)
    XCTAssertTrue(overlay.mirrorOutput)
  }

  func testAnEmptyMapKeepsTheSpecifiedDefaults() {
    let overlay = CameraOverlayConfiguration(map: [:])

    XCTAssertEqual(overlay.preset, .camera)
    XCTAssertEqual(overlay.widthRatio, 0.16)
    XCTAssertEqual(overlay.marginRatio, 0.01)
    XCTAssertEqual(overlay.corner, "bottomRight")
    XCTAssertEqual(overlay.cornerRadiusRatio, 0)
    XCTAssertEqual(overlay.fit, .contain, "the default never crops")
    XCTAssertNil(overlay.position, "no position is the corner, not 0,0")
    XCTAssertTrue(overlay.followsSourceAspectRatio)
    XCTAssertTrue(overlay.mirrorPreview, "the preview is mirrored")
    XCTAssertFalse(overlay.mirrorOutput, "the file is not")
  }

  // MARK: - presets (§33.5)

  func testAPresetThisBuildDoesNotKnowIsTheDefaultOne() {
    // The same reading Dart's decoder takes. It matters because `fit` is
    // decoded separately: a preset nobody recognises must not silently start
    // cropping, and must not silently stop.
    XCTAssertEqual(CameraPipPreset(name: "hexagon"), .camera)
    XCTAssertEqual(CameraPipPreset(name: nil), .camera)
    XCTAssertTrue(CameraPipPreset.camera.keepsWholeFrame)
    XCTAssertFalse(CameraPipPreset.square.keepsWholeFrame)
    XCTAssertFalse(CameraPipPreset.circle.keepsWholeFrame)
  }

  func testTheShapePresetsCropAndTheDefaultDoesNot() {
    XCTAssertEqual(CameraOverlayConfiguration(map: ["preset": "camera"]).fit, .contain)
    XCTAssertEqual(CameraOverlayConfiguration(map: ["preset": "square"]).fit, .cover)
    XCTAssertEqual(CameraOverlayConfiguration(map: ["preset": "circle"]).fit, .cover)
  }

  func testTheWireFitWinsOverAPresetThisBuildCannotRead() {
    // A newer Dart asking for a crop under a preset this build reads as
    // `camera` would otherwise show the whole frame — a disagreement between
    // the preview and the file, which is the one thing design `1p` forbids.
    let overlay = CameraOverlayConfiguration(map: ["preset": "hexagon", "fit": "cover"])

    XCTAssertEqual(overlay.preset, .camera)
    XCTAssertEqual(overlay.fit, .cover)
  }

  func testTheCameraPresetIsCappedAtTheSpecifiedWidth() {
    let overlay = CameraOverlayConfiguration()

    // A 1280-wide camera on a 1920-wide canvas asks for 0.66 and gets the cap,
    // so an ordinary session looks exactly as it did before presets existed.
    XCTAssertEqual(
      overlay.effectiveWidthRatio(canvasWidth: canvas.width, sourceWidth: 1280),
      0.16, accuracy: 0.0001)
  }

  func testACameraNarrowerThanTheCapIsNeverUpscaledPastItsOwnPixels() {
    let overlay = CameraOverlayConfiguration()

    // 240 / 1920 = 0.125, under the cap and over the floor: the tile is the
    // camera's own width.
    XCTAssertEqual(
      overlay.effectiveWidthRatio(canvasWidth: canvas.width, sourceWidth: 240),
      0.125, accuracy: 0.0001)
  }

  func testAVeryNarrowCameraStopsAtTheFloor() {
    let overlay = CameraOverlayConfiguration()

    // A tile below 0.08 of the canvas cannot be read, so the floor wins over
    // the sensor's own width — the one place §33.5 accepts an upscale.
    XCTAssertEqual(
      overlay.effectiveWidthRatio(canvasWidth: canvas.width, sourceWidth: 32),
      0.08, accuracy: 0.0001)
  }

  func testTheFixedPresetsIgnoreTheCameraWidth() {
    // Their size is the point: `Square · small` is 0.10 of the canvas whatever
    // the sensor behind it is.
    for name in ["square", "circle"] {
      let overlay = CameraOverlayConfiguration(map: [
        "preset": name, "widthRatio": 0.10, "aspectRatio": 1.0,
        "followsSourceAspectRatio": false,
      ])
      XCTAssertEqual(
        overlay.effectiveWidthRatio(canvasWidth: canvas.width, sourceWidth: 240),
        0.10, accuracy: 0.0001, name)
      let rect = overlay.rect(
        canvasWidth: canvas.width, canvasHeight: canvas.height,
        sourceAspectRatio: 16.0 / 9.0, sourceWidth: 240)
      XCTAssertEqual(rect.width, canvas.width * 0.10, accuracy: 0.001, name)
      XCTAssertEqual(rect.width, rect.height, accuracy: 0.001, "\(name) is 1:1")
    }
  }

  func testContainFitsTheWholeFrameAndCoverFillsTheTile() {
    // The one place a frame is cropped, and it happens only because the user
    // named a shape the sensor is not. A 16:9 camera in a 192-point square:
    // `contain` scales by the width and leaves bars, `cover` scales by the
    // height and drops the sides.
    let source = CGSize(width: 1280, height: 720)
    let tile = CGSize(width: 192, height: 192)

    XCTAssertEqual(
      CameraPipFit.contain.scale(source: source, tile: tile), 192.0 / 1280.0,
      accuracy: 0.00001)
    XCTAssertEqual(
      CameraPipFit.cover.scale(source: source, tile: tile), 192.0 / 720.0,
      accuracy: 0.00001)
  }

  func testAFitOfEitherKindIsUniform() {
    // Both fits scale one number, so nothing is ever stretched: §33.5 dropped
    // "never cropped", it did not drop "never distorted".
    let source = CGSize(width: 1280, height: 720)
    let tile = CGSize(width: 300, height: 300)

    for fit in [CameraPipFit.contain, CameraPipFit.cover] {
      let scale = fit.scale(source: source, tile: tile)
      let drawn = CGSize(width: source.width * scale, height: source.height * scale)
      XCTAssertEqual(
        Double(drawn.width / drawn.height), Double(source.width / source.height),
        accuracy: 0.0001, "\(fit)")
    }
  }

  func testACoverFitOnATileTheCameraShapeIsTheSameAsContain() {
    // The default preset asks for the camera's own shape, so its "crop" takes
    // nothing: the two fits agree, which is why the default never crops.
    let source = CGSize(width: 1280, height: 720)
    let tile = CGSize(width: 320, height: 180)

    XCTAssertEqual(
      CameraPipFit.cover.scale(source: source, tile: tile),
      CameraPipFit.contain.scale(source: source, tile: tile), accuracy: 0.00001)
  }

  func testADegenerateFrameIsDrawnRatherThanScaledByZero() {
    XCTAssertEqual(
      CameraPipFit.cover.scale(source: .zero, tile: CGSize(width: 10, height: 10)),
      1)
    XCTAssertEqual(
      CameraPipFit.contain.scale(
        source: CGSize(width: 10, height: 10), tile: .zero), 1)
  }

  func testTheCircleIsTheSquareWithHalfItsWidthAsARadius() {
    let overlay = CameraOverlayConfiguration(map: [
      "preset": "circle", "widthRatio": 0.10, "aspectRatio": 1.0,
      "followsSourceAspectRatio": false, "cornerRadiusRatio": 0.5,
    ])
    let rect = overlay.rect(canvasWidth: canvas.width, canvasHeight: canvas.height)

    // A ratio, not pixels: the same configuration has to describe the same
    // shape on a 720p canvas, a 1080p one and the preview window.
    XCTAssertEqual(
      overlay.cornerRadius(forTileWidth: Double(rect.width)), Double(rect.width) / 2,
      accuracy: 0.001)
  }

  func testAnOutOfRangeWidthIsPulledIntoTheStatedBounds() {
    XCTAssertEqual(
      CameraOverlayConfiguration(map: ["widthRatio": 0.9]).widthRatio, 0.50)
    XCTAssertEqual(
      CameraOverlayConfiguration(map: ["widthRatio": 0.01]).widthRatio, 0.08)
    XCTAssertEqual(
      CameraOverlayConfiguration(map: ["cornerRadiusRatio": 2.0]).cornerRadiusRatio,
      0.5)
  }

  // MARK: - the free position (§33.5)

  func testAFreePositionPlacesTheTileWhereItWasDropped() {
    let overlay = CameraOverlayConfiguration(map: [
      "positionX": 0.25, "positionY": 0.5,
    ])
    let rect = overlay.rect(canvasWidth: canvas.width, canvasHeight: canvas.height)

    XCTAssertEqual(rect.minX, canvas.width * 0.25, accuracy: 0.001)
    XCTAssertEqual(rect.minY, canvas.height * 0.5, accuracy: 0.001)
  }

  func testHalfAPositionIsNoPosition() {
    // A tile placed on one axis and cornered on the other is a shape nobody
    // asked for, which is the rule Dart decodes by.
    XCTAssertNil(CameraOverlayConfiguration(map: ["positionX": 0.25]).position)
    XCTAssertNil(CameraOverlayConfiguration(map: ["positionY": 0.25]).position)
  }

  func testADragPastTheEdgeIsClampedToTheMargin() {
    let margin = canvas.width * 0.01
    let overlay = CameraOverlayConfiguration(map: [
      "positionX": 1.5, "positionY": -0.4,
    ])
    let rect = overlay.rect(
      canvasWidth: canvas.width, canvasHeight: canvas.height,
      sourceAspectRatio: 16.0 / 9.0)

    XCTAssertEqual(canvas.width - Double(rect.maxX), margin, accuracy: 0.001)
    XCTAssertEqual(Double(rect.minY), margin, accuracy: 0.001)
  }

  func testATileNearACornerSnapsOntoIt() {
    let margin = canvas.width * 0.01
    // Inside 2% of the canvas width of the bottom-right margin, which is the
    // snap §33.5 states.
    let overlay = CameraOverlayConfiguration(map: [
      "positionX": (canvas.width - margin - canvas.width * 0.16 - 12) / canvas.width,
      "positionY": 0.5,
    ])
    let rect = overlay.rect(
      canvasWidth: canvas.width, canvasHeight: canvas.height,
      sourceAspectRatio: 16.0 / 9.0)

    XCTAssertEqual(canvas.width - Double(rect.maxX), margin, accuracy: 0.001)
    XCTAssertEqual(Double(rect.minY), canvas.height * 0.5, accuracy: 0.001,
      "the axis that was nowhere near a corner does not move")
  }

  func testATileWellAwayFromACornerDoesNotSnap() {
    let left = canvas.width * 0.4
    let overlay = CameraOverlayConfiguration(map: [
      "positionX": 0.4, "positionY": 0.4,
    ])
    let rect = overlay.rect(canvasWidth: canvas.width, canvasHeight: canvas.height)

    XCTAssertEqual(Double(rect.minX), left, accuracy: 0.001)
  }

  func testAPositionIsTheInverseOfTheRectangleItResolvesTo() {
    // A drag reports points; they have to survive the trip back into a
    // fraction and out again, or the tile walks a little on every session.
    let position = CameraOverlayConfiguration.positionRatio(
      left: 480, top: 270, canvasWidth: canvas.width, canvasHeight: canvas.height)
    let overlay = CameraOverlayConfiguration().moved(to: position)
    let rect = overlay.rect(canvasWidth: canvas.width, canvasHeight: canvas.height)

    XCTAssertEqual(Double(rect.minX), 480, accuracy: 0.001)
    XCTAssertEqual(Double(rect.minY), 270, accuracy: 0.001)
  }

  func testAPositionOnACanvasOfNoSizeIsTheOrigin() {
    // A NaN position reaches a window as an origin AppKit places nowhere.
    let ratio = CameraOverlayConfiguration.positionRatio(
      left: 10, top: 10, canvasWidth: 0, canvasHeight: 0)

    XCTAssertEqual(ratio, .zero)
  }

  func testAResolvedWidthDescribesTheTileOnAnyCanvas() {
    // The cap is resolved against the encoder canvas, where the sensor's pixels
    // are the thing being compared; the result then places the preview window
    // on a display measured in points.
    let resolved = CameraOverlayConfiguration()
      .resolvedForCamera(canvasWidth: canvas.width, sourceWidth: 240)

    XCTAssertEqual(resolved.widthRatio, 0.125, accuracy: 0.0001)
    XCTAssertEqual(
      resolved.rect(canvasWidth: 1440, canvasHeight: 900).width, 1440 * 0.125,
      accuracy: 0.001)
  }
}
