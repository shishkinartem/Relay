import XCTest

@testable import RecorderCore

/// What the camera preview window draws, in each of the two modes (§33.5).
///
/// These are regression tests for a window-mode preview that inherited the
/// tile's crop and its mask. The preview window is the picture-in-picture only
/// in display mode (design `1p`); in window mode it is a separate captioned
/// object that is deliberately not the tile (design `1e`), so the `circle`
/// preset — chosen for the *file* — was masking a window that stands for a tile
/// nobody can see, and `cover` was cropping a frame it is supposed to letterbox
/// whole.
final class CameraPreviewPresentationTests: XCTestCase {
  /// The tile as Dart sends it for `Circle · small`: cropped by the preset, and
  /// masked to a circle by a corner radius of half its width.
  private func circlePreset() -> CameraOverlayConfiguration {
    CameraOverlayConfiguration(map: [
      "preset": CameraPipPreset.circle.rawValue,
      "cornerRadiusRatio": 0.5,
    ])
  }

  // MARK: - display mode: the preview *is* the tile

  func testDisplayModeTakesTheTilesCropAndMask() {
    let presentation = CameraPreviewPresentation.resolve(
      configuration: circlePreset(), matchesCompositedPip: true)

    XCTAssertEqual(presentation.fit, .cover)
    XCTAssertEqual(presentation.cornerRadiusRatio, 0.5)
  }

  func testTheDefaultPresetStillNeverCrops() {
    let presentation = CameraPreviewPresentation.resolve(
      configuration: CameraOverlayConfiguration(), matchesCompositedPip: true)

    XCTAssertEqual(presentation.fit, .contain)
    XCTAssertEqual(presentation.cornerRadiusRatio, 0)
  }

  // MARK: - window mode: the preview is not the tile

  func testWindowModeLetterboxesWhateverThePresetSays() {
    let presentation = CameraPreviewPresentation.resolve(
      configuration: circlePreset(), matchesCompositedPip: false)

    XCTAssertEqual(presentation.fit, .contain)
    XCTAssertEqual(presentation.cornerRadiusRatio, 0)
  }

  func testWindowModeIsUnchangedByAnyConfiguredCornerRadius() {
    var overlay = CameraOverlayConfiguration()
    overlay.cornerRadiusRatio = 0.25

    let presentation = CameraPreviewPresentation.resolve(
      configuration: overlay, matchesCompositedPip: false)

    XCTAssertEqual(presentation, CameraPreviewPresentation.letterboxed)
  }

  // MARK: - no tile at all

  func testNoConfigurationLetterboxesInEitherMode() {
    // `matchesCompositedPip` true with no configuration is the shape the
    // contract forbids — the tile is what the mode is *for* — but a host with
    // nothing to resolve must still draw the whole frame rather than guess a
    // crop.
    for mode in [true, false] {
      XCTAssertEqual(
        CameraPreviewPresentation.resolve(
          configuration: nil, matchesCompositedPip: mode),
        CameraPreviewPresentation.letterboxed)
    }
  }
}
