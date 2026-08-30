import XCTest

@testable import RecorderCore

/// What the source picker is allowed to list (§4.1).
///
/// These are regression tests for a picker full of things that are not windows.
/// The rule this replaced accepted a window when its title *or* its application
/// name was non-empty, so every untitled surface the window server knows about
/// — wallpaper, menu-bar status items, the Dock, notification banners, offscreen
/// helper panels — arrived as a selectable entry labelled with an application
/// name and nothing else.
final class CapturableWindowTests: XCTestCase {
  private func window(
    title: String = "Untitled — main.dart",
    applicationName: String = "Visual Studio Code",
    width: CGFloat = 1200,
    height: CGFloat = 800,
    layer: Int = 0,
    isOnScreen: Bool = true,
    belongsToThisApplication: Bool = false,
    isExplicitlyExcluded: Bool = false
  ) -> CapturableWindowAttributes {
    CapturableWindowAttributes(
      title: title,
      applicationName: applicationName,
      width: width,
      height: height,
      layer: layer,
      isOnScreen: isOnScreen,
      belongsToThisApplication: belongsToThisApplication,
      isExplicitlyExcluded: isExplicitlyExcluded)
  }

  // MARK: - the windows a user means

  func testAnOrdinaryDocumentWindowIsOffered() {
    XCTAssertTrue(CapturableWindowRule.isCapturable(window()))
  }

  func testAWindowExactlyAtTheMinimumEdgeIsOffered() {
    let edge = CapturableWindowRule.minimumEdge

    XCTAssertTrue(CapturableWindowRule.isCapturable(window(width: edge, height: edge)))
  }

  // MARK: - the things that are not windows

  func testAnUntitledWindowIsNotOffered() {
    XCTAssertFalse(CapturableWindowRule.isCapturable(window(title: "")))
  }

  func testAWhitespaceOnlyTitleIsNotATitle() {
    XCTAssertFalse(CapturableWindowRule.isCapturable(window(title: "   \n")))
  }

  func testAStatusItemAboveTheNormalLayerIsNotOffered() {
    // A menu-bar extra sits at level 25 and is titled; only the level tells it
    // apart from a document window.
    XCTAssertFalse(
      CapturableWindowRule.isCapturable(window(title: "Item-0", layer: 25)))
  }

  func testADesktopLayerWindowIsNotOffered() {
    XCTAssertFalse(CapturableWindowRule.isCapturable(window(layer: -2_147_483_603)))
  }

  func testAWindowWithNoOwningApplicationNameIsNotOffered() {
    XCTAssertFalse(CapturableWindowRule.isCapturable(window(applicationName: "")))
  }

  func testAnOffscreenWindowIsNotOffered() {
    XCTAssertFalse(CapturableWindowRule.isCapturable(window(isOnScreen: false)))
  }

  func testATinyHelperSurfaceIsNotOffered() {
    XCTAssertFalse(CapturableWindowRule.isCapturable(window(width: 64, height: 40)))
  }

  // MARK: - our own surfaces

  func testOurOwnWindowsAreNeverACaptureTarget() {
    XCTAssertFalse(
      CapturableWindowRule.isCapturable(
        window(title: "Recorder", belongsToThisApplication: true)))
  }

  func testAnExplicitlyExcludedOverlayIsNeverACaptureTarget() {
    XCTAssertFalse(
      CapturableWindowRule.isCapturable(window(isExplicitlyExcluded: true)))
  }
}
