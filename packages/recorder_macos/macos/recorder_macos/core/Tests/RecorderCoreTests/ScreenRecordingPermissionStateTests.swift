import XCTest

@testable import RecorderCore

final class ScreenRecordingPermissionStateTests: XCTestCase {
  func testGrantedWinsOverEveryFlag() {
    XCTAssertEqual(
      ScreenRecordingPermissionState.resolve(
        preflightGranted: true, askedThisRun: true, askedEver: true),
      "granted")
  }

  func testAskingInThisProcessIsPendingNotDenied() {
    // The regression this file exists for: the answer to a prompt raised in
    // this process cannot be read back here, and reporting it as a refusal is
    // what made the preflight relabel itself the instant the user pressed
    // Allow.
    XCTAssertEqual(
      ScreenRecordingPermissionState.resolve(
        preflightGranted: false, askedThisRun: true, askedEver: true),
      "pendingRelaunch")
  }

  func testAskedInAnEarlierProcessIsDenied() {
    XCTAssertEqual(
      ScreenRecordingPermissionState.resolve(
        preflightGranted: false, askedThisRun: false, askedEver: true),
      "denied")
  }

  func testNeverAskedIsNotDetermined() {
    XCTAssertEqual(
      ScreenRecordingPermissionState.resolve(
        preflightGranted: false, askedThisRun: false, askedEver: false),
      "notDetermined")
  }
}
