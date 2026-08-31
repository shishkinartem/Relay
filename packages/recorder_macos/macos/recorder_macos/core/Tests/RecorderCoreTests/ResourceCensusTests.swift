import XCTest

@testable import RecorderCore

/// §19.1's census, at the level `swift test` can reach.
///
/// The arithmetic and the released-rows rule are here; whether the plugin's
/// three contributors report the right numbers is asserted from Dart, because
/// `RecorderMacosPlugin`, `OverlayWindowController` and `InputMeter` all need
/// FlutterMacOS and AVFoundation and sit outside this module — the same
/// asymmetry `packages/CLAUDE.md` records for `LetterboxRect`.
final class ResourceCensusTests: XCTestCase {
  func testSummingAddsEachRowIndependently() {
    let session = ResourceCensus(
      captureStreams: 1, cameraSessions: 1, microphoneSessions: 1,
      sessionTimers: 1, powerAssertions: 1, writers: 1, compositors: 1)
    let overlays = ResourceCensus(
      registeredTextures: 1, overlayEngines: 3, eventMonitors: 2)
    let meter = ResourceCensus(meteringTaps: 1, meterSubscriptions: 2)

    let total = session + overlays + meter

    XCTAssertEqual(
      total,
      ResourceCensus(
        captureStreams: 1, cameraSessions: 1, microphoneSessions: 1,
        meteringTaps: 1, meterSubscriptions: 2, registeredTextures: 1,
        overlayEngines: 3, eventMonitors: 2, sessionTimers: 1,
        powerAssertions: 1, writers: 1, compositors: 1))
  }

  func testAnEmptyCensusHasReleasedEverything() {
    XCTAssertTrue(ResourceCensus().sessionResourcesReleased)
  }

  /// The point of the getter: §19.1's second table lets a host keep its overlay
  /// engines for the life of the process, so engines alone are not a leak.
  func testKeptOverlayEnginesAreNotHeldSessionResources() {
    XCTAssertTrue(ResourceCensus(overlayEngines: 3).sessionResourcesReleased)
  }

  func testEveryOtherRowFailsTheReleasedCheck() {
    let leaks: [ResourceCensus] = [
      ResourceCensus(captureStreams: 1),
      ResourceCensus(cameraSessions: 1),
      ResourceCensus(microphoneSessions: 1),
      ResourceCensus(meteringTaps: 1),
      ResourceCensus(meterSubscriptions: 1),
      ResourceCensus(registeredTextures: 1),
      ResourceCensus(eventMonitors: 1),
      ResourceCensus(sessionTimers: 1),
      ResourceCensus(powerAssertions: 1),
      ResourceCensus(writers: 1),
      ResourceCensus(compositors: 1),
    ]
    for leak in leaks {
      XCTAssertFalse(leak.sessionResourcesReleased, "\(leak)")
    }
  }

  /// The wire shape Dart decodes. Every value an `Int`, and every key present —
  /// a row that went missing would decode as zero and read as "released".
  func testTheWireMapCarriesEveryRowAsAnInteger() {
    let map = ResourceCensus(
      captureStreams: 1, cameraSessions: 2, microphoneSessions: 3,
      meteringTaps: 4, meterSubscriptions: 5, registeredTextures: 6,
      overlayEngines: 7, eventMonitors: 8, sessionTimers: 9,
      powerAssertions: 10, writers: 11, compositors: 12
    ).map

    XCTAssertEqual(
      Set(map.keys),
      [
        "captureStreams", "cameraSessions", "microphoneSessions",
        "meteringTaps", "meterSubscriptions", "registeredTextures",
        "overlayEngines", "eventMonitors", "sessionTimers", "powerAssertions",
        "writers", "compositors",
      ])
    for (key, value) in map {
      XCTAssertTrue(value is Int, "\(key) is not an Int")
    }
    XCTAssertEqual(map["captureStreams"] as? Int, 1)
    XCTAssertEqual(map["compositors"] as? Int, 12)
  }

  // MARK: - the session's ledger

  func testTheLedgerStartsEmpty() {
    XCTAssertEqual(SessionResourceLedger().census, ResourceCensus())
  }

  func testTheLedgerReportsWhatWasNoted() {
    let ledger = SessionResourceLedger()
    ledger.noteCaptureStream(true)
    ledger.noteWriter(true)
    ledger.noteCompositor(true)
    ledger.noteTimer(true)
    ledger.notePowerAssertion(true)

    XCTAssertEqual(
      ledger.census,
      ResourceCensus(
        captureStreams: 1, sessionTimers: 1, powerAssertions: 1, writers: 1,
        compositors: 1))
  }

  /// The stop path: the capture, the tick and the assertion go before
  /// finalization, so the recording indicator goes out when Stop is pressed —
  /// while the writer and the compositor are still needed to finish the file.
  func testTheCaptureCanBeReleasedBeforeTheWriter() {
    let ledger = SessionResourceLedger()
    ledger.noteCaptureStream(true)
    ledger.noteWriter(true)
    ledger.noteCompositor(true)
    ledger.noteTimer(true)
    ledger.notePowerAssertion(true)

    ledger.noteCaptureStream(false)
    ledger.noteTimer(false)
    ledger.notePowerAssertion(false)

    XCTAssertEqual(
      ledger.census, ResourceCensus(writers: 1, compositors: 1))
  }

  func testReleaseAllDropsEveryRow() {
    let ledger = SessionResourceLedger()
    ledger.noteCaptureStream(true)
    ledger.noteWriter(true)
    ledger.noteCompositor(true)
    ledger.noteTimer(true)
    ledger.notePowerAssertion(true)

    ledger.releaseAll()

    XCTAssertEqual(ledger.census, ResourceCensus())
    XCTAssertTrue(ledger.census.sessionResourcesReleased)
  }

  /// Idempotent, because every session exit runs through the same teardown and
  /// a double release must not drive a row negative and hide a real leak.
  func testReleasingTwiceIsTheSameAsReleasingOnce() {
    let ledger = SessionResourceLedger()
    ledger.noteWriter(true)
    ledger.releaseAll()
    ledger.releaseAll()

    XCTAssertEqual(ledger.census, ResourceCensus())
  }
}
