import AVFoundation
import FlutterMacOS
import Foundation
import RecorderCore
import ScreenCaptureKit

/// The macOS half of the platform contract
/// (`docs/architecture/platform-channel-contract.md`).
///
/// The plugin marshals commands and events only. Frames and audio buffers stay
/// inside the native pipeline and never cross a channel.
public class RecorderMacosPlugin: NSObject, FlutterPlugin {
  private var recorderChannel: FlutterMethodChannel?
  private var eventSink: FlutterEventSink?
  private var overlayEventSink: FlutterEventSink?

  private let enumerator = CaptureSourceEnumerator()
  private let overlays = OverlayWindowController()

  /// The microphone meter. Reference counted and thread-safe in its own right,
  /// so it needs no part of `sessionLock`; what it shares with a live session
  /// is that session's `MicrophoneCapture`, handed to it by
  /// `refreshMeterSource()` whenever the session changes.
  /// Built once, in `attach(registrar:)`, on the platform thread.
  ///
  /// Deliberately not `lazy`: a `lazy var` on a class has no locking, and this
  /// is reached from the platform thread (the metering and microphone arms, and
  /// the device observers) *and* from the concurrency pool (`refreshMeterSource`
  /// inside `prepare`, `stop`, `abort` and `releaseSession`). Two threads
  /// arriving at an uninitialised `lazy` both construct and both store, which
  /// over-releases one instance — the same hazard `sessionLock` exists for
  /// below — and orphans whatever tap the losing instance had opened.
  private var meter: InputMeter!

  /// The connect/disconnect observers. A block-based observer is not detached
  /// when its owner goes, so these are removed in `deinit`; the blocks hold
  /// `self` weakly so a notification arriving in between is a no-op rather than
  /// a call into a freed plugin.
  private var deviceObservers: [NSObjectProtocol] = []

  /// The other half of "the device lists changed": the machine moving its own
  /// default from one device to another, which unplugs nothing and so posts
  /// none of the notifications above. It removes its own registrations when it
  /// is released with the plugin.
  private var defaultDevices: DefaultDeviceObserver?

  /// The live session, behind a lock.
  ///
  /// It is written from a `Task` (`prepare`, `dispose`), read synchronously on
  /// the platform thread by every runtime toggle, and read again on Flutter's
  /// raster thread through the camera-preview texture closure. An
  /// unsynchronised read/write of a class reference is not merely a stale
  /// read — the concurrent retain/release can over-release and crash.
  private let sessionLock = NSLock()
  private var _session: RecordingSession?
  private var session: RecordingSession? {
    get {
      sessionLock.lock()
      defer { sessionLock.unlock() }
      return _session
    }
    set {
      sessionLock.lock()
      _session = newValue
      sessionLock.unlock()
    }
  }

  /// Installs a session, releasing whatever it replaces.
  ///
  /// `prepare` used to assign straight over the previous session. If one was
  /// still live — after a failed stop, or a prepare following a fatal error —
  /// it was released with its capture still running and no owner left to stop
  /// it.
  ///
  /// `release()` rather than `abort()`: a session that stopped normally is
  /// `.finalized`, a state `abort()` refuses, so the call that was meant to
  /// guarantee nothing survives a replacement did nothing at all in the
  /// commonest case of all — the second recording of a session.
  private func replaceSession(with next: RecordingSession?) async {
    sessionLock.lock()
    let previous = _session
    _session = next
    sessionLock.unlock()
    if let previous, previous !== next {
      await previous.release()
    }
    refreshMeterSource()
  }

  /// Hands the meter whichever microphone the live session holds, if any.
  ///
  /// Called wherever that can have changed: a session installed or dropped, a
  /// recording stopped or aborted, the microphone toggled mid-session. While
  /// the session's microphone is running the meter reads its levels and closes
  /// its own tap, so the device is never open twice (§33.7).
  private func refreshMeterSource() {
    meter.setLiveMicrophone(session?.microphoneLevelProvider)
  }

