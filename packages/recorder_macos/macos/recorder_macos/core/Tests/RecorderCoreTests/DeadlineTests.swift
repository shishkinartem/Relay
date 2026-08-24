import XCTest

@testable import RecorderCore

/// The bounded wait that stops a wedged capture stop from stranding a session.
///
/// `stopSources()` awaits `SCStream.stopCapture()`, which talks to a system
/// daemon. An unbounded await there is not a slow stop but a permanent one: the
/// session stays `.stopping`, a state both `stop()` and `abort()` refuse, and
/// the capture — with its screen-recording indicator — outlives every UI that
/// could stop it.
///
/// The first version of this helper raced the work against a sleeper inside a
/// `withTaskGroup` and did not bound anything, because a task group awaits every
/// child before it returns. It looked correct and shipped. These tests are what
/// distinguishes the two.
final class DeadlineTests: XCTestCase {
  func testWorkThatFinishesReturnsWithoutWaitingOutTheDeadline() async {
    let start = ContinuousClock.now
    var ran = false

    await Deadline.run(seconds: 30) {
      ran = true
    }

    XCTAssertTrue(ran)
    XCTAssertLessThan(
      start.duration(to: .now), .seconds(5),
      "a deadline must not become a delay for work that already finished")
  }

  func testWorkThatNeverFinishesIsAbandonedAtTheDeadline() async {
    // The whole point: the caller gets control back and can finish tearing the
    // session down, rather than waiting on a daemon that is never going to
    // answer.
    let start = ContinuousClock.now

    await Deadline.run(seconds: 0.2) {
      try? await Task.sleep(nanoseconds: 60_000_000_000)
    }

    let waited = start.duration(to: .now)
    XCTAssertGreaterThanOrEqual(waited, .milliseconds(150))
    XCTAssertLessThan(
      waited, .seconds(5),
      "the wait must be bounded by the deadline, not by the work")
  }

  func testTheGateResumesOnlyOnce() async {
    // Both racers open the gate whenever the work finishes close to the
    // deadline. Resuming a continuation twice traps, so this is the ordinary
    // case, not an edge one.
    for _ in 0..<50 {
      await Deadline.run(seconds: 0.01) {
        try? await Task.sleep(nanoseconds: 10_000_000)
      }
    }
  }

  func testAGateOpenedBeforeAnyoneWaitsStillResumesTheWaiter() async {
    // Fast work opens the gate before `attach` runs. Without the `opened` check
    // in `attach` the continuation would never be resumed and the caller would
    // hang forever — the opposite failure, and a worse one.
    let gate = DeadlineGate()
    gate.open()

    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      gate.attach(continuation)
    }
  }
}
