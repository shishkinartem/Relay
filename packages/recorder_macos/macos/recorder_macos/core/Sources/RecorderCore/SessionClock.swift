import CoreMedia
import Foundation

/// The one monotonic recording timeline (§8, §9).
///
/// Video frames arrive on the stream queue, system audio on the same one,
/// microphone samples on the capture session's queue, and pause/resume from
/// whichever thread the channel call lands on. They all read and advance this
/// state, so it lives behind a lock rather than as loose fields — concurrent
/// access to a plain `Double?` from several queues is undefined behaviour, not
/// merely a wrong number.
///
/// Paused intervals are subtracted, so the file's duration equals the strip's
/// timer.
public final class SessionClock {
  public init() {}

  private let lock = NSLock()
  private var startHostSeconds: Double?
  private var pausedTotal: Double = 0
  private var pausedAtHostSeconds: Double?
  private var lastElapsed: Double = 0

  /// Host-clock now. Monotonic; wall-clock never enters the calculation.
  public static func hostSeconds() -> Double {
    return CMClockGetTime(CMClockGetHostTimeClock()).seconds
  }

  public func reset() {
    lock.lock()
    defer { lock.unlock() }
    startHostSeconds = nil
    pausedTotal = 0
    pausedAtHostSeconds = nil
    lastElapsed = 0
  }

  public var isPaused: Bool {
    lock.lock()
    defer { lock.unlock() }
    return pausedAtHostSeconds != nil
  }

  public var elapsedSeconds: Double {
    lock.lock()
    defer { lock.unlock() }
    return lastElapsed
  }

  public func pause() {
    lock.lock()
    defer { lock.unlock() }
    guard pausedAtHostSeconds == nil else { return }
    pausedAtHostSeconds = SessionClock.hostSeconds()
  }

  public func resume() {
    lock.lock()
    defer { lock.unlock() }
    guard let pausedAt = pausedAtHostSeconds else { return }
    pausedTotal += SessionClock.hostSeconds() - pausedAt
    pausedAtHostSeconds = nil
  }

  /// Places a source timestamp on the recording timeline.
  ///
  /// Returns nil while paused, or before the timeline has a start, so a
  /// caller cannot encode a sample that does not belong in the file.
  public func position(of presentationTime: CMTime, advancingElapsed: Bool) -> Double? {
    guard presentationTime.isValid, presentationTime.isNumeric else { return nil }
    lock.lock()
    defer { lock.unlock() }
    if startHostSeconds == nil {
      startHostSeconds = presentationTime.seconds
    }
    guard let start = startHostSeconds, pausedAtHostSeconds == nil else {
      return nil
    }
    let seconds = presentationTime.seconds - start - pausedTotal
    guard seconds >= 0 else { return nil }
    if advancingElapsed {
      lastElapsed = seconds
    }
    return seconds
  }
}

/// Which inputs are contributing right now (§8).
///
/// Toggled from the channel thread and read on every capture callback, so the
/// three flags are guarded rather than free-floating `Bool`s.
public final class InputFlags {
  private let lock = NSLock()
  private var microphone: Bool
  private var camera: Bool
  private var systemAudio: Bool

  public init(microphone: Bool, camera: Bool, systemAudio: Bool) {
    self.microphone = microphone
    self.camera = camera
    self.systemAudio = systemAudio
  }

  public var microphoneEnabled: Bool {
    get { lock.lock(); defer { lock.unlock() }; return microphone }
    set { lock.lock(); microphone = newValue; lock.unlock() }
  }

  public var cameraEnabled: Bool {
    get { lock.lock(); defer { lock.unlock() }; return camera }
    set { lock.lock(); camera = newValue; lock.unlock() }
  }

  public var systemAudioEnabled: Bool {
    get { lock.lock(); defer { lock.unlock() }; return systemAudio }
    set { lock.lock(); systemAudio = newValue; lock.unlock() }
  }

  public var snapshot: (microphone: Bool, camera: Bool, systemAudio: Bool) {
    lock.lock()
    defer { lock.unlock() }
    return (microphone, camera, systemAudio)
  }
}

/// The session's lifecycle state, readable from any queue.
public final class AtomicState {
  public init() {}

  private let lock = NSLock()
  private var value: PlatformRecorderState = .idle

  public var current: PlatformRecorderState {
    lock.lock()
    defer { lock.unlock() }
    return value
  }

  /// Sets the state and reports whether it actually changed, so the caller
  /// emits exactly one event per transition.
  public func set(_ next: PlatformRecorderState) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard value != next else { return false }
    value = next
    return true
  }

  /// Moves to [next] only from one of [allowed]. Returns false otherwise, which
  /// is what makes stop and abort idempotent under a race.
  public func transition(to next: PlatformRecorderState, from allowed: Set<PlatformRecorderState>) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard allowed.contains(value), value != next else { return false }
    value = next
    return true
  }
}
