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
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = RecorderMacosPlugin()
    instance.attach(registrar: registrar)
  }

  private func attach(registrar: FlutterPluginRegistrar) {
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
        await MainActor.run { result(nil) }
      }

    case "setMicrophoneEnabled":
      session?.setMicrophoneEnabled(arguments["enabled"] as? Bool ?? false)
      result(nil)

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
      try session.prepare(configuration: configuration, filter: filter)
      await self.replaceSession(with: session)
      await MainActor.run { result(nil) }
    } catch {
      await MainActor.run { result(Self.flutterError(error)) }
    }
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
