import Foundation

/// The meter's own tap, as its arithmetic sees it (§33.2).
public enum MeteringTap: Equatable {
  /// Nothing of the meter's own is open — either nobody is watching, or the
  /// levels are coming off a capture a recording already owns.
  case closed

  /// A tap opened for this device id, where nil is the platform default.
  ///
  /// The id the *start* named, never the device it resolved to: starting again
  /// with the same id must be a no-op even when the machine has moved its
  /// default underneath the tap, and whether the resolved device still exists
  /// is a question only the enumerator can answer.
  case open(deviceId: String?)
}

/// What the meter should be listening to next (§33.2, §33.7).
public enum InputMeterPlan: Equatable {
  /// Nobody is watching: close the tap and stop emitting. No device may stay
  /// open for a meter nobody is looking at.
  case stop

  /// Read the levels off the capture a recording already holds. A second
  /// `AVCaptureSession` on a device the session owns is the one thing §33.7
  /// forbids outright.
  case readLiveCapture

  /// A session is opening this microphone: close the tap and emit nothing
  /// until it says what it ended up holding.
  ///
  /// Distinct from `stop`, which means the meter is unwanted. Here it is
  /// wanted and has nothing to read, and it emits nothing rather than zeroes:
  /// a run of silent samples is exactly what Dart counts before it tells the
  /// user a working microphone is hearing nothing (§33.7).
  case waitForSession

  /// Open a tap on this device id, nil being the platform default.
  ///
  /// Re-pointing an existing tap is this same plan: the tap moves to the device
  /// that was asked for, and a second one is never opened.
  case openTap(deviceId: String?)

  /// The open tap is already on the device that was asked for; nothing to do
  /// but go on emitting.
  case keepTap
}

/// What callers have asked the meter for, and what that means for the device it
/// holds (§33.2, §33.7).
///
/// Pure on purpose. "Who is watching, which device they named, and whether a
/// recording has taken it" is the whole of the meter's decision-making, and out
/// here — away from AVFoundation — `swift test` can reach it. `InputMeter` in
/// the plugin owns the devices and does what a plan says.
public struct InputMeterDemand: Equatable {
  /// How many callers are watching. Counted, never stacked: two meters on
  /// screen make one tap, and the tap closes when the last of them stops.
  public private(set) var subscribers: Int

  /// The device the most recent start named, where nil is the platform
  /// default — the same meaning it has on `RecordingConfiguration`.
  ///
  /// The most recent start wins outright. A counted API cannot honour two
  /// watchers naming two different devices, and the row the user just chose is
  /// the one the bar is drawn under.
  public private(set) var deviceId: String?

  /// True from the moment a session is about to open this microphone until it
  /// reports what it ended up holding.
  ///
  /// It exists because closing the tap and opening the session's capture are
  /// two steps with a gap between them, and anything that reconciles in that
  /// gap — a device arriving, a second meter appearing — would re-open the tap
  /// on the device the session is in the middle of taking (§33.7).
  public private(set) var isYieldedToSession: Bool

  public init() {
    subscribers = 0
    deviceId = nil
    isYieldedToSession = false
  }

  public var isWanted: Bool { subscribers > 0 }

  public mutating func start(deviceId: String?) {
    subscribers += 1
    self.deviceId = deviceId
  }

  /// A stop with nothing running is a no-op: a meter leaving the screen must be
  /// able to say so without knowing who else is watching.
  public mutating func stop() {
    guard subscribers > 0 else { return }
    subscribers -= 1
    if subscribers == 0 { deviceId = nil }
  }

  /// Forgets every watcher, for a plugin being disposed.
  public mutating func clear() {
    subscribers = 0
    deviceId = nil
    isYieldedToSession = false
  }

  /// The device is about to be a session's. See `isYieldedToSession`.
  public mutating func yieldToSession() {
    isYieldedToSession = true
  }

  /// The session settled — holding the microphone or not holding it.
  ///
  /// Both outcomes lift the hold: a `prepare` that failed leaves nobody with
  /// the device, and a meter that stayed yielded to it would draw a flat bar
  /// for a microphone that is working perfectly well.
  public mutating func sessionSettled() {
    isYieldedToSession = false
  }

  /// The plan this demand implies, given what is happening around it.
  ///
  /// `liveCaptureIsRunning` is a recording's microphone actually delivering
  /// buffers, not merely a session existing: a prepared session whose
  /// microphone refused to open holds nothing, and the meter is free to open
  /// its own tap.
  public func plan(liveCaptureIsRunning: Bool, tap: MeteringTap) -> InputMeterPlan {
    guard isWanted else { return .stop }
    if liveCaptureIsRunning { return .readLiveCapture }
    if isYieldedToSession { return .waitForSession }
    if case .open(let openId) = tap, openId == deviceId { return .keepTap }
    return .openTap(deviceId: deviceId)
  }
}