  /// The same re-sourcing, for a session that died rather than settled.
  ///
  /// It goes through the meter's other door on purpose. This runs from a
  /// session's own teardown, which is not ordered against anything the plugin
  /// is doing: the release that follows a fatal error is a detached task nobody
  /// awaits, so a dead session's last word can land after the user has started
  /// recording again and the next `prepare` has already yielded the microphone.
  /// Ending that handover here would re-open the meter's tap on the device that
  /// `prepare` is in the middle of taking (§33.7).
  private func meterLostSessionCapture() {
    meter.liveMicrophoneStopped(session?.microphoneLevelProvider)
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = RecorderMacosPlugin()
    instance.attach(registrar: registrar)
  }

  private func attach(registrar: FlutterPluginRegistrar) {
    // Before any channel is wired up, so nothing can reach `meter` unset.
    meter = InputMeter(emit: { [weak self] event in
      DispatchQueue.main.async { self?.eventSink?(event) }
    })

    let recorder = FlutterMethodChannel(
      name: "relay/recorder", binaryMessenger: registrar.messenger)
    registrar.addMethodCallDelegate(self, channel: recorder)
    recorderChannel = recorder

    let overlay = FlutterMethodChannel(
      name: "relay/overlay", binaryMessenger: registrar.messenger)
    overlay.setMethodCallHandler { [weak self] call, result in
      self?.handleOverlay(call, result: result)
    }

    FlutterEventChannel(
      name: "relay/recorder/events", binaryMessenger: registrar.messenger
    ).setStreamHandler(
      StreamHandler(
        onListen: { [weak self] sink in self?.eventSink = sink },
        onCancel: { [weak self] in self?.eventSink = nil }))

    FlutterEventChannel(
      name: "relay/overlay/events", binaryMessenger: registrar.messenger
    ).setStreamHandler(
      StreamHandler(
        onListen: { [weak self] sink in self?.overlayEventSink = sink },
        onCancel: { [weak self] in self?.overlayEventSink = nil }))

    overlays.onCommand = { [weak self] command in
      DispatchQueue.main.async { self?.overlayEventSink?(command) }
    }

    // Device lists change under the user: a webcam is unplugged, an iPhone
    // comes into range. Dart is told to re-read rather than told what changed
    // (§33.7), because the list it should draw is the enumeration, not a diff.
    for name in [
      AVCaptureDevice.wasConnectedNotification,
      AVCaptureDevice.wasDisconnectedNotification,
    ] {
      deviceObservers.append(
        NotificationCenter.default.addObserver(
          forName: name, object: nil, queue: .main
        ) { [weak self] notification in
          let device = notification.object as? AVCaptureDevice
          self?.devicesChanged(
            DeviceChangeNotice.device(
              isCamera: device?.hasMediaType(.video) ?? false,
              isMicrophone: device?.hasMediaType(.audio) ?? false))
        })
    }

    // And the change that plugs nothing in and pulls nothing out: the machine
    // moving its default input, output or camera. It reaches the same event,
    // because what Dart does about it is the same — read the lists again.
    defaultDevices = DefaultDeviceObserver { [weak self] notice in
      self?.devicesChanged(notice)
    }
  }

  deinit {
    for observer in deviceObservers {
      NotificationCenter.default.removeObserver(observer)
    }
  }

  // MARK: - relay/recorder

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let arguments = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "getCapabilities":
      result(capabilities())

    case "getAvailableSources":
      let refresh = arguments["refreshThumbnails"] as? Bool ?? true
      Task { await self.respondWithSources(refresh: refresh, result: result) }

    case "getCurrentDisplay":
      result(CaptureSourceEnumerator.currentDisplayGeometry())

    case "getInputDevices":
      // Every kind answers, including one this platform cannot enumerate and
      // one it does not recognise: falling through to
      // `FlutterMethodNotImplemented` reaches Dart as `unsupported`, which is a
      // failure rather than "there is nothing here to choose". What can be
      // chosen is gated by `selectableDeviceKinds` in `capabilities()` (§33.2).
      let deviceKind = MediaDeviceKind(name: arguments["kind"] as? String)
      let devices = deviceKind.map { InputDeviceEnumerator.devices(kind: $0) } ?? []
      result(devices.map { $0.toMap() })

