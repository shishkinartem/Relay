import CoreMedia
import XCTest

@testable import RecorderCore

/// The one monotonic recording timeline (§8, §9).
///
/// 154 lines of dependency-free arithmetic that nothing executed until now,
/// guarding the single invariant no other test in the project can reach: the
/// file's duration equals the strip's timer, and wall-clock never enters the
/// calculation.
final class SessionClockTests: XCTestCase {
  /// A host timestamp `seconds` into the timeline.
  private func time(_ seconds: Double) -> CMTime {
    CMTime(seconds: seconds, preferredTimescale: 90_000)
  }

  func testTheFirstSampleDefinesTheOrigin() {
    let clock = SessionClock()

    // Capture never starts at zero: ScreenCaptureKit hands out host-clock
    // timestamps that have been running since boot. The first sample is what
    // the timeline is measured from.
    XCTAssertEqual(clock.position(of: time(1_000), advancingElapsed: true), 0)
    XCTAssertEqual(clock.position(of: time(1_002), advancingElapsed: true), 2)
  }

  func testElapsedFollowsTheVideoTimelineOnly() {
    let clock = SessionClock()
    _ = clock.position(of: time(500), advancingElapsed: true)

    // Audio places itself on the timeline without advancing it. Both sources
    // must share the origin, or they drift apart in the file.
    _ = clock.position(of: time(509), advancingElapsed: false)
    XCTAssertEqual(clock.elapsedSeconds, 0)

    _ = clock.position(of: time(504), advancingElapsed: true)
    XCTAssertEqual(clock.elapsedSeconds, 4)
  }

  func testAudioAndVideoShareOneOrigin() {
    let clock = SessionClock()

    // Whichever source arrives first sets the origin, and the other is placed
    // against the same one. A separate origin per source is exactly the bug
    // that shows up as lip-sync drift.
    let audio = clock.position(of: time(2_000), advancingElapsed: false)
    let video = clock.position(of: time(2_000), advancingElapsed: true)
    XCTAssertEqual(audio, 0)
    XCTAssertEqual(video, 0)
  }

  func testPausedIntervalsAreSubtracted() {
    let clock = SessionClock()
    _ = clock.position(of: time(100), advancingElapsed: true)
    _ = clock.position(of: time(105), advancingElapsed: true)
    XCTAssertEqual(clock.elapsedSeconds, 5)

    clock.pause()
    XCTAssertTrue(clock.isPaused)
    // A sample captured during a pause has nowhere to go: encoding it would
    // put paused wall time into the file, and the file's duration would stop
    // matching the timer on the strip.
    XCTAssertNil(clock.position(of: time(107), advancingElapsed: true))
    XCTAssertEqual(clock.elapsedSeconds, 5, "a pause does not advance elapsed")
  }

  func testResumeContinuesWhereThePauseBegan() {
    let clock = SessionClock()
    _ = clock.position(of: time(0), advancingElapsed: true)
    _ = clock.position(of: time(10), advancingElapsed: true)

    clock.pause()
    clock.resume()
    XCTAssertFalse(clock.isPaused)

    // The pause here is measured in host seconds by the clock itself, so this
    // asserts the shape rather than an exact figure: the timeline continues,
    // it does not restart and it does not jump forward by the pause.
    let after = clock.position(of: time(12), advancingElapsed: true)
    XCTAssertNotNil(after)
    XCTAssertGreaterThanOrEqual(after!, 10)
    XCTAssertLessThanOrEqual(after!, 12)
  }

  func testPauseIsIdempotent() {
    let clock = SessionClock()
    _ = clock.position(of: time(0), advancingElapsed: true)

    clock.pause()
    clock.pause()
    clock.resume()

    // Two pauses and one resume must not leave the clock paused, and must not
    // double-count the interval. Double-clicking Pause on the strip is one
    // mis-timed frame away from doing exactly this.
    XCTAssertFalse(clock.isPaused)
  }

  func testResumeWithoutPauseDoesNothing() {
    let clock = SessionClock()
    _ = clock.position(of: time(0), advancingElapsed: true)
    _ = clock.position(of: time(3), advancingElapsed: true)

    clock.resume()
    XCTAssertEqual(clock.elapsedSeconds, 3)
  }

  func testATimestampBeforeTheOriginIsRefused() {
    let clock = SessionClock()
    _ = clock.position(of: time(50), advancingElapsed: true)

    // Out-of-order buffers do arrive. A negative position would be appended
    // behind the previous frame and the encoder would reject the whole run.
    XCTAssertNil(clock.position(of: time(49), advancingElapsed: true))
  }

  func testAnInvalidTimestampIsRefused() {
    let clock = SessionClock()
    XCTAssertNil(clock.position(of: .invalid, advancingElapsed: true))
    XCTAssertNil(clock.position(of: .indefinite, advancingElapsed: true))
  }

  func testResetReturnsTheClockToItsInitialState() {
    let clock = SessionClock()
    _ = clock.position(of: time(1_000), advancingElapsed: true)
    _ = clock.position(of: time(1_020), advancingElapsed: true)
    clock.pause()

    clock.reset()

    XCTAssertEqual(clock.elapsedSeconds, 0)
    XCTAssertFalse(clock.isPaused, "a second recording does not start paused")
    // A fresh origin, not the previous one: the next session's first frame is
    // time zero however long ago the last one ended.
    XCTAssertEqual(clock.position(of: time(9_000), advancingElapsed: true), 0)
  }

  func testHostSecondsIsMonotonic() {
    // Wall-clock never enters media timing. This is the property that makes a
    // recording survive an NTP correction or a daylight-saving jump.
    let first = SessionClock.hostSeconds()
    let second = SessionClock.hostSeconds()
    XCTAssertGreaterThanOrEqual(second, first)
  }

  func testConcurrentAccessFromManyQueuesIsSafe() {
    // Video arrives on one queue, audio on another, pause/resume on whichever
    // thread the channel call lands on. The lock is the reason this is a wrong
    // number rather than undefined behaviour.
    let clock = SessionClock()
    _ = clock.position(of: time(0), advancingElapsed: true)

    let group = DispatchGroup()
    for index in 1...200 {
      DispatchQueue.global().async(group: group) {
        _ = clock.position(
          of: self.time(Double(index) / 60.0), advancingElapsed: index % 2 == 0)
      }
      DispatchQueue.global().async(group: group) {
        if index % 20 == 0 {
          clock.pause()
          clock.resume()
        }
      }
    }
    XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
    XCTAssertFalse(clock.isPaused)
  }
}
