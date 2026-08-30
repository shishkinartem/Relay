import AVFoundation
import Foundation
import RecorderCore

/// The microphone level meter (§33.2, §33.7).
///
/// Reference counted rather than stacked: two screens showing a meter make one
/// tap, and the tap closes when the last of them stops. A stop with nothing
/// running is a no-op — a meter that leaves the screen must be able to say so
/// without knowing who else is watching. A start naming a *different* device
/// moves that one tap onto it; it never opens a second.
///
/// Only the microphone is meterable. System audio is deliberately not: the user
/// can act on neither the endpoint nor what the machine is playing (§33.2).
///
/// Threading. `lock` guards everything a caller and the capture queue share —
/// the demand (who is watching, which device they named, whether a session has
/// taken it), the level accumulated since the last emission, and the live
/// session's microphone. `queue` owns everything that outlives a call: the
/// standalone tap and the two ids describing it, whichever capture is attached,
/// the emitting timer and `reportedFailure`. Callers never touch those; they
/// change the wanted state under `lock` and hand `queue` the job of making the
/// world match it.
final class InputMeter {
  typealias EventSink = ([String: Any]) -> Void

  /// ~20 Hz. Enough for a bar the eye reads as continuous, and far below the
  /// rate buffers arrive at (§33.2).
  private static let emitInterval = DispatchTimeInterval.milliseconds(50)

  private let emit: EventSink

  private let lock = NSLock()
  private var demand = InputMeterDemand()
  private var pending = AudioLevel.silent
  private var liveMicrophone: MicrophoneCapture?

  private let queue = DispatchQueue(label: "relay.input.meter")
  private var tap: MicrophoneCapture?

  /// The id the open tap was *asked* for, and the device that id resolved to.
  ///
  /// Both, because they answer two different questions. Starting again with the
  /// same id is a no-op, which compares the requested ids; and a machine that
  /// moves its default underneath a tap has changed the device without changing
  /// the request, which only the resolved id can see.
  private var tapDeviceId: String?
  private var tapResolvedId: String?

  private var attached: MicrophoneCapture?
  private var ticker: DispatchSourceTimer?
  private var reportedFailure = false

  init(emit: @escaping EventSink) {
    self.emit = emit
  }

  /// Last resort, for a meter released while it still holds a device — the
  /// plugin winding down. Every ordinary path reconciles to nothing first and
  /// this finds nothing left to do; nothing else references these by then, so
  /// reaching them off `queue` is safe.
  deinit {
    ticker?.cancel()
    tap?.release()
  }

  // MARK: - the channel's three calls

  /// A start for a kind that cannot be metered is a silent no-op, not an error:
  /// the caller asked for a meter this platform does not draw, which is an
  /// answer the capabilities already gave it (§33.2).
  ///
  /// `deviceId` is the device to listen to, nil meaning the platform default —
  /// the same meaning it has on `RecordingConfiguration`. A meter that showed
  /// the default while the user was choosing a different microphone would
  /// answer a question nobody asked (§33.2).
  func start(kind: MediaDeviceKind?, deviceId: String?) {
    guard kind == .microphone else { return }
    lock.lock()
    let isNewDevice = !demand.isWanted || demand.deviceId != deviceId
    demand.start(deviceId: deviceId)
    lock.unlock()
    queue.async {
      // A different device gets its own chance to refuse, and to say so. The
      // suppression below exists to stop one dead device repeating itself, not
      // to silence the next one.
      if isNewDevice { self.reportedFailure = false }
      self.reconcile()
    }
  }

  func stop(kind: MediaDeviceKind?) {
    guard kind == .microphone else { return }
    lock.lock()
    demand.stop()
    lock.unlock()
    queue.async { self.reconcile() }
  }

  // MARK: - what the meter listens to

  /// The microphone the live session owns, or nil when no session holds one.
  ///
  /// Called by the plugin whenever a session has *settled*: a `prepare` that
  /// finished either way, a stop, an abort, a session dropped or replaced.
  /// While the session's microphone is running the meter reads levels off it
  /// and closes its own tap: a recording already has the device open, and a
  /// second `AVCaptureSession` on it is a second handle on the same hardware
  /// (§33.7). It also ends whatever `yieldToSession()` began, because a session
  /// has now settled — holding the microphone or, when its `prepare` failed,
  /// holding nothing.
  func setLiveMicrophone(_ microphone: MicrophoneCapture?) {
    updateLiveMicrophone(microphone, settlingHandover: true)
  }

