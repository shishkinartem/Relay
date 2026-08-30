import XCTest

@testable import RecorderCore

/// What the meter listens to, and when (§33.2, §33.7).
final class InputMeteringTests: XCTestCase {
  private func demand(startingWith ids: [String?]) -> InputMeterDemand {
    var demand = InputMeterDemand()
    for id in ids { demand.start(deviceId: id) }
    return demand
  }

  private func plan(
    _ demand: InputMeterDemand, live: Bool = false, tap: MeteringTap = .closed
  ) -> InputMeterPlan {
    demand.plan(liveCaptureIsRunning: live, tap: tap)
  }

  // MARK: - the device the caller named

  func testAStartOpensTheDeviceItNamedRatherThanTheDefault() {
    // The bar sits under a device row the user is choosing between two
    // microphones with. A meter on the system default would answer a question
    // nobody asked (§33.2).
    let demand = self.demand(startingWith: ["microphone:mv7"])
    XCTAssertEqual(plan(demand), .openTap(deviceId: "microphone:mv7"))
  }

  func testNoDeviceNamedIsThePlatformDefaultRatherThanNothingToOpen() {
    // Nil carries the same meaning it has on `RecordingConfiguration`: the
    // device a session with no chosen id would record.
    let demand = self.demand(startingWith: [nil])
    XCTAssertEqual(plan(demand), .openTap(deviceId: nil))
  }

  func testStartingAgainWithTheSameDeviceIsANoOp() {
    let demand = self.demand(startingWith: ["microphone:mv7", "microphone:mv7"])
    XCTAssertEqual(
      plan(demand, tap: .open(deviceId: "microphone:mv7")), .keepTap)
  }

  func testStartingAgainWithTheDefaultIsANoOpToo() {
    // `.open(deviceId: nil)` is a tap on the default, not a tap on nothing
    // known: comparing it as if the id were missing would reopen the device on
    // every start.
    let demand = self.demand(startingWith: [nil, nil])
    XCTAssertEqual(plan(demand, tap: .open(deviceId: nil)), .keepTap)
  }

  func testStartingAgainWithADifferentDeviceRePointsTheOneTap() {
    // Re-pointing, never a second handle: the plan names the new device while
    // the old tap is open, and the meter moves that tap onto it (§33.7).
    let demand = self.demand(startingWith: ["microphone:builtin", "microphone:mv7"])
    XCTAssertEqual(
      plan(demand, tap: .open(deviceId: "microphone:builtin")),
      .openTap(deviceId: "microphone:mv7"))
  }

  func testRePointingFromANamedDeviceBackToTheDefaultIsAlsoOneTap() {
    var demand = self.demand(startingWith: ["microphone:mv7"])
    demand.start(deviceId: nil)
    XCTAssertEqual(
      plan(demand, tap: .open(deviceId: "microphone:mv7")),
      .openTap(deviceId: nil))
  }

  // MARK: - counting

  func testWatchersAreCountedRatherThanStacked() {
    // Two meters on screen make one tap, and the tap closes when the last of
    // them stops (§33.2).
    var demand = self.demand(startingWith: ["microphone:mv7", "microphone:mv7"])
    demand.stop()
    XCTAssertTrue(demand.isWanted)
    XCTAssertEqual(
      plan(demand, tap: .open(deviceId: "microphone:mv7")), .keepTap)

    demand.stop()
    XCTAssertFalse(demand.isWanted)
    XCTAssertEqual(plan(demand, tap: .open(deviceId: "microphone:mv7")), .stop)
  }

  func testAStopWithNothingRunningIsANoOpRatherThanANegativeCount() {
    var demand = InputMeterDemand()
    demand.stop()
    demand.stop()
    XCTAssertEqual(demand.subscribers, 0)

    demand.start(deviceId: nil)
    XCTAssertEqual(demand.subscribers, 1, "one start, one watcher")
    XCTAssertEqual(plan(demand), .openTap(deviceId: nil))
  }

  func testTheLastStopForgetsTheDeviceItWasWatching() {
    // Nothing is metering, so nothing is remembered about what was: the next
    // start names its own device and must not be compared against a stale one.
    var demand = self.demand(startingWith: ["microphone:mv7"])
    demand.stop()
    XCTAssertNil(demand.deviceId)
  }

  func testDisposingForgetsEveryWatcher() {
    // No device may stay open for a meter nobody is watching.
    var demand = self.demand(startingWith: ["microphone:mv7", nil])
    demand.yieldToSession()
    demand.clear()
    XCTAssertEqual(demand, InputMeterDemand())
    XCTAssertEqual(plan(demand, tap: .open(deviceId: nil)), .stop)
  }

  // MARK: - a recording holds the device

