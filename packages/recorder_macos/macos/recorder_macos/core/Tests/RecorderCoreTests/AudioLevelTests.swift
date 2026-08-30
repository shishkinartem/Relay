import XCTest

@testable import RecorderCore

/// The microphone meter's arithmetic (§33.2, §33.7).
final class AudioLevelTests: XCTestCase {
  private func level(_ samples: [Float]) -> AudioLevel {
    samples.withUnsafeBufferPointer { AudioLevel.measuring($0) }
  }

  func testAnEmptyRunIsSilenceRatherThanADivisionByZero() {
    XCTAssertEqual(level([]), .silent)
    XCTAssertEqual(level([0, 0, 0, 0]), .silent)
  }

  func testPeakIsTheLoudestSampleAndIgnoresItsSign() {
    // A negative half-cycle is as loud as a positive one; a meter that read the
    // signed maximum would draw silence for the bottom half of every waveform.
    let measured = level([0.1, -0.8, 0.3])
    XCTAssertEqual(measured.peak, 0.8, accuracy: 1e-6)
  }

  func testRmsIsTheRootMeanSquareOfEverySample() {
    // A full-scale square wave is the one signal whose RMS equals its peak.
    let square = level([1, -1, 1, -1])
    XCTAssertEqual(square.peak, 1.0, accuracy: 1e-6)
    XCTAssertEqual(square.rms, 1.0, accuracy: 1e-6)

    // Half of a full-scale square: RMS follows the amplitude, not the count.
    let quiet = level([0.5, -0.5])
    XCTAssertEqual(quiet.rms, 0.5, accuracy: 1e-6)

    // Silence in half the run halves the mean square, not the amplitude.
    let gated = level([1, 0])
    XCTAssertEqual(gated.peak, 1.0, accuracy: 1e-6)
    XCTAssertEqual(gated.rms, (0.5 as Double).squareRoot(), accuracy: 1e-6)
  }

  func testAHotSampleIsClippingRatherThanAnOverflowingBar() {
    // Float PCM is not bounded by its format, and the bar has nowhere to draw a
    // level past the end of its scale.
    let measured = level([1.8, -2.4])
    XCTAssertEqual(measured.peak, 1.0)
    XCTAssertEqual(measured.rms, 1.0)
    XCTAssertEqual(AudioLevel(peak: -0.5, rms: -0.5), .silent)
  }

  func testANonFiniteSampleDoesNotPinTheMeter() {
    // `max` with a NaN keeps whichever operand it was handed first, so one bad
    // sample in a buffer could hold a meter at full scale for as long as the
    // device kept delivering.
    let measured = level([0.25, .nan, .infinity, -0.5])
    XCTAssertEqual(measured.peak, 0.5, accuracy: 1e-6)
    XCTAssertTrue(measured.rms.isFinite)
    XCTAssertEqual(level([.nan, .infinity]), .silent)
    XCTAssertEqual(AudioLevel(peak: .nan, rms: .infinity), .silent)
  }

  func testTheLoudestOfTwoMeasurementsIsTakenComponentByComponent() {
    // One emitted value is made of every buffer that arrived since the last
    // emission. Averaging them would swallow the transient the meter exists to
    // show.
    let transient = AudioLevel(peak: 0.9, rms: 0.2)
    let sustained = AudioLevel(peak: 0.4, rms: 0.35)
    XCTAssertEqual(
      transient.loudest(sustained), AudioLevel(peak: 0.9, rms: 0.35))
    XCTAssertEqual(
      sustained.loudest(transient), AudioLevel(peak: 0.9, rms: 0.35))
    XCTAssertEqual(AudioLevel.silent.loudest(transient), transient)
  }
}
