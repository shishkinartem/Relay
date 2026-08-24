import XCTest

@testable import RecorderCore

/// The camera picture-in-picture rectangle (§7, design `1p`).
///
/// CLAUDE.md states the invariant outright: lower-right corner, 0.16 of the
/// canvas width, the camera's *own* aspect ratio, 0.01 margin — and the frame
/// is never cropped and never distorted, in the file or in the preview. That
/// last clause is a property of this arithmetic and of nothing else, and until
/// now nothing executed it.
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

  func testOnlyTopCornersPinTheirTopEdge() {
    // Which edge is pinned decides which way the tile grows when the camera's
    // shape changes mid-session. Getting it wrong moves the tile off the
    // corner it is supposed to be anchored to.
    for corner in ["topLeft", "topRight"] {
      var overlay = CameraOverlayConfiguration()
      overlay.corner = corner
      XCTAssertTrue(overlay.pinsTopEdge, corner)
    }
    for corner in ["bottomLeft", "bottomRight"] {
      var overlay = CameraOverlayConfiguration()
      overlay.corner = corner
      XCTAssertFalse(overlay.pinsTopEdge, corner)
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
      "widthRatio": 0.25,
      "aspectRatio": 4.0 / 3.0,
      "followsSourceAspectRatio": false,
      "cornerRadius": 8.0,
      "marginRatio": 0.05,
      "corner": "topLeft",
      "mirrorPreview": false,
      "mirrorOutput": true,
    ])

    XCTAssertEqual(overlay.widthRatio, 0.25)
    XCTAssertEqual(overlay.aspectRatio, 4.0 / 3.0)
    XCTAssertFalse(overlay.followsSourceAspectRatio)
    XCTAssertEqual(overlay.cornerRadius, 8.0)
    XCTAssertEqual(overlay.marginRatio, 0.05)
    XCTAssertEqual(overlay.corner, "topLeft")
    XCTAssertFalse(overlay.mirrorPreview)
    XCTAssertTrue(overlay.mirrorOutput)
  }

  func testAnEmptyMapKeepsTheSpecifiedDefaults() {
    let overlay = CameraOverlayConfiguration(map: [:])

    XCTAssertEqual(overlay.widthRatio, 0.16)
    XCTAssertEqual(overlay.marginRatio, 0.01)
    XCTAssertEqual(overlay.corner, "bottomRight")
    XCTAssertTrue(overlay.followsSourceAspectRatio)
    XCTAssertTrue(overlay.mirrorPreview, "the preview is mirrored")
    XCTAssertFalse(overlay.mirrorOutput, "the file is not")
  }
}
