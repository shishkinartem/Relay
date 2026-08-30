import Foundation

/// A metering sample for one input, in linear amplitude (§33.2).
///
/// Linear, never decibels, and never a buffer: §3 keeps raw media native, and
/// what a level meter needs across the channel is a peak-and-RMS pair. The
/// scale a bar is drawn on belongs wherever that bar is drawn — `InputLevel` in
/// `recorder_platform_interface` holds exactly these two numbers.
public struct AudioLevel: Equatable {
  /// The loudest single sample of the measured run.
  public let peak: Double

  /// The root mean square of the measured run: perceived loudness, where
  /// `peak` is a transient.
  public let rms: Double

  public static let silent = AudioLevel(peak: 0, rms: 0)

  /// Clamped to `[0, 1]`, and a non-finite input is silence.
  ///
  /// Float PCM is not bounded by its format: a hot input delivers samples past
  /// full scale, and that is clipping — which the bar draws at the end of its
  /// scale rather than past it.
  public init(peak: Double, rms: Double) {
    self.peak = AudioLevel.unit(peak)
    self.rms = AudioLevel.unit(rms)
  }

  private static func unit(_ value: Double) -> Double {
    guard value.isFinite else { return 0 }
    return min(max(value, 0), 1)
  }

  /// The louder of two measurements, component by component.
  ///
  /// This is how one emitted value is made out of the several buffers that
  /// arrive between two emissions: a meter that averaged them would swallow
  /// exactly the transient it exists to show.
  public func loudest(_ other: AudioLevel) -> AudioLevel {
    AudioLevel(peak: Swift.max(peak, other.peak), rms: Swift.max(rms, other.rms))
  }

  /// Measures one run of linear PCM float samples.
  ///
  /// Channel layout does not enter into it: interleaved or not, the loudest
  /// sample of the run is the peak and every sample counts once towards the
  /// RMS. A non-finite sample is skipped rather than compared, because `max`
  /// with a NaN keeps whichever side it was handed first and would pin a meter
  /// at whatever that was.
  public static func measuring(_ samples: UnsafeBufferPointer<Float>) -> AudioLevel {
    var peak = 0.0
    var sumOfSquares = 0.0
    var counted = 0
    for sample in samples {
      let value = Double(sample)
      guard value.isFinite else { continue }
      let magnitude = abs(value)
      if magnitude > peak { peak = magnitude }
      sumOfSquares += value * value
      counted += 1
    }
    guard counted > 0 else { return .silent }
    return AudioLevel(
      peak: peak, rms: (sumOfSquares / Double(counted)).squareRoot())
  }
}