  /// The live session let go of the microphone on its own — the platform
  /// stopped the stream, or the writer failed underneath the ticker and the
  /// session tore itself down.
  ///
  /// Deliberately not `setLiveMicrophone(_:)`. A session dying is not a session
  /// settling, and this can arrive late: the teardown that follows a fatal
  /// error runs on a detached task nobody awaits, so a dead session's last word
  /// can land after the user has started recording again and the *next*
  /// `prepare` has already yielded the device. Lifting the handover here would
  /// re-open the tap on a microphone that session is in the middle of taking —
  /// the one state §33.7 forbids outright. A handover in flight keeps the meter
  /// on `.waitForSession`, and the call that took it is what lifts it.
  func liveMicrophoneStopped(_ microphone: MicrophoneCapture?) {
    updateLiveMicrophone(microphone, settlingHandover: false)
  }

  private func updateLiveMicrophone(
    _ microphone: MicrophoneCapture?, settlingHandover: Bool
  ) {
    lock.lock()
    liveMicrophone = microphone
    if settlingHandover { demand.sessionSettled() }
    lock.unlock()
    queue.async { self.reconcile() }
  }

  /// Closes the tap and holds it closed while a session opens the same
  /// microphone.
  ///
  /// The hold is what makes the ordering safe, and it is taken synchronously,
  /// under `lock`, before this call suspends: from here on every reconcile —
  /// one already queued, one a device notification posts a moment later — plans
  /// `.waitForSession` and closes the tap instead of re-opening it. Awaiting
  /// then adds the other half of the guarantee, that the tap is already shut
  /// when the caller goes on to open the session's own capture on that device.
  ///
  /// Only the waiting is asynchronous, and it suspends the caller rather than
  /// blocking a thread. This used to be `queue.sync`, reached from the platform
  /// thread by the `setMicrophoneEnabled` arm: whatever the meter's queue was
  /// doing — `startRunning()` in `openTap`, `stopRunning()` in `releaseTap`,
  /// seconds of either on a Bluetooth or Continuity input — the main thread
  /// waited for it. The control strip is a Flutter view driven from that
  /// thread, so it stopped drawing and its elapsed timer stalled with it.
  ///
  /// The hold is lifted by the next `setLiveMicrophone(_:)`, which every path
  /// out of `prepare` and out of the microphone toggle reaches, including the
  /// ones that throw.
  func yieldToSession() async {
    lock.lock()
    demand.yieldToSession()
    lock.unlock()
    await withCheckedContinuation { continuation in
      queue.async {
        self.reconcile()
        continuation.resume()
      }
    }
  }

  /// Re-opens the tap when the device underneath it changes — the metered
  /// microphone was unplugged, or the machine moved the default the tap is
  /// following.
  ///
  /// Without this the tap keeps a dead device open and the bar sits at zero,
  /// which §33.7 separates from silence on purpose. The comparison is on the
  /// *resolved* device: a request for `microphone:mv7` that fell back to the
  /// built-in one re-points itself the moment the MV7 is plugged back in.
  func deviceListChanged() {
    queue.async {
      self.lock.lock()
      let requested = self.demand.deviceId
      self.lock.unlock()
      let resolved = InputDeviceEnumerator.resolve(
        kind: .microphone, requestedId: requested
      ).device?.uniqueID
      guard self.tapResolvedId != resolved else { return }
      self.releaseTap()
      // A tap that had no device to open gets to try again, and to report it
      // again if the new one refuses too.
      self.reportedFailure = false
      self.reconcile()
    }
  }

  /// Drops the tap and forgets every subscriber, for a plugin being disposed.
  /// No device may stay open for a meter nobody is watching.
  func releaseAll() {
    lock.lock()
    demand.clear()
    liveMicrophone = nil
    lock.unlock()
    queue.async { self.reconcile() }
  }

  // MARK: - the tap

