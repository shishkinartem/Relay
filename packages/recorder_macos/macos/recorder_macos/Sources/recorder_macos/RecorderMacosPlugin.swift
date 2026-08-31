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

  /// What the live capture filter was built from, and what it actually
  /// excludes (§6).
  ///
  /// `_filterExcludedIDs` is deliberately not "every panel we own": it is the
  /// ids that were both ours *and* listed by the window server when the filter
  /// was made, because those are the only ones a filter can hold. The
  /// difference is what tells a panel that never reached the exclusion list
  /// apart from one that is already in it.
  ///
  /// Behind a lock of their own: they are written from the `Task` `prepare`
  /// runs on and read from the main thread, where the overlay callback that
  /// triggers a rebuild fires. `sessionLock` is not reused for them — it guards
  /// one reference and is held across nothing else, and widening it to cover a
  /// second concern is how a lock starts covering a system call.
  private let exclusionLock = NSLock()
  private var _activeSourceId: String?
  private var _filterExcludedIDs: Set<CGWindowID> = []
  private var _exclusionRebuildInFlight = false
  private var _exclusionRebuildPending = false

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
    if next == nil {
      // Nothing left to re-point, and a source id that outlived its session
      // would send the next overlay's appearance rebuilding a filter for a
      // recording that is over.
      forgetCaptureFilter()
    }
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

    // A choice travels on the same channel as the commands, as a map. Dart
    // decodes by shape — a String is a command, a Map is a choice — so a host
    // that only ever emits names keeps working untouched (§33.4).
    overlays.onMenuSelection = { [weak self] selection in
      DispatchQueue.main.async { self?.overlayEventSink?(selection) }
    }

    // An overlay window just appeared, and it cannot be in the filter `prepare`
    // built: that filter names the windows the window server was listing at the
    // time, and every overlay — the strip, the preview, the input menu — is
    // shown afterwards. Re-pointing the running capture is what makes the
    // exclusion list the second mechanism §6 asks for rather than a list that
    // happens to be empty.
    overlays.onOverlayWindowsChanged = { [weak self] in
      guard let self else { return }
      Task { await self.refreshCaptureExclusions() }
    }

    // A drag of the preview *is* a drag of the picture-in-picture in display
    // mode (design `1p`), so the compositor follows it here rather than waiting
    // for the application to read the position back and push it: the drag ran
    // inside AppKit's own loop, and a preview that has moved while the file has
    // not is the disagreement §33.7 calls a defect.
    //
    // The application is told as well, on the events channel, as a map with an
    // `event` name — beside the bare command strings and the input menu's maps,
    // which Dart tells apart by shape (§33.4). It has to be told: the
    // configuration it pushes on the next preset change is built from the
    // position *it* holds, and a drag only this side knew about was thrown away
    // by every one of them (§33.5, §33.7's "preset changed mid-drag").
    //
    // Pushed rather than left to be pulled at teardown. The old pull asked the
    // window where it was, which is the tile's rectangle whether the user
    // dragged it there or the corner rule put it there — so a session that
    // never touched the tile still stored a free position, and the corner
    // stopped being consulted from then on.
    overlays.onCameraPreviewMoved = { [weak self] landed in
      guard let self else { return }
      if let overlay = self.overlays.cameraOverlay {
        self.session?.setCameraOverlay(overlay)
      }
      DispatchQueue.main.async {
        self.overlayEventSink?([
          "event": "cameraPreviewMoved",
          "x": Double(landed.x),
          "y": Double(landed.y),
        ])
      }
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
      // Off the platform thread. This is where the process first touches
      // AVFoundation's capture subsystem, and that start-up costs a fifth of a
      // second — paid here once, before the first frame, but paid on the thread
      // that drives every Flutter engine.
      Task { await self.respondWithCapabilities(result: result) }

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
      //
      // Off the platform thread: a discovery session is a fifth of a second
      // cold, and unbounded when a Continuity Camera is coming into range. This
      // runs on every chevron press and on every plug or unplug — during a
      // recording, when a stalled platform thread stops all four overlay
      // engines drawing.
      let deviceKind = MediaDeviceKind(name: arguments["kind"] as? String)
      Task {
        let devices = deviceKind.map { InputDeviceEnumerator.devices(kind: $0) } ?? []
        let payload = devices.map { $0.toMap() }
        await MainActor.run { result(payload) }
      }

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
      // Off the platform thread. Measured at ~36 ms, and it is asked on every
      // launch and every time the application is brought back to the front.
      Task {
        let permissions = RecorderPermissions.check()
        await MainActor.run { result(permissions) }
      }

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
      // Off the platform thread, for the reason spelled out on
      // `setMicrophoneEnabled` above and for one more: turning the camera on
      // resolves a device — a discovery session, a fifth of a second cold —
      // then opens it and calls `startRunning()`, which is seconds on a
      // Continuity or Bluetooth camera. On the platform thread that is a
      // recording whose control strip stops drawing and whose timer stalls,
      // followed by Dart's own eight-second deadline firing on a call that
      // actually succeeded.
      let cameraEnabled = arguments["enabled"] as? Bool ?? false
      Task {
        self.session?.setCameraEnabled(cameraEnabled)
        await MainActor.run { result(nil) }
      }

    case "setSystemAudioEnabled":
      session?.setSystemAudioEnabled(arguments["enabled"] as? Bool ?? false)
      result(nil)

    case "selectInputDevice":
      // Off the platform thread, like every other arm that talks to hardware:
      // a swap is a `stopRunning()` and a `startRunning()`, seconds of either
      // on a Bluetooth or Continuity input, and the control strip is a Flutter
      // view driven from this thread.
      let deviceKind = MediaDeviceKind(name: arguments["kind"] as? String)
      let requestedId = arguments["deviceId"] as? String
      Task {
        await self.selectInputDevice(
          deviceKind, deviceId: requestedId, result: result)
      }

    case "setCameraOverlay":
      // Applied between frames, for the next one. The tile also *is* the
      // preview window in display mode, so both move together or design `1p`
      // stops being true (§33.5). Outside a session there is nothing to
      // re-point: what the next recording opens is the configuration's business.
      if let session {
        let overlay = CameraOverlayConfiguration(map: arguments)
        session.setCameraOverlay(overlay)
        overlays.updateCameraPreview(
          configuration: overlay, source: cameraTileSource())
      }
      result(nil)

    case "cameraPreviewPosition":
      // Null in window mode, where the preview is not the tile (design `1e`).
      result(overlays.cameraPreviewPosition())

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
    case "showInputMenu":
      overlays.showInputMenu(
        placement: arguments,
        state: arguments["state"] as? [String: Any] ?? [:])
      result(nil)
    case "updateInputMenu":
      overlays.updateInputMenu(arguments)
      result(nil)
    case "hideInputMenu":
      overlays.hideInputMenu()
      result(nil)
    case "nudgeControlStrip":
      overlays.nudgeControlStrip(
        dx: arguments["dx"] as? Double ?? 0, dy: arguments["dy"] as? Double ?? 0)
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
      overlays.showCameraPreview(
        placement: arguments,
        configuration: overlay,
        // Stated by Dart, never inferred from the placement: both modes send
        // an absolute frame, so reading the mode off `frame` would report
        // display mode for a window recording too.
        matchesCompositedPip: arguments["matchesCompositedPip"] as? Bool ?? false,
        mirrored: overlay?.mirrorPreview ?? true,
        source: cameraTileSource())
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

  /// `getCapabilities`, off the platform thread. See the `handle` arm.
  private func respondWithCapabilities(result: @escaping FlutterResult) async {
    let payload = capabilities()
    await MainActor.run { result(payload) }
  }

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
      // `excludedWindowIDs` walks `NSApplication.shared.windows`, and the
      // enumerator's `isCurrentDisplay` reads `NSScreen.screens`. AppKit is
      // main-thread-only: reading it from this task is undefined behaviour,
      // not merely a race — and this is one of the two most frequently
      // executed paths in the plugin. `rebuildContentFilter` already hops for
      // exactly this; these did not.
      let excluded = await MainActor.run { self.overlays.excludedWindowIDs }
      let sources = try await enumerator.enumerate(
        refreshThumbnails: refresh, excludedWindowIDs: excluded)
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
      // Main thread: see `respondWithSources`.
      let requestedExclusions = await MainActor.run { self.overlays.excludedWindowIDs }
      let (filter, _) = try enumerator.filter(
        forSourceId: configuration.sourceId,
        excludedWindowIDs: requestedExclusions,
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
      // Recorded *after* the session is installed, because `replaceSession`
      // with a new session leaves the previous one's record in place and a nil
      // one clears it. What is recorded is what the filter really holds, which
      // on a first recording is nothing at all: no overlay is on screen yet.
      rememberCaptureFilter(
        sourceId: configuration.sourceId, requested: requestedExclusions,
        listedIn: content)
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

  /// The live device swap, off the platform thread. See the `handle` arm.
  ///
  /// Every kind answers, including the one macOS cannot choose: system audio is
  /// the mix ScreenCaptureKit delivers and there is no endpoint to name
  /// (§33.8). Falling through to `FlutterMethodNotImplemented` would reach Dart
  /// as `unsupported` — a failure, rather than "there is nothing here to
  /// choose". Outside a session it is a no-op for the same reason `prepare`
  /// carries device ids at all.
  private func selectInputDevice(
    _ kind: MediaDeviceKind?, deviceId: String?, result: @escaping FlutterResult
  ) async {
    // The session's microphone may have stopped, restarted, or gone off
    // entirely, and the meter reads either that capture or its own tap (§33.7).
    defer { refreshMeterSource() }
    if let kind, let session {
      // The same handover `prepare` and the microphone toggle make: a meter
      // whose own tap is open on a device the session is about to take is the
      // one state §33.7 forbids outright, so the tap is closed *before* the
      // swap and held closed until the deferred re-source above lifts it.
      if kind == .microphone { await meter.yieldToSession() }
      session.selectInputDevice(kind: kind, deviceId: deviceId)
      if kind == .camera {
        // A camera of another shape gives the tile another shape, and in
        // display mode the preview *is* the tile (design `1p`). The tile's
        // position and preset are untouched; only what they resolve to moves.
        let source = cameraTileSource()
        await MainActor.run {
          self.overlays.updateCameraPreview(configuration: nil, source: source)
        }
      }
    }
    await MainActor.run { result(nil) }
  }

  /// What the host knows about the camera the live session holds.
  ///
  /// Zeroed with no session, where the tile has no camera to be capped against
  /// and the configured width stands.
  private func cameraTileSource() -> CameraTileSource {
    guard let session else { return CameraTileSource() }
    return CameraTileSource(
      aspectRatio: session.cameraFrameProvider.aspectRatio,
      pixelWidth: session.cameraFrameProvider.pixelWidth,
      canvasWidth: session.outputCanvasSize.width)
  }

  private func start(result: @escaping FlutterResult) async {
    do {
      try await currentSession().start()
      // The strip, and the camera preview when there is one, were shown between
      // `prepare` and here — so the stream started on a filter that names
      // neither (§6). Not awaited: the capture is already running, the
      // window-level `sharingType = .none` is already keeping both out of the
      // frame, and the redundant half of the rule must not delay the answer to
      // `start`.
      Task { await self.refreshCaptureExclusions() }
      await MainActor.run { result(nil) }
    } catch {
      await MainActor.run { result(Self.flutterError(error)) }
    }
  }

  /// Re-points a live capture at a filter that excludes the overlay windows on
  /// screen now, and never drops a request to (§6).
  ///
  /// A rebuild answers "is every overlay on screen *now* named in the filter?",
  /// so a second announcement arriving while one is in flight is not a repeat
  /// of it: the panel it is about appeared after the running rebuild had
  /// already read the window list. Dropping it would leave that window out of
  /// the exclusion list until something else happened to appear. It is
  /// remembered, and the rebuild goes round once more instead — the same
  /// coalescing `scheduleStripResize` does on the overlay side.
  private func refreshCaptureExclusions() async {
    exclusionLock.lock()
    let running = _exclusionRebuildInFlight
    _exclusionRebuildInFlight = true
    if running { _exclusionRebuildPending = true }
    exclusionLock.unlock()
    guard !running else { return }

    var again = true
    while again {
      await rebuildContentFilter()
      exclusionLock.lock()
      again = _exclusionRebuildPending
      _exclusionRebuildPending = false
      _exclusionRebuildInFlight = again
      exclusionLock.unlock()
    }
  }

  /// One rebuild, or nothing when the live filter is already complete.
  ///
  /// Whether it is needed at all is `CaptureExclusionPolicy`'s decision, in
  /// `RecorderCore` where `swift test` executes it: a window source cannot show
  /// an overlay in the first place, and an overlay already in the list must not
  /// spend a `SCShareableContent` fetch every time a menu reopens.
  ///
  /// Every failure is swallowed. This is the second of §6's two mechanisms —
  /// each panel's own `sharingType = .none` is untouched by anything here — so
  /// a rebuild that will not apply is never a reason to fail, or to report,
  /// a recording that is running.
  private func rebuildContentFilter() async {
    let panels = await MainActor.run {
      (onScreen: self.overlays.onScreenWindowIDs, all: self.overlays.excludedWindowIDs)
    }
    exclusionLock.lock()
    let sourceId = _activeSourceId
    let excludedByFilter = _filterExcludedIDs
    exclusionLock.unlock()

    guard let sourceId, let session, session.isActive,
      CaptureExclusionPolicy.needsFilterRebuild(
        sourceId: sourceId, onScreenOverlayIDs: panels.onScreen,
        excludedByFilter: excludedByFilter)
    else { return }

    do {
      let content = try await enumerator.shareableContent()
      let (filter, _) = try enumerator.filter(
        forSourceId: sourceId, excludedWindowIDs: panels.all, content: content)
      await session.updateContentFilter(filter)
      // Only if this is still the recording it was for. A rebuild spans a
      // system call, and a session released while it was in flight has already
      // cleared the record — writing into it here would leave a finished
      // recording's exclusions standing over the next one's.
      rememberCaptureFilter(
        sourceId: sourceId, requested: panels.all, listedIn: content,
        onlyIfStillActive: true)
    } catch {
      // Nothing to do and nothing to say; see above.
    }
  }

  /// Records what a filter just built actually excludes.
  ///
  /// The intersection, not the request: `SCContentFilter` can only be given
  /// windows the shareable content lists, so an id of ours that was off screen
  /// at that moment was silently dropped — and remembering it as excluded is
  /// exactly how a window ends up in a recording with nobody noticing.
  private func rememberCaptureFilter(
    sourceId: String, requested: Set<CGWindowID>,
    listedIn content: SCShareableContent, onlyIfStillActive: Bool = false
  ) {
    let listed = Set(content.windows.map { $0.windowID })
    exclusionLock.lock()
    defer { exclusionLock.unlock() }
    if onlyIfStillActive, _activeSourceId != sourceId { return }
    _activeSourceId = sourceId
    _filterExcludedIDs = requested.intersection(listed)
  }

  private func forgetCaptureFilter() {
    exclusionLock.lock()
    _activeSourceId = nil
    _filterExcludedIDs = []
    exclusionLock.unlock()
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