    case "startInputMetering":
      // Reference counted, and a silent no-op for a kind that cannot be
      // metered. Opening the tap happens on the meter's own queue, so an
      // `AVCaptureSession` starting up never blocks the platform thread.
      //
      // The device travels with the call: a missing `deviceId` is the platform
      // default, the same meaning it has on the configuration map, and a start
      // naming a different one moves the tap rather than opening a second
      // (§33.2).
      meter.start(
        kind: MediaDeviceKind(name: arguments["kind"] as? String),
        deviceId: arguments["deviceId"] as? String)
      result(nil)

    case "stopInputMetering":
      meter.stop(kind: MediaDeviceKind(name: arguments["kind"] as? String))
      result(nil)

    case "checkPermissions":
      result(RecorderPermissions.check())

    case "requestPermission":
      RecorderPermissions.request(kind: arguments["kind"] as? String ?? "") { status in
        result(status)
      }

    case "openPermissionSettings":
      RecorderPermissions.openSystemSettings(kind: arguments["kind"] as? String ?? "")
      result(nil)

    case "relaunchApplication":
      RecorderPermissions.relaunch { reopened in
        if reopened {
          result(nil)
        } else {
          result(
            FlutterError(
              code: RecorderErrorCode.unsupported.rawValue,
              message: "Relay could not reopen itself.",
              details: nil))
        }
      }

    case "quitApplication":
      result(nil)
      RecorderPermissions.quit()

    case "prepare":
      Task { await self.prepare(arguments: arguments, result: result) }

    case "start":
      Task { await self.start(result: result) }

    case "pause":
      run(result) { try self.currentSession().pause() }

    case "resume":
      run(result) { try self.currentSession().resume() }

    case "stop":
      Task { await self.stop(result: result) }

    case "abort":
      Task {
        await self.session?.abort()
        self.refreshMeterSource()
        await MainActor.run { result(nil) }
      }

    case "setMicrophoneEnabled":
      // Off the platform thread, like every other arm here that talks to
      // hardware. Turning the microphone on closes the meter's tap and then
      // opens the session's capture on that same device — `stopRunning()` and
      // `startRunning()`, seconds of either on a Bluetooth or Continuity
      // input. Run on the main thread they stop the control strip, a Flutter
      // view driven from it, drawing, and stall its elapsed timer with it.
      let microphoneEnabled = arguments["enabled"] as? Bool ?? false
      Task { await self.setMicrophoneEnabled(microphoneEnabled, result: result) }

    case "setCameraEnabled":
      let enabled = arguments["enabled"] as? Bool ?? false
      session?.setCameraEnabled(enabled)
      result(nil)

    case "setSystemAudioEnabled":
      session?.setSystemAudioEnabled(arguments["enabled"] as? Bool ?? false)
      result(nil)

    case "recoverArtifact":
      Task { await self.recover(path: arguments["path"] as? String, result: result) }

    case "releaseSession":
      // The finished session, dropped as soon as the user leaves the
      // post-recording screen. Until this existed, the only release was at
      // process exit, so a recorder sitting idle after a recording still owned
      // a configured camera and microphone graph — and, if its stop had gone
      // wrong, a live capture nothing would ever stop again.
      Task {
        await self.replaceSession(with: nil)
        await MainActor.run { result(nil) }
      }

    case "dispose":
      Task {
        await self.replaceSession(with: nil)
        // No device may stay open for a meter nobody is watching.
        self.meter.releaseAll()
        await MainActor.run { result(nil) }
      }

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - relay/overlay