  /// Makes the world match the wanted state. Runs on `queue`, one call at a
  /// time, so a start immediately followed by a stop settles in that order.
  private func reconcile() {
    lock.lock()
    let demand = self.demand
    let live = liveMicrophone
    lock.unlock()

    let plan = demand.plan(
      liveCaptureIsRunning: live?.isRunning ?? false, tap: tapState)
    switch plan {
    case .stop:
      stopTicker()
      attach(to: nil)
      releaseTap()
      reportedFailure = false
      lock.lock()
      pending = .silent
      lock.unlock()

    case .waitForSession:
      // The session is opening this microphone. Nothing is emitted until it
      // hands the capture over: a run of zeroes is what Dart counts before it
      // tells the user a working microphone is hearing nothing (§33.7).
      stopTicker()
      attach(to: nil)
      releaseTap()

    case .readLiveCapture:
      releaseTap()
      attach(to: live)
      startTicker()

    case .keepTap:
      attach(to: tap)
      startTicker()

    case .openTap(let deviceId):
      // Re-pointing is one tap moving: the old one is closed before the new one
      // is opened, so the two never hold a device at the same time.
      releaseTap()
      let opened = openTap(deviceId: deviceId)
      attach(to: opened)
      if opened == nil {
        // A device that would not open is not a device that is quiet. Ticking
        // anyway emits a run of zeroes, and a run of zeroes is exactly what
        // Dart counts before it tells the user a working microphone is hearing
        // nothing (§33.7) — the wrong message, and a permanent one, because the
        // real reason was reported once and is long gone from the screen.
        stopTicker()
      } else {
        startTicker()
      }
    }
  }

  private var tapState: MeteringTap {
    tap == nil ? .closed : .open(deviceId: tapDeviceId)
  }

  /// The lightest tap macOS offers outside a recording: one `AVCaptureSession`
  /// on the device the start named.
  ///
  /// A `deviceId` that no longer resolves falls back to the platform default,
  /// exactly as a configured id does on `prepare` (§33.2) — and silently, where
  /// `prepare` reports it: a bar is not the place to tell someone their
  /// microphone is gone, and the list they are choosing from says it already.
  private func openTap(deviceId: String?) -> MicrophoneCapture? {
    let resolution = InputDeviceEnumerator.resolve(
      kind: .microphone, requestedId: deviceId)
    let capture = MicrophoneCapture()
    do {
      try capture.start(device: resolution.device)
    } catch {
      // A meter that cannot open its device says why rather than drawing a
      // dead bar with no explanation (§33.7). Once per metering run: every
      // device change reconciles again, and the same refusal reported each
      // time would be a stream of identical errors.
      report(error)
      return nil
    }
    tap = capture
    tapDeviceId = deviceId
    tapResolvedId = resolution.device?.uniqueID
    return capture
  }

  private func releaseTap() {
    guard let tap else { return }
    if attached === tap { attach(to: nil) }
    self.tap = nil
    tapDeviceId = nil
    tapResolvedId = nil
    tap.release()
  }

  private func attach(to source: MicrophoneCapture?) {
    guard attached !== source else { return }
    attached?.onLevel = nil
    attached = source
    source?.onLevel = { [weak self] level in
      guard let self else { return }
      // Called on the capture queue. The loudest buffer since the last
      // emission wins, so a transient between two ticks is not averaged away.
      self.lock.lock()
      self.pending = self.pending.loudest(level)
      self.lock.unlock()
    }
  }

  // MARK: - emission

  private func startTicker() {
    guard ticker == nil else { return }
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(
      deadline: .now() + InputMeter.emitInterval,
      repeating: InputMeter.emitInterval)
    timer.setEventHandler { [weak self] in self?.tick() }
    ticker = timer
    timer.resume()
  }

  /// Nothing is emitted once the last subscriber has gone: the events exist for
  /// a meter that is on screen (§33.2).
  private func stopTicker() {
    ticker?.cancel()
    ticker = nil
  }

  private func tick() {
    lock.lock()
    let level = pending
    // Reset rather than decay: the next interval reports what actually arrived
    // in it, and an input that has gone quiet reads as silence instead of
    // holding its last peak.
    pending = .silent
    lock.unlock()

    emit([
      "type": "inputLevel",
      "kind": MediaDeviceKind.microphone.rawValue,
      "peak": level.peak,
      "rms": level.rms,
    ])
  }

  private func report(_ error: Error) {
    guard !reportedFailure else { return }
    reportedFailure = true
    let recorderError =
      error as? RecorderError
      ?? RecorderError(.unknown, error.localizedDescription)
    emit([
      "type": "error",
      "code": recorderError.code.rawValue,
      "message": recorderError.message,
      "details": recorderError.details as Any,
      "fatal": false,
    ])
  }
}
