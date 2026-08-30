import XCTest

@testable import RecorderCore

/// When a running capture has to be re-pointed at a new content filter (§6).
///
/// These are regression tests for an exclusion list that was always empty. The
/// filter is built in `prepare`, from the windows the window server was listing
/// at that moment — and every overlay this application owns is put on screen
/// *after* `prepare` returns: the control strip and the camera preview as the
/// session starts, the input menu the first time a chevron is pressed. Nothing
/// then brought them into the list, so §6's second mechanism named no window at
/// all and only each panel's `sharingType = .none` was keeping them out of the
/// file.
final class CaptureExclusionTests: XCTestCase {

  // MARK: - which sources need the list at all

  func testADisplaySourceNeedsTheExclusionList() {
    XCTAssertTrue(CaptureExclusionPolicy.isDisplaySource("display:1"))
  }

  func testAWindowSourceDoesNot() {
    // Nothing this application owns can get inside another window's own
    // content, so an overlay appearing changes nothing about that capture.
    XCTAssertFalse(CaptureExclusionPolicy.isDisplaySource("window:42"))
  }

  func testAMalformedSourceIdIsNotADisplay() {
    for id in ["", "display", "display:", "display:none", "screen:1", ":1"] {
      XCTAssertFalse(
        CaptureExclusionPolicy.isDisplaySource(id),
        "\(id) is not a display source")
    }
  }

  func testASourceIdWithAColonInItsPayloadIsStillRead() {
    // `filter(forSourceId:)` splits once and parses the rest, so anything the
    // number is not travels with it rather than making a third part.
    XCTAssertFalse(CaptureExclusionPolicy.isDisplaySource("display:1:2"))
  }

  // MARK: - the case that was broken

  func testAMenuOpenedAfterPrepareRebuildsTheFilter() {
    // The strip and the preview are in the list; the menu panel was created on
    // the first chevron press, long after the filter was built.
    XCTAssertTrue(
      CaptureExclusionPolicy.needsFilterRebuild(
        sourceId: "display:1",
        onScreenOverlayIDs: [11, 12, 13],
        excludedByFilter: [11, 12]))
  }

  func testAFirstRecordingRebuildsForEveryOverlay() {
    // Nothing is on screen when `prepare` runs, so the filter it built holds
    // nothing: the strip appearing is what has to put that right.
    XCTAssertTrue(
      CaptureExclusionPolicy.needsFilterRebuild(
        sourceId: "display:1", onScreenOverlayIDs: [11], excludedByFilter: []))
  }

  // MARK: - and the cases that must not spend a system call

  func testAnOverlayAlreadyInTheListIsNotRebuiltFor() {
    // A filter excludes by window id, and the id survives the panel being
    // ordered out and shown again — so a menu reopening is not a rebuild.
    XCTAssertFalse(
      CaptureExclusionPolicy.needsFilterRebuild(
        sourceId: "display:1",
        onScreenOverlayIDs: [11, 13],
        excludedByFilter: [11, 12, 13]))
  }

  func testNothingOnScreenIsNothingToExclude() {
    XCTAssertFalse(
      CaptureExclusionPolicy.needsFilterRebuild(
        sourceId: "display:1", onScreenOverlayIDs: [], excludedByFilter: []))
  }

  func testAWindowRecordingIsNeverRebuilt() {
    // Rebuilding one would ask the window server for a window that may have
    // closed since, and answer a running recording with `sourceClosed`.
    XCTAssertFalse(
      CaptureExclusionPolicy.needsFilterRebuild(
        sourceId: "window:42", onScreenOverlayIDs: [11], excludedByFilter: []))
  }

  func testAMalformedSourceIdIsNeverRebuilt() {
    XCTAssertFalse(
      CaptureExclusionPolicy.needsFilterRebuild(
        sourceId: "display:", onScreenOverlayIDs: [11], excludedByFilter: []))
  }
}
