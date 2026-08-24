import XCTest

@testable import RecorderCore

/// The guard that makes stop and abort idempotent under a race (§19).
///
/// Two Stop clicks can both pass an `isActive` check; only one may finalize.
/// That property lives entirely in `transition(to:from:)`, and a recording is
/// lost or double-finalized when it fails.
final class AtomicStateTests: XCTestCase {
  func testAFreshSessionIsIdle() {
    XCTAssertEqual(AtomicState().current, .idle)
  }

  func testSetReportsOnlyRealChanges() {
    let state = AtomicState()

    // The return value is what makes exactly one event per transition reach
    // Dart. A repeated `set` that reported true would emit a duplicate state
    // event and the application would reject it as illegal.
    XCTAssertTrue(state.set(.recording))
    XCTAssertFalse(state.set(.recording))
    XCTAssertEqual(state.current, .recording)
  }

  func testATransitionIsRefusedFromAnUnlistedState() {
    let state = AtomicState()
    XCTAssertFalse(state.transition(to: .finalizing, from: [.recording]))
    XCTAssertEqual(state.current, .idle, "a refused transition changes nothing")
  }

  func testATransitionOntoItselfIsRefused() {
    let state = AtomicState()
    _ = state.set(.stopping)

    // This is what stops a concurrent `abort` from displacing a `stop` that
    // has already claimed the session.
    XCTAssertFalse(state.transition(to: .stopping, from: [.stopping, .recording]))
  }

  func testOnlyOneOfTwoConcurrentStopsWins() {
    // The whole reason this class exists. Both callers see `.recording`; only
    // one may proceed to finalize the file.
    for _ in 0..<200 {
      let state = AtomicState()
      _ = state.set(.recording)

      let winners = NSMutableArray()
      let lock = NSLock()
      let group = DispatchGroup()
      for _ in 0..<8 {
        DispatchQueue.global().async(group: group) {
          if state.transition(to: .stopping, from: [.recording, .paused]) {
            lock.lock()
            winners.add(1)
            lock.unlock()
          }
        }
      }
      XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
      XCTAssertEqual(winners.count, 1, "exactly one caller claims the stop")
    }
  }

  func testConcurrentSetsLeaveAValidState() {
    let state = AtomicState()
    let all: [PlatformRecorderState] = [
      .idle, .preparing, .prepared, .recording, .paused, .stopping, .finalizing,
      .finalized, .failed,
    ]
    let group = DispatchGroup()
    for index in 0..<400 {
      DispatchQueue.global().async(group: group) {
        _ = state.set(all[index % all.count])
      }
    }
    XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
    XCTAssertTrue(all.contains(state.current))
  }
}

/// Which inputs are contributing right now (§8).
final class InputFlagsTests: XCTestCase {
  func testTheFlagsRoundTrip() {
    let flags = InputFlags(microphone: true, camera: false, systemAudio: true)

    XCTAssertTrue(flags.microphoneEnabled)
    XCTAssertFalse(flags.cameraEnabled)
    XCTAssertTrue(flags.systemAudioEnabled)

    flags.cameraEnabled = true
    XCTAssertTrue(flags.cameraEnabled)
  }

  func testTheSnapshotIsConsistentAcrossAllThree() {
    // The snapshot is what an `inputChanged` event is built from. Reading the
    // three flags separately could report a state that never existed.
    let flags = InputFlags(microphone: true, camera: true, systemAudio: false)
    let snapshot = flags.snapshot

    XCTAssertTrue(snapshot.microphone)
    XCTAssertTrue(snapshot.camera)
    XCTAssertFalse(snapshot.systemAudio)
  }

  func testTogglingFromManyQueuesIsSafe() {
    // Toggled from the channel thread, read on every capture callback. This is
    // the access pattern the lock is there for.
    let flags = InputFlags(microphone: true, camera: false, systemAudio: true)
    let group = DispatchGroup()

    for index in 0..<500 {
      DispatchQueue.global().async(group: group) {
        flags.microphoneEnabled = index % 2 == 0
      }
      DispatchQueue.global().async(group: group) {
        _ = flags.snapshot
      }
    }
    XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
    XCTAssertTrue(flags.systemAudioEnabled, "an untouched flag is untouched")
  }
}
