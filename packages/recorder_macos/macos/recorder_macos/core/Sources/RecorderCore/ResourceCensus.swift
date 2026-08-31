import Foundation

/// What the host is still holding, counted (§19.1).
///
/// §19.1 observes that "state is cleaned up" cannot be a requirement, because
/// nothing can fail it. This is what makes it falsifiable: every row is an
/// integer, and the two tests it names — census equality across ten start →
/// stop cycles, and every row of its first table zero after one stop — are both
/// equality assertions on this.
///
/// It lives out here rather than in the plugin so `swift test` can reach the
/// arithmetic, and so the three things that answer it — the session, the
/// overlay windows and the meter — each report their own rows and are summed
/// once, instead of one of them owning a map the other two write into.
///
/// The wire shape is `[String: Int]`, matching `ResourceCensus` in
/// `recorder_platform_interface` key for key
/// (`docs/architecture/platform-channel-contract.md`).
public struct ResourceCensus: Equatable {
  public var captureStreams: Int
  public var cameraSessions: Int
  public var microphoneSessions: Int
  public var meteringTaps: Int
  public var meterSubscriptions: Int
  public var registeredTextures: Int
  public var overlayEngines: Int
  public var eventMonitors: Int
  public var sessionTimers: Int
  public var powerAssertions: Int
  public var writers: Int
  public var compositors: Int

  public init(
    captureStreams: Int = 0,
    cameraSessions: Int = 0,
    microphoneSessions: Int = 0,
    meteringTaps: Int = 0,
    meterSubscriptions: Int = 0,
    registeredTextures: Int = 0,
    overlayEngines: Int = 0,
    eventMonitors: Int = 0,
    sessionTimers: Int = 0,
    powerAssertions: Int = 0,
    writers: Int = 0,
    compositors: Int = 0
  ) {
    self.captureStreams = captureStreams
    self.cameraSessions = cameraSessions
    self.microphoneSessions = microphoneSessions
    self.meteringTaps = meteringTaps
    self.meterSubscriptions = meterSubscriptions
    self.registeredTextures = registeredTextures
    self.overlayEngines = overlayEngines
    self.eventMonitors = eventMonitors
    self.sessionTimers = sessionTimers
    self.powerAssertions = powerAssertions
    self.writers = writers
    self.compositors = compositors
  }

  /// Row-wise addition. Each contributor counts only what it owns, so the sum
  /// is the whole census and nothing is counted twice.
  public static func + (lhs: ResourceCensus, rhs: ResourceCensus) -> ResourceCensus {
    ResourceCensus(
      captureStreams: lhs.captureStreams + rhs.captureStreams,
      cameraSessions: lhs.cameraSessions + rhs.cameraSessions,
      microphoneSessions: lhs.microphoneSessions + rhs.microphoneSessions,
      meteringTaps: lhs.meteringTaps + rhs.meteringTaps,
      meterSubscriptions: lhs.meterSubscriptions + rhs.meterSubscriptions,
      registeredTextures: lhs.registeredTextures + rhs.registeredTextures,
      overlayEngines: lhs.overlayEngines + rhs.overlayEngines,
      eventMonitors: lhs.eventMonitors + rhs.eventMonitors,
      sessionTimers: lhs.sessionTimers + rhs.sessionTimers,
      powerAssertions: lhs.powerAssertions + rhs.powerAssertions,
      writers: lhs.writers + rhs.writers,
      compositors: lhs.compositors + rhs.compositors)
  }

  /// True when every row of §19.1's **first** table is zero.
  ///
  /// `overlayEngines` is excluded deliberately: §19.1's second table allows a
  /// host to keep its overlay engines for the life of the process, which is
  /// what this one does. What that host owes instead is stability, and the
  /// census *equality* test is what holds it to that.
  public var sessionResourcesReleased: Bool {
    captureStreams == 0 && cameraSessions == 0 && microphoneSessions == 0
      && meteringTaps == 0 && meterSubscriptions == 0 && registeredTextures == 0
      && eventMonitors == 0 && sessionTimers == 0 && powerAssertions == 0
      && writers == 0 && compositors == 0
  }

  /// The wire map. Every value an `Int`, `writers` and `compositors` included:
  /// one type for the whole map is what lets Dart compare it in one equality.
  public var map: [String: Any] {
    [
      "captureStreams": captureStreams,
      "cameraSessions": cameraSessions,
      "microphoneSessions": microphoneSessions,
      "meteringTaps": meteringTaps,
      "meterSubscriptions": meterSubscriptions,
      "registeredTextures": registeredTextures,
      "overlayEngines": overlayEngines,
      "eventMonitors": eventMonitors,
      "sessionTimers": sessionTimers,
      "powerAssertions": powerAssertions,
      "writers": writers,
      "compositors": compositors,
    ]
  }
}

/// The rows a live session owns, mirrored so the census can be read from a
/// thread that is not the one that built them (§19.1).
///
/// A mirror rather than a direct read of `RecordingSession`'s own fields, and
/// this is not tidiness: those fields are written on the concurrency pool and
/// the census is asked for on the platform thread, and an unsynchronised
/// read/write of a class reference can over-release rather than merely read
/// stale — the hazard `sessionLock` already exists for in the plugin. Six
/// booleans behind one lock cost nothing and cannot crash.
///
/// The camera and the microphone are deliberately *not* here: they are `let`
/// captures the session owns for its whole life, so they can be asked directly
/// and there is nothing to keep in step.
public final class SessionResourceLedger: @unchecked Sendable {
  private let lock = NSLock()
  private var captureStream = false
  private var writer = false
  private var compositor = false
  private var timer = false
  private var powerAssertion = false

  public init() {}

  public func noteCaptureStream(_ held: Bool) { write { self.captureStream = held } }
  public func noteWriter(_ held: Bool) { write { self.writer = held } }
  public func noteCompositor(_ held: Bool) { write { self.compositor = held } }
  public func noteTimer(_ held: Bool) { write { self.timer = held } }
  public func notePowerAssertion(_ held: Bool) { write { self.powerAssertion = held } }

  /// Everything the session built, dropped at once — what `tearDown` does.
  public func releaseAll() {
    write {
      self.captureStream = false
      self.writer = false
      self.compositor = false
      self.timer = false
      self.powerAssertion = false
    }
  }

  public var census: ResourceCensus {
    lock.lock()
    defer { lock.unlock() }
    return ResourceCensus(
      captureStreams: captureStream ? 1 : 0,
      sessionTimers: timer ? 1 : 0,
      powerAssertions: powerAssertion ? 1 : 0,
      writers: writer ? 1 : 0,
      compositors: compositor ? 1 : 0)
  }

  private func write(_ body: () -> Void) {
    lock.lock()
    body()
    lock.unlock()
  }
}