  func testALiveCaptureIsReadRatherThanOpenedASecondTime() {
    // The one thing §33.7 forbids outright is a second `AVCaptureSession` on a
    // device the recording already holds.
    let demand = self.demand(startingWith: ["microphone:mv7"])
    XCTAssertEqual(plan(demand, live: true), .readLiveCapture)
    XCTAssertEqual(
      plan(demand, live: true, tap: .open(deviceId: "microphone:mv7")),
      .readLiveCapture,
      "an open tap is released in favour of the recording's own capture")
  }

  func testASessionThatIsNotRunningAMicrophoneLeavesTheDeviceFree() {
    // A prepared session whose microphone refused to open holds nothing, and a
    // meter that deferred to it would draw a flat bar for no reason.
    let demand = self.demand(startingWith: ["microphone:mv7"])
    XCTAssertEqual(plan(demand, live: false), .openTap(deviceId: "microphone:mv7"))
  }

  func testNobodyWatchingBeatsEverything() {
    var demand = InputMeterDemand()
    demand.yieldToSession()
    XCTAssertEqual(plan(demand, live: true), .stop)
  }

  // MARK: - the handover

  func testAYieldedMeterOpensNothingWhileTheSessionTakesTheDevice() {
    // The gap between closing the tap and the session's own capture starting is
    // where two handles on one microphone used to appear: anything that
    // reconciled inside it re-opened the tap.
    var demand = self.demand(startingWith: ["microphone:mv7"])
    demand.yieldToSession()
    XCTAssertEqual(plan(demand), .waitForSession)
    XCTAssertEqual(
      plan(demand, tap: .open(deviceId: "microphone:mv7")), .waitForSession,
      "a tap that is still open is closed, not kept")
  }

  func testAStartArrivingInsideTheHandoverOpensNothing() {
    // The gap is no longer instantaneous: the tap close is awaited rather than
    // blocked on, so a second meter appearing — or the user picking another
    // microphone — is far likelier to land inside it. Neither may open a device
    // the session is in the middle of taking (§33.7).
    var demand = self.demand(startingWith: ["microphone:mv7"])
    demand.yieldToSession()
    demand.start(deviceId: "microphone:builtin")

    XCTAssertEqual(
      plan(demand), .waitForSession,
      "the device the start named is opened after the handover, not inside it")
    XCTAssertEqual(
      plan(demand, tap: .open(deviceId: "microphone:mv7")), .waitForSession,
      "a tap still open from before the handover is closed, not re-pointed")
  }

  func testTheHandoverEndsWhetherTheSessionTookTheDeviceOrNot() {
    // A `prepare` that threw leaves nobody holding the microphone. A meter
    // still yielded to it would emit nothing for the rest of the session.
    var demand = self.demand(startingWith: ["microphone:mv7"])
    demand.yieldToSession()

    demand.sessionSettled()
    XCTAssertEqual(plan(demand, live: true), .readLiveCapture)
    XCTAssertEqual(plan(demand, live: false), .openTap(deviceId: "microphone:mv7"))
  }

  func testARecordingsCaptureIsReadEvenBeforeTheHandoverIsAcknowledged() {
    // The session started the microphone; which of the two calls arrives first
    // is not something the meter should depend on.
    var demand = self.demand(startingWith: [nil])
    demand.yieldToSession()
    XCTAssertEqual(plan(demand, live: true), .readLiveCapture)
  }

  // MARK: - a session that died rather than stopped

  func testASessionDyingMidRecordingHandsTheDeviceBack() {
    // The platform stopped the stream, or the writer failed underneath the
    // ticker: the session closes its microphone without reaching any of the
    // teardown paths the plugin drives. Left attached to a capture that has
    // stopped delivering buffers the meter emits `peak: 0` at 20 Hz, and a run
    // of zeroes is exactly what Dart counts before it tells the user a working
    // microphone is hearing nothing (§33.7).
    var demand = self.demand(startingWith: ["microphone:mv7"])
    demand.yieldToSession()
    demand.sessionSettled()
    XCTAssertEqual(plan(demand, live: true), .readLiveCapture)

    XCTAssertEqual(
      plan(demand, live: false), .openTap(deviceId: "microphone:mv7"),
      "the device the meter was asked for, not whatever the recording used")
  }

  func testARecordingAfterAFatalErrorTakesTheDeviceBackFromTheMeter() {
    // The user records again after a session died. The dead session's teardown
    // and the new `prepare` reach the meter through different doors on purpose,
    // and only the second of them may end a handover — a teardown nobody
    // ordered against the new `prepare` would otherwise re-open the tap on the
    // microphone that `prepare` is taking (§33.7).
    var demand = self.demand(startingWith: ["microphone:mv7"])
    demand.yieldToSession()
    demand.sessionSettled()
    XCTAssertEqual(plan(demand, live: false), .openTap(deviceId: "microphone:mv7"))

    demand.yieldToSession()
    XCTAssertEqual(
      plan(demand, live: false, tap: .open(deviceId: "microphone:mv7")),
      .waitForSession,
      "the second recording's handover closes the tap the first one left open")
  }
}
