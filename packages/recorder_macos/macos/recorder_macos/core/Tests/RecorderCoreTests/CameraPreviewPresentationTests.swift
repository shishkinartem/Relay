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

  // MARK: - the shape is the tile's, in both modes

  func testDisplayModeTakesTheTilesCropAndMask() {
    let presentation = CameraPreviewPresentation.resolve(
      configuration: circlePreset())

    XCTAssertEqual(presentation.fit, .cover)
    XCTAssertEqual(presentation.cornerRadiusRatio, 0.5)
  }

  func testTheDefaultPresetStillNeverCrops() {
    let presentation = CameraPreviewPresentation.resolve(
      configuration: CameraOverlayConfiguration())

    XCTAssertEqual(presentation.fit, .contain)
    XCTAssertEqual(presentation.cornerRadiusRatio, 0)
  }

  /// This asserted the opposite until 2026-08-30, on the reasoning that the
  /// window-mode preview is a separate captioned object and not the tile.
  ///
  /// The premise is right and the conclusion was wrong: design `1e` constrains
  /// the *panel*, and the compositor has no source-type gate — a window
  /// recording gets the circle in the file exactly as a display recording does.
  /// So all three presets looked identical on screen while the MP4 differed,
  /// and a user who chose `Circle` by name could not see what they had chosen.
  func testWindowModeCarriesThePresetsCropAndMaskToo() {
    let presentation = CameraPreviewPresentation.resolve(
      configuration: circlePreset())

    XCTAssertEqual(presentation.fit, .cover)
    XCTAssertEqual(presentation.cornerRadiusRatio, 0.5)
  }

  /// The mask is applied to the picture, never to the window: what differs
  /// between the modes is the box, which is why the mode is no longer a
  /// parameter here at all.
  func testTheModeIsNotPartOfThisDecision() {
    var overlay = CameraOverlayConfiguration()
    overlay.cornerRadiusRatio = 0.25

    XCTAssertEqual(
      CameraPreviewPresentation.resolve(configuration: overlay),
      CameraPreviewPresentation(fit: .contain, cornerRadiusRatio: 0.25))
  }

  // MARK: - no tile at all

  func testNoConfigurationLetterboxes() {
    // A host with nothing to resolve must draw the whole frame rather than
    // guess a crop.
    XCTAssertEqual(
      CameraPreviewPresentation.resolve(configuration: nil),
      CameraPreviewPresentation.letterboxed)
  }
}