  private func handleOverlay(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let arguments = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "showControlStrip":
      overlays.showControlStrip(placement: arguments)
      result(nil)
    case "hideControlStrip":
      overlays.hideControlStrip()
      result(nil)
    case "controlStripPosition":
      // Null when there is no strip to read, so the application keeps whatever
      // position it had stored (§33.3).
      result(overlays.controlStripPosition())
    case "updateControlStrip":
      overlays.updateControlStrip(arguments)
      result(nil)
    case "showCameraPreview":
      overlays.cameraFrameProvider = { [weak self] in
        self?.session?.cameraFrameProvider.copyLatestFrame()
      }
      session?.onCameraFrame = { [weak self] in
        self?.overlays.markCameraFrameAvailable()
      }
      let overlay = (arguments["cameraOverlay"] as? [String: Any]).map {
        CameraOverlayConfiguration(map: $0)
      }
      let cameraAspect = session?.cameraFrameProvider.aspectRatio ?? 16.0 / 9.0
      overlays.showCameraPreview(
        placement: arguments,
        configuration: overlay,
        // Stated by Dart, never inferred from the placement: both modes send
        // an absolute frame, so reading the mode off `frame` would report
        // display mode for a window recording too.
        matchesCompositedPip: arguments["matchesCompositedPip"] as? Bool ?? false,
        mirrored: overlay?.mirrorPreview ?? true,
        aspectRatio: cameraAspect)
      result(nil)
    case "hideCameraPreview":
      overlays.hideCameraPreview()
      result(nil)
    case "setMainWindowVisible":
      overlays.setMainWindowVisible(arguments["visible"] as? Bool ?? true)
      result(nil)
    case "excludedWindowIds":
      result(overlays.excludedWindowIDs.map { String($0) })
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - operations

  private func capabilities() -> [String: Any] {
    let version = ProcessInfo.processInfo.operatingSystemVersion
    return [
      "qualities": ["hd720", "fullHd1080"],
      "frameRates": [30, 60],
      "sourceTypes": ["display", "window"],
      // Cameras and microphones are picked from a list of real devices; system
      // audio is not, because ScreenCaptureKit delivers the system mix and
      // there is no endpoint to choose (§33.8). The UI reads this, never the
      // operating system's name (§28).
      "selectableDeviceKinds": [
        MediaDeviceKind.camera.rawValue, MediaDeviceKind.microphone.rawValue,
      ],
      // Only the microphone: a level the user can act on is worth showing, and
      // they can change neither the endpoint nor what the machine is playing
      // (§33.2).
      "meterableDeviceKinds": [MediaDeviceKind.microphone.rawValue],
      "supportsCamera": AVCaptureDevice.default(for: .video) != nil,
      "supportsMicrophone": AVCaptureDevice.default(for: .audio) != nil,
      "supportsSystemAudio": true,
      "supportsPause": true,
      "supportsCursorCapture": true,
      "supportsHardwareEncoding": true,
      // macOS applies a screen-recording answer to the launched binary, so the
      // application has to be able to reopen itself for one to take effect.
      "screenRecordingNeedsRelaunch": true,
      // A GUI application started through Launch Services is reparented to
      // launchd; one started straight from a shell keeps that shell as its
      // parent, and macOS then attributes screen recording to the shell rather
      // than to Relay. The permission looks refused however many times the user
      // grants it.
      "screenRecordingLaunchedByThisApp": getppid() == 1,
      "platformName": "macOS",
      "platformVersion":
        "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
    ]
  }

  /// Tells Dart to re-read the device lists, naming the kind when the change
  /// belongs to exactly one of them.
  ///
  /// Which kind a change names, and whether it can have moved the metered
  /// microphone, is decided in `DeviceChangeNotice` where `swift test` reaches
  /// it.
  private func devicesChanged(_ notice: DeviceChangeNotice) {
    eventSink?(notice.toMap())
    if notice.affectsMicrophone {
      // The metered device may have left, or the machine may have moved the
      // default the tap is following (§33.7).
      meter.deviceListChanged()
    }
  }

  private func respondWithSources(refresh: Bool, result: @escaping FlutterResult) async {
    do {
      let sources = try await enumerator.enumerate(
        refreshThumbnails: refresh, excludedWindowIDs: overlays.excludedWindowIDs)
      let payload: [[String: Any]] = sources.map { source in
        var map: [String: Any] = [
          "id": source.id,
          "type": source.type,
          "title": source.title,
          "subtitle": source.subtitle,
          "pixelWidth": source.pixelWidth,
          "pixelHeight": source.pixelHeight,
          "isCurrentDisplay": source.isCurrentDisplay,
        ]
        if let thumbnail = source.thumbnail {
          map["thumbnail"] = FlutterStandardTypedData(bytes: thumbnail)
        }
        return map
      }
      await MainActor.run { result(payload) }
    } catch {
      await MainActor.run { result(Self.flutterError(error)) }
    }
  }

  private func prepare(arguments: [String: Any], result: @escaping FlutterResult) async {
    // Whatever happens below, the meter is re-sourced. It used to be re-sourced
    // only where a session was installed — inside the `do` this `catch`
    // swallows — so a `prepare` that threw left the meter bound to a capture
    // that was gone, or, once it has yielded the device, holding nothing at
    // all. Either way the bar read zero for a working microphone until the next
    // session, and Dart's silence detector accused it of hearing nothing
    // (§33.7).
    defer { refreshMeterSource() }
    do {
      // A live recording is never replaced silently. The plugin builds a fresh
      // session per prepare, so `RecordingSession`'s own "already in progress"
      // guard can never see the second call — it would abort the running
      // capture, orphan its `.part` and answer success. The Windows plugin
      // refuses this; both sides of the contract now answer the same.
      if let live = self.session, live.isActive {
        throw RecorderError(.invalidState, "A recording is already in progress.")
      }
      // Then release, before anything is built rather than after.
      // `session.prepare` opens a stream, the camera and the microphone; doing
      // that while the previous session still holds its own means two capture
      // graphs exist at once, and a failure in between leaves the new one owned
      // by nobody.
      await self.replaceSession(with: nil)
      let configuration = try RecordingConfiguration(map: arguments)
      let content = try await enumerator.shareableContent()
      let (filter, _) = try enumerator.filter(
        forSourceId: configuration.sourceId,
        excludedWindowIDs: overlays.excludedWindowIDs,
        content: content)

      let session = RecordingSession(emit: { [weak self] event in
        DispatchQueue.main.async { self?.eventSink?(event) }
      })
      // A session that dies on its own reaches none of the plugin's teardown
      // paths, so nothing here re-sourced the meter and it went on reading a
      // capture that had stopped delivering (§33.7).
      session.onInputsReleased = { [weak self] in self?.meterLostSessionCapture() }
      if configuration.microphoneEnabled {
        // `prepare` below opens the microphone. A meter on the launch screen
        // has its own `AVCaptureSession` on that same device, and two of them
        // holding one microphone is the state the contract forbids outright —
        // so the tap is closed *before* the session opens it, not after
        // (§33.7). The hold is lifted by the `refreshMeterSource()` this
        // function defers, on every path out of here.
        await meter.yieldToSession()
      }
      try session.prepare(configuration: configuration, filter: filter)
      await self.replaceSession(with: session)
      await MainActor.run { result(nil) }
    } catch {
      await MainActor.run { result(Self.flutterError(error)) }
    }
  }

  /// The microphone toggle, off the platform thread. See the `handle` arm.
  private func setMicrophoneEnabled(
    _ enabled: Bool, result: @escaping FlutterResult
  ) async {
    // Either direction of the toggle is a moment the meter must switch between
    // its own tap and the session's capture, and on the `true` path this is
    // also what lifts the handover below — on every path out of here.
    defer { refreshMeterSource() }
    if let session {
      // Turning it on can start a microphone `prepare` never opened. The
      // meter's own tap is on that device, so — as in `prepare` — it is closed
      // *before* the session opens it, never afterwards (§33.7). Awaiting is
      // what orders the two; it suspends this task rather than holding a
      // thread.
      if enabled { await meter.yieldToSession() }
      session.setMicrophoneEnabled(enabled)
    }
    await MainActor.run { result(nil) }
  }

  private func start(result: @escaping FlutterResult) async {
    do {
      try await currentSession().start()
      await MainActor.run { result(nil) }
    } catch {
      await MainActor.run { result(Self.flutterError(error)) }
    }
  }

  private func stop(result: @escaping FlutterResult) async {
    // The session's microphone is closed by the time this returns, however it
    // returns: a stop that throws still tore the capture down, and a meter left
    // attached to it would emit zeroes forever instead of going back to its own
    // tap (§33.7).
    defer { refreshMeterSource() }
    do {
      let metadata = try await currentSession().stop()
      await MainActor.run { result(metadata) }
    } catch {
      await MainActor.run { result(Self.flutterError(error)) }
    }
  }

  /// Reads an orphaned `.part` artefact and finalizes it when it is readable.
  ///
  /// Never deletes the artefact: an unreadable file is left exactly where it is
  /// (§18).
  private func recover(path: String?, result: @escaping FlutterResult) async {
    guard let path, FileManager.default.fileExists(atPath: path) else {
      await MainActor.run { result(nil) }
      return
    }
    let source = URL(fileURLWithPath: path)
    let target = source.deletingPathExtension().appendingPathExtension("mp4")
    if FileManager.default.fileExists(atPath: target.path) {
      await MainActor.run { result(nil) }
      return
    }

    // AVFoundation identifies the container by extension, so the artefact is
    // moved onto its final name before probing and moved back untouched if
    // nothing readable is in it. Nothing is ever deleted here (§18).
    do {
      try FileManager.default.moveItem(at: source, to: target)
    } catch {
      await MainActor.run { result(nil) }
      return
    }

    let asset = AVURLAsset(url: target)
    do {
      let duration = try await asset.load(.duration)
      let tracks = try await asset.load(.tracks)
      guard duration.isNumeric, duration.seconds > 0.2,
        tracks.contains(where: { $0.mediaType == .video })
      else {
        try? FileManager.default.moveItem(at: target, to: source)
        await MainActor.run { result(nil) }
        return
      }

      let attributes = try FileManager.default.attributesOfItem(atPath: target.path)
      let videoTrack = tracks.first { $0.mediaType == .video }
      let size = try await videoTrack?.load(.naturalSize) ?? .zero
      let frameRate = try await videoTrack?.load(.nominalFrameRate) ?? 30
      let recordingId = source.deletingPathExtension().lastPathComponent
        .replacingOccurrences(of: "recording-", with: "")

      let payload: [String: Any] = [
        "path": target.path,
        "recordingId": recordingId,
        "sizeBytes": (attributes[.size] as? NSNumber)?.intValue ?? 0,
        "durationMs": Int(duration.seconds * 1000),
        "createdAtMs": Int(
          ((attributes[.creationDate] as? Date) ?? Date()).timeIntervalSince1970 * 1000),
        "width": Int(size.width),
        "height": Int(size.height),
        "frameRate": Int(frameRate.rounded()),
        "hasAudio": tracks.contains { $0.mediaType == .audio },
        "hasCamera": false,
      ]
      await MainActor.run { result(payload) }
    } catch {
      try? FileManager.default.moveItem(at: target, to: source)
      await MainActor.run { result(nil) }
    }
  }

  // MARK: - helpers

  private func currentSession() throws -> RecordingSession {
    guard let session else {
      throw RecorderError(.invalidState, "No recording session is prepared.")
    }
    return session
  }

  private func run(_ result: @escaping FlutterResult, _ body: () throws -> Void) {
    do {
      try body()
      result(nil)
    } catch {
      result(Self.flutterError(error))
    }
  }

  static func flutterError(_ error: Error) -> FlutterError {
    if let recorderError = error as? RecorderError {
      return FlutterError(
        code: recorderError.code.rawValue,
        message: recorderError.message,
        details: recorderError.details)
    }
    return FlutterError(
      code: RecorderErrorCode.unknown.rawValue,
      message: error.localizedDescription,
      details: nil)
  }
}

/// A closure-backed `FlutterStreamHandler`, so the plugin does not need a
/// separate class per event channel.
final class StreamHandler: NSObject, FlutterStreamHandler {
  private let onListenHandler: (@escaping FlutterEventSink) -> Void
  private let onCancelHandler: () -> Void

  init(
    onListen: @escaping (@escaping FlutterEventSink) -> Void,
    onCancel: @escaping () -> Void
  ) {
    self.onListenHandler = onListen
    self.onCancelHandler = onCancel
  }

  func onListen(
    withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    onListenHandler(events)
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    onCancelHandler()
    return nil
  }
}
