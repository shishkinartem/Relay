import AVFoundation
import CoreMedia
import Foundation
import RecorderCore
import ScreenCaptureKit

/// Owns one capture session end to end: ScreenCaptureKit, the camera, the two
/// audio sources, composition, encoding and muxing.
///
/// Threading: every capture callback hands work to `processingQueue` and
/// returns immediately. Nothing here performs file or network I/O on a capture
/// callback, and no queue is unbounded — when the encoder is not ready the
/// frame is dropped and counted (`docs/architecture/media-pipeline.md`).
///
/// Timing: all sources are placed on one monotonic host-clock timeline with
/// paused intervals subtracted, so the file's duration equals the strip's
/// timer and wall-clock never enters the calculation (§8, §9).
final class RecordingSession: NSObject, SCStreamOutput, SCStreamDelegate {
  typealias EventSink = ([String: Any]) -> Void

  private let processingQueue = DispatchQueue(
    label: "relay.recording.session", qos: .userInitiated)
  private let streamQueue = DispatchQueue(
    label: "relay.recording.stream", qos: .userInitiated)
  private let audioQueue = DispatchQueue(
    label: "relay.recording.audio", qos: .userInitiated)

  private let emit: EventSink

  private var configuration: RecordingConfiguration?
  private var canvasSize: CGSize = .zero
  private var partURL: URL?
  private var finalURL: URL?

  private var stream: SCStream?
  /// The live stream's configuration, kept so the system-audio tap can be
  /// opened or closed without rebuilding the stream.
  private var streamConfiguration: SCStreamConfiguration?
  private var writer: AVAssetWriter?
  private var videoInput: AVAssetWriterInput?
  private var audioInput: AVAssetWriterInput?
  private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
  private var compositor: VideoCompositor?

  private let mixer = AudioMixer()
  private let camera = CameraCapture()
  private let microphone = MicrophoneCapture()

  private let stateBox = AtomicState()
  private let clock = SessionClock()
  private let inputs = InputFlags(
    microphone: true, camera: false, systemAudio: true)

  /// Touched only on `processingQueue`.
  private var lastVideoPTS: CMTime = .invalid
  private var capturedFrames = 0
  private var encodedFrames = 0
  private var droppedFrames = 0

  private var ticker: DispatchSourceTimer?
  private var finished = false

  /// Held for exactly as long as a session is live. See `beginActivity()`.
  private var activityToken: NSObjectProtocol?

  /// Live camera frames for the preview texture.
  var cameraFrameProvider: CameraCapture { camera }

  init(emit: @escaping EventSink) {
    self.emit = emit
    super.init()
    camera.onFrame = { [weak self] in self?.onCameraFrame?() }
  }

  /// Last resort, for a session released while it still holds hardware —
  /// dropped by the plugin, or the process winding down.
  ///
  /// Every ordinary exit runs `tearDown()` and this finds nothing left to do.
  /// It exists because "every ordinary exit" was not true until recently, and
  /// a recorder that leaks a live capture leaks the camera light with it.
  deinit {
    ticker?.cancel()
    if let token = activityToken {
      ProcessInfo.processInfo.endActivity(token)
    }
    camera.stop()
    microphone.stop()
    stream?.stopCapture { _ in }
  }

  /// Set by the plugin to mark the preview texture dirty.
  var onCameraFrame: (() -> Void)?

  private var state: PlatformRecorderState { stateBox.current }

  var isActive: Bool {
    switch stateBox.current {
    case .recording, .paused, .preparing, .prepared, .stopping, .finalizing:
      return true
    default:
      return false
    }
  }

  var isCameraEnabled: Bool { inputs.cameraEnabled }

  // MARK: - lifecycle

  func prepare(configuration: RecordingConfiguration, filter: SCContentFilter) throws {
    guard state == .idle || state == .finalized || state == .failed else {
      throw RecorderError(.invalidState, "A recording is already in progress.")
    }
    reset()
    transition(.preparing)

    self.configuration = configuration
    inputs.microphoneEnabled = configuration.microphoneEnabled
    inputs.cameraEnabled = configuration.cameraEnabled
    inputs.systemAudioEnabled = configuration.systemAudioEnabled
    canvasSize = configuration.canvasSize()
    compositor = VideoCompositor(
      canvasSize: canvasSize, overlay: configuration.cameraOverlay)

    let directory = URL(fileURLWithPath: configuration.outputDirectoryPath)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true)
    let part = directory.appendingPathComponent(
      "recording-\(configuration.recordingId).part")
    let final = directory.appendingPathComponent(
      "recording-\(configuration.recordingId).mp4")
    if FileManager.default.fileExists(atPath: part.path) {
      try FileManager.default.removeItem(at: part)
    }
    partURL = part
    finalURL = final

    try makeWriter(at: part, configuration: configuration)
    try makeStream(filter: filter, configuration: configuration)

    if inputs.cameraEnabled {
      do { try camera.start() } catch {
        inputs.cameraEnabled = false
        emitError(error, fatal: false)
      }
    }
    if inputs.microphoneEnabled {
      do { try startMicrophone() } catch {
        inputs.microphoneEnabled = false
        emitError(error, fatal: false)
      }
    }

    transition(.prepared)
  }

  func start() async throws {
    guard state == .prepared, let stream, let writer else {
      throw RecorderError(.invalidState, "The session is not prepared.")
    }
    guard writer.startWriting() else {
      throw RecorderError(
        .encodingFailed, "The encoder refused to start.",
        details: writer.error?.localizedDescription)
    }
    writer.startSession(atSourceTime: .zero)
    do {
      try await stream.startCapture()
    } catch {
      throw RecorderError(
        .captureFailed, "The capture session could not be started.",
        details: error.localizedDescription)
    }
    transition(.recording)
    beginActivity()
    startTicker()
    emitInputs()
  }

  /// Tells macOS that a recording is user-initiated work, for as long as it
  /// runs.
  ///
  /// A session spends its whole life with no ordinary window on screen (§6)
  /// and usually with the application not even frontmost — precisely the shape
  /// App Nap looks for. Under it timers are coalesced, I/O is deprioritised
  /// and the process is throttled: on a recorder that is late ticks, a
  /// stuttering control strip and dropped frames, all of it invisible in the
  /// code and impossible to reproduce on a machine that happens to be plugged
  /// in.
  ///
  /// `.userInitiated` is not one flag but the documented set for exactly this
  /// case. Besides suppressing App Nap it disables idle *system* sleep, which
  /// would otherwise truncate a long recording, and both sudden and automatic
  /// termination — the same process death `RecorderWindowPolicy` guards
  /// against from the AppKit side.
  ///
  /// Idle *display* sleep is deliberately left alone: blanking the screen is
  /// the user's power policy, not something a recorder should override behind
  /// their back. Whether a sleeping display starves ScreenCaptureKit is an
  /// open question for the §24 soak runs, which have not been made.
  private func beginActivity() {
    guard activityToken == nil else { return }
    activityToken = ProcessInfo.processInfo.beginActivity(
      options: [.userInitiated],
      reason: "Relay is recording the screen")
  }

  /// Idempotent: every session exit runs through `tearDown`, and a hold that
  /// was never taken must not be released.
  private func endActivity() {
    guard let token = activityToken else { return }
    ProcessInfo.processInfo.endActivity(token)
    activityToken = nil
  }

  func pause() throws {
    guard stateBox.transition(to: .paused, from: [.recording]) else {
      throw RecorderError(.invalidState, "The session is not recording.")
    }
    clock.pause()
    emitState(.paused)
  }

  func resume() throws {
    guard stateBox.transition(to: .recording, from: [.paused]) else {
      throw RecorderError(.invalidState, "The session is not paused.")
    }
    clock.resume()
    emitState(.recording)
  }

  /// Idempotent: a second stop returns the same finalized file.
  ///
  /// The claim on `.stopping` is the guard, not a preceding `isActive` check —
  /// two Stop clicks can both pass a check and only one may finalize.
  func stop() async throws -> [String: Any] {
    guard
      stateBox.transition(to: .stopping, from: [.recording, .paused, .prepared])
    else {
      if stateBox.current == .finalized, let finalURL {
        return try metadata(for: finalURL)
      }
      throw RecorderError(.invalidState, "There is no recording to stop.")
    }
    // Every exit from here releases the hardware, the power assertion and the
    // writer. Five throwing paths below used to skip it and leave the session
    // `.finalizing` with the stream still attached — a state `abort()` refuses,
    // so nothing could reach it afterwards.
    defer { tearDown() }
    emitState(.stopping)
    stopTicker()

    await stopSources()
    transition(.finalizing)

    do {
      return try await finalizeOutput()
    } catch {
      // A failed finalization is terminal, and `.failed` is a state the plugin
      // and `abort()` can still act on where `.finalizing` is not. A failure
      // *after* the file reached its final name leaves `.finalized` alone: the
      // recording exists, and a second stop returns it.
      if stateBox.current != .finalized {
        transition(.failed)
      }
      throw error
    }
  }

  /// Closes the writer inputs and moves `.part` onto its final name.
  ///
  /// Split out of `stop()` so every failure inside it funnels through one
  /// `catch`, and so the rendezvous below cannot be skipped by a new early
  /// return.
  private func finalizeOutput() async throws -> [String: Any] {
    // Both capture queues may still hold a block that appends to a writer
    // input. Appending after `markAsFinished()`, or from two threads at once,
    // raises `NSInternalInconsistencyException` — uncatchable from Swift, so a
    // hard crash exactly while the user's recording is being written out. The
    // marks therefore happen *on* the queues that do the appending, after
    // every block already scheduled there has run.
    audioQueue.sync {
      if let tail = mixer.flush(), let audioInput,
        audioInput.isReadyForMoreMediaData
      {
        audioInput.append(tail)
      }
      audioInput?.markAsFinished()
    }
    processingQueue.sync {
      videoInput?.markAsFinished()
    }

    guard let writer else {
      throw RecorderError(.finalizationFailed, "The encoder was already gone.")
    }
    await writer.finishWriting()

    if writer.status != .completed {
      throw mapWriterError(writer.error)
    }

    guard let partURL, let finalURL else {
      throw RecorderError(.finalizationFailed, "The output path was lost.")
    }
    if FileManager.default.fileExists(atPath: finalURL.path) {
      try? FileManager.default.removeItem(at: finalURL)
    }
    try FileManager.default.moveItem(at: partURL, to: finalURL)

    transition(.finalized)
    return try metadata(for: finalURL)
  }

  /// Stops the three capture sources. Safe to call more than once.
  ///
  /// The stream stop is given a deadline. `stopCapture()` talks to a system
  /// daemon, and an unbounded await on it is not a slow stop but a permanent
  /// one: the session stays `.stopping` forever, a state both `stop()` and
  /// `abort()` refuse, so nothing on either side of the channel can reach the
  /// session again and the capture — with its screen-recording indicator —
  /// outlives every UI that could stop it. Timing out at least lets teardown
  /// finish and the reference drop, so `deinit` gets its last attempt.
  private func stopSources() async {
    if let stream {
      await Deadline.run(seconds: 5) { try? await stream.stopCapture() }
    }
    camera.stop()
    microphone.stop()
  }

  /// Aborts without finalizing. The `.part` artefact is left on disk (§18).
  func abort() async {
    guard
      stateBox.transition(
        to: .stopping,
        // `.failed` is included so `dispose` can still release a session the
        // platform killed. Without it the abort is refused and the writer, the
        // camera and the microphone survive the session that owned them.
        from: [.preparing, .prepared, .recording, .paused, .failed])
    else { return }
    defer { tearDown() }
    stopTicker()
    await stopSources()
    // The same rendezvous `finalizeOutput()` makes, and for the same reason:
    // an append already in flight on either capture queue must land before its
    // input is marked finished.
    audioQueue.sync { audioInput?.markAsFinished() }
    processingQueue.sync { videoInput?.markAsFinished() }
    if let writer, writer.status == .writing {
      await writer.finishWriting()
    }
    transition(.idle)
  }

  /// Releases everything this session still holds, from any state.
  ///
  /// `abort()` is not that call and should not be made into one: it refuses a
  /// `.finalized` session, correctly, because there is nothing left to abort
  /// and turning a finished recording back into an idle one would lose the
  /// "a second stop returns the same file" guarantee. But "drop this session"
  /// still has to work on a finished one — it owns two configured capture
  /// sessions, and if a stop wedged it may still own a live stream. This is the
  /// one call that always leaves nothing behind, and it is what the plugin uses
  /// when a session is replaced or the user leaves the post-recording screen.
  func release() async {
    switch stateBox.current {
    case .preparing, .prepared, .recording, .paused, .failed:
      await abort()
    case .stopping, .finalizing:
      // A stop already owns this session's teardown. It marks the writer inputs
      // finished on the queues that append to them, moves the `.part` onto its
      // final name and runs `tearDown()` from its own `defer`. Tearing down
      // underneath it drops the writer mid-finalization — the stop then fails
      // with "The encoder was already gone" and a recording that was about to
      // succeed is stranded as a `.part` needing §18 recovery. It also races
      // the two capture queues for the inputs. So: leave it alone. The stop
      // releases everything, and `deinit` is the backstop if it never does.
      return
    default:
      stopTicker()
      await stopSources()
      tearDown()
    }
    camera.release()
    microphone.release()
  }

  // MARK: - runtime toggles

  func setMicrophoneEnabled(_ enabled: Bool) {
    guard inputs.microphoneEnabled != enabled else { return }
    inputs.microphoneEnabled = enabled
    if enabled && !microphone.isRunning {
      do { try startMicrophone() } catch {
        inputs.microphoneEnabled = false
        emitError(error, fatal: false)
      }
    }
    // A disabled source stops contributing to the mix but keeps its stream, so
    // toggling never restarts capture (§8).
    emitInputs()
  }

  /// Switches system audio, tap included.
  ///
  /// Turning it *off* is immediate and does not disturb the stream: the mixer
  /// stops taking the buffers, which is the §8 rule that a toggle never
  /// restarts capture. Turning it *on* may have to reopen a tap that
  /// `prepare` never opened, because the session was started with system audio
  /// off — and that is a change only the live stream can make, asynchronously.
  /// The switch is applied optimistically and reverted if the stream refuses,
  /// so the strip never claims to be recording audio that is not arriving.
  func setSystemAudioEnabled(_ enabled: Bool) {
    guard inputs.systemAudioEnabled != enabled else { return }
    inputs.systemAudioEnabled = enabled
    emitInputs()

    guard enabled, let stream, let configuration = streamConfiguration,
      !configuration.capturesAudio
    else { return }

    configuration.capturesAudio = true
    Task { [weak self] in
      do {
        try await stream.updateConfiguration(configuration)
      } catch {
        configuration.capturesAudio = false
        guard let self, self.inputs.systemAudioEnabled else { return }
        self.inputs.systemAudioEnabled = false
        self.emitError(
          RecorderError(
            .systemAudioUnavailable,
            "System audio could not be switched on for this recording.",
            details: error.localizedDescription),
          fatal: false)
        self.emitInputs()
      }
    }
  }

  func setCameraEnabled(_ enabled: Bool) {
    guard inputs.cameraEnabled != enabled else { return }
    inputs.cameraEnabled = enabled
    if enabled {
      do { try camera.start() } catch {
        inputs.cameraEnabled = false
        emitError(error, fatal: false)
      }
    } else {
      camera.stop()
    }
    emitInputs()
  }

  // MARK: - SCStreamOutput

  func stream(
    _ stream: SCStream,
    didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
    of type: SCStreamOutputType
  ) {
    switch type {
    case .screen:
      handleScreen(sampleBuffer)
    case .audio:
      handleSystemAudio(sampleBuffer)
    default:
      break
    }
  }

  func stream(_ stream: SCStream, didStopWithError error: Error) {
    let details = error.localizedDescription
    // Claiming `.stopping` first does two things: it makes the failure ignore a
    // stop the user already started — which would otherwise flip a successful
    // finalization to `.failed` — and it guarantees the teardown below runs
    // once. Reporting the failure without tearing down left the stream, the
    // camera (LED on), the microphone and the 250 ms ticker alive for the rest
    // of the process, and those stale ticks drove the *next* session's timer.
    guard
      stateBox.transition(to: .stopping, from: [.recording, .paused, .prepared])
    else { return }
    Task { await self.failAfterTeardown(details: details) }
  }

  /// Ends a session that the platform stopped underneath us.
  ///
  /// The partial `.part` artefact is deliberately left on disk for startup
  /// recovery (§18); nothing here deletes or renames it.
  private func failAfterTeardown(details: String) async {
    stopTicker()
    // The stream is already stopped — asking it again throws.
    camera.stop()
    microphone.stop()
    if let tail = mixer.flush(), let audioInput, audioInput.isReadyForMoreMediaData {
      audioInput.append(tail)
    }
    videoInput?.markAsFinished()
    audioInput?.markAsFinished()
    if let writer, writer.status == .writing {
      await writer.finishWriting()
    }
    transition(.failed)
    emitError(
      RecorderError(
        .sourceClosed, "The capture source stopped.", details: details),
      fatal: true)
    tearDown()
  }

  // MARK: - frame handling

  private func handleScreen(_ sampleBuffer: CMSampleBuffer) {
    guard CMSampleBufferIsValid(sampleBuffer), isFrameComplete(sampleBuffer)
    else { return }

    let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    // The sample buffer is captured, not its image buffer: ScreenCaptureKit
    // recycles the backing surface as soon as the callback returns, and a
    // CVPixelBuffer taken out of it has no independent lifetime. Capturing the
    // CMSampleBuffer keeps it alive across the hop to the processing queue.
    processingQueue.async { [weak self] in
      guard let self else { return }
      self.capturedFrames += 1
      guard self.stateBox.current == .recording,
        let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
        let seconds = self.clock.position(of: pts, advancingElapsed: true)
      else { return }
      self.encode(
        pixelBuffer: pixelBuffer,
        at: CMTime(seconds: seconds, preferredTimescale: 90_000))
    }
  }

  private func encode(pixelBuffer: CVPixelBuffer, at presentation: CMTime) {
    guard let adaptor, let videoInput, let compositor, let writer,
      writer.status == .writing
    else { return }
    // Bounded by the encoder itself: when it is not ready the newest frame is
    // dropped rather than queued, so memory cannot grow under load.
    guard videoInput.isReadyForMoreMediaData else {
      droppedFrames += 1
      return
    }
    // The validity check is not decoration. `CMTimeCompare` reports every real
    // timestamp as *less than* `CMTime.invalid`, so comparing against the
    // initial `.invalid` rejects the first frame — and because `lastVideoPTS`
    // only advances on a successful append, it stays invalid and every
    // subsequent frame is rejected too. The recording ends up empty.
    if lastVideoPTS.isValid, presentation <= lastVideoPTS {
      droppedFrames += 1
      return
    }

    let cameraFrame = inputs.cameraEnabled ? camera.copyLatestFrame() : nil

    if compositor.canPassThrough(screen: pixelBuffer, cameraEnabled: cameraFrame != nil) {
      if adaptor.append(pixelBuffer, withPresentationTime: presentation) {
        lastVideoPTS = presentation
        encodedFrames += 1
      } else {
        droppedFrames += 1
      }
      return
    }

    guard let pool = adaptor.pixelBufferPool else {
      droppedFrames += 1
      return
    }
    var destination: CVPixelBuffer?
    guard
      CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &destination)
        == kCVReturnSuccess,
      let destination
    else {
      droppedFrames += 1
      return
    }
    compositor.render(
      screen: pixelBuffer, camera: cameraFrame, into: destination)
    if adaptor.append(destination, withPresentationTime: presentation) {
      lastVideoPTS = presentation
      encodedFrames += 1
    } else {
      droppedFrames += 1
    }
  }

  private func handleSystemAudio(_ sampleBuffer: CMSampleBuffer) {
    guard inputs.systemAudioEnabled else { return }
    let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    audioQueue.async { [weak self] in
      guard let self, self.stateBox.current == .recording,
        let seconds = self.clock.position(of: pts, advancingElapsed: false)
      else { return }
      self.mixer.mix(
        sampleBuffer: sampleBuffer, timelineSeconds: seconds,
        sourceKey: "systemAudio")
      self.drainAudio(upTo: seconds)
    }
  }

  private func handleMicrophone(_ sampleBuffer: CMSampleBuffer) {
    guard inputs.microphoneEnabled else { return }
    let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    audioQueue.async { [weak self] in
      guard let self, self.stateBox.current == .recording,
        let seconds = self.clock.position(of: pts, advancingElapsed: false)
      else { return }
      self.mixer.mix(
        sampleBuffer: sampleBuffer, timelineSeconds: seconds,
        sourceKey: "microphone")
      self.drainAudio(upTo: seconds)
    }
  }

  private func drainAudio(upTo seconds: Double) {
    guard let audioInput, audioInput.isReadyForMoreMediaData,
      let writer, writer.status == .writing
    else { return }
    while let chunk = mixer.drain(upToTimelineSeconds: seconds) {
      if !audioInput.append(chunk) { break }
      if !audioInput.isReadyForMoreMediaData { break }
    }
  }

  // MARK: - frame validity

    /// ScreenCaptureKit marks incomplete frames; encoding them wastes the
  /// encoder and can duplicate content.
  private func isFrameComplete(_ sampleBuffer: CMSampleBuffer) -> Bool {
    guard
      let attachments = CMSampleBufferGetSampleAttachmentsArray(
        sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
      let info = attachments.first,
      let raw = info[.status] as? Int,
      let status = SCFrameStatus(rawValue: raw)
    else { return false }
    return status == .complete
  }

  // MARK: - setup

  private func makeWriter(at url: URL, configuration: RecordingConfiguration) throws {
    let writer: AVAssetWriter
    do {
      writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    } catch {
      throw RecorderError(
        .encodingFailed, "The output file could not be created.",
        details: error.localizedDescription)
    }
    // Fragmented output: a session that is killed still leaves a readable file
    // up to the last flushed fragment, which is what startup recovery repairs.
    writer.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 1)
    writer.shouldOptimizeForNetworkUse = false

    let bitrate = RecordingSession.videoBitrate(
      height: Int(canvasSize.height), frameRate: configuration.frameRate)
    let videoInput = AVAssetWriterInput(
      mediaType: .video,
      outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: Int(canvasSize.width),
        AVVideoHeightKey: Int(canvasSize.height),
        AVVideoCompressionPropertiesKey: [
          AVVideoAverageBitRateKey: bitrate,
          AVVideoExpectedSourceFrameRateKey: configuration.frameRate,
          AVVideoMaxKeyFrameIntervalKey: configuration.frameRate * 2,
          AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
          AVVideoAllowFrameReorderingKey: false,
        ],
      ])
    videoInput.expectsMediaDataInRealTime = true

    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: videoInput,
      sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: Int(canvasSize.width),
        kCVPixelBufferHeightKey as String: Int(canvasSize.height),
        kCVPixelBufferMetalCompatibilityKey as String: true,
      ])

    let audioInput = AVAssetWriterInput(
      mediaType: .audio,
      outputSettings: [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: AudioMixer.sampleRate,
        AVNumberOfChannelsKey: AudioMixer.channelCount,
        AVEncoderBitRateKey: 192_000,
      ])
    audioInput.expectsMediaDataInRealTime = true

    guard writer.canAdd(videoInput), writer.canAdd(audioInput) else {
      throw RecorderError(.encodingFailed, "The encoder rejected the output format.")
    }
    writer.add(videoInput)
    writer.add(audioInput)

    self.writer = writer
    self.videoInput = videoInput
    self.audioInput = audioInput
    self.adaptor = adaptor
  }

  private func makeStream(
    filter: SCContentFilter, configuration: RecordingConfiguration
  ) throws {
    let streamConfiguration = SCStreamConfiguration()
    streamConfiguration.width = Int(canvasSize.width)
    streamConfiguration.height = Int(canvasSize.height)
    streamConfiguration.minimumFrameInterval = CMTime(
      value: 1, timescale: CMTimeScale(configuration.frameRate))
    streamConfiguration.showsCursor = configuration.showCursor
    streamConfiguration.pixelFormat = kCVPixelFormatType_32BGRA
    streamConfiguration.queueDepth = 6
    // The tap is opened only when the user asked for system audio. It used to
    // be unconditional, with unwanted buffers discarded in `handleSystemAudio`
    // — which meant macOS was told this application taps system audio in every
    // session, including the ones where the strip says it is off. What the OS
    // reports about a recorder has to match what the recorder's own UI says.
    streamConfiguration.capturesAudio = configuration.systemAudioEnabled
    streamConfiguration.sampleRate = Int(AudioMixer.sampleRate)
    streamConfiguration.channelCount = AudioMixer.channelCount
    streamConfiguration.excludesCurrentProcessAudio = true

    let stream = SCStream(
      filter: filter, configuration: streamConfiguration, delegate: self)
    do {
      try stream.addStreamOutput(
        self, type: .screen, sampleHandlerQueue: streamQueue)
      try stream.addStreamOutput(
        self, type: .audio, sampleHandlerQueue: streamQueue)
    } catch {
      throw RecorderError(
        .captureFailed, "The capture output could not be attached.",
        details: error.localizedDescription)
    }
    self.stream = stream
    self.streamConfiguration = streamConfiguration
  }

  private func startMicrophone() throws {
    microphone.onSampleBuffer = { [weak self] buffer in
      self?.handleMicrophone(buffer)
    }
    try microphone.start()
  }

  // MARK: - events

  private func transition(_ next: PlatformRecorderState) {
    guard stateBox.set(next) else { return }
    emit(["type": "state", "state": next.rawValue])
  }

  private func emitState(_ state: PlatformRecorderState) {
    emit(["type": "state", "state": state.rawValue])
  }

  private func emitInputs() {
    let snapshot = inputs.snapshot
    emit([
      "type": "inputChanged",
      "microphoneEnabled": snapshot.microphone,
      "cameraEnabled": snapshot.camera,
      "systemAudioEnabled": snapshot.systemAudio,
    ])
  }

  private func emitError(_ error: Error, fatal: Bool) {
    let recorderError =
      error as? RecorderError
      ?? RecorderError(.unknown, error.localizedDescription)
    emit([
      "type": "error",
      "code": recorderError.code.rawValue,
      "message": recorderError.message,
      "details": recorderError.details as Any,
      "fatal": fatal,
    ])
    if fatal { transition(.failed) }
  }

  /// Reports a fatal mid-session failure and then releases everything.
  ///
  /// Reporting used to be the whole handler. That left the `SCStream`
  /// capturing, the camera light on, the microphone open and the
  /// `beginActivity` hold taken for the life of the process: the session
  /// reached `.failed` without a teardown, and nothing on either side of the
  /// channel could reach it afterwards — `abort()` does accept `.failed`, but
  /// the Dart side never called it.
  ///
  /// The release runs on a detached task on purpose. This is called from the
  /// ticker, which fires on `processingQueue`, and the rendezvous inside
  /// `releaseAfterFailure()` would deadlock on that queue.
  private func failAfterTeardown(_ error: Error) {
    guard stateBox.current != .failed else { return }
    stopTicker()
    emitError(error, fatal: true)
    Task.detached { [weak self] in
      await self?.releaseAfterFailure()
    }
  }

  private func releaseAfterFailure() async {
    await stopSources()
    // Rendezvous only. The writer has already failed, so marking its inputs
    // finished is neither useful nor safe; waiting for both queues is, because
    // `tearDown()` drops the inputs a scheduled block may still be appending
    // to.
    processingQueue.sync {}
    audioQueue.sync {}
    tearDown()
  }

  private func startTicker() {
    let timer = DispatchSource.makeTimerSource(queue: processingQueue)
    // The first fire is one interval away, not immediate: `start()` has not
    // returned yet, so a tick emitted now reaches the application while its
    // session is still `preparing` and is rejected as illegal.
    timer.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250))
    timer.setEventHandler { [weak self] in
      guard let self else { return }
      // A paused session's elapsed time does not advance, so a tick carries no
      // new information and the application rejects it as illegal while paused.
      if self.stateBox.current == .recording {
        self.emit([
          "type": "tick",
          "elapsedMs": Int(self.clock.elapsedSeconds * 1000),
        ])
      }
      if self.capturedFrames % 40 == 0 {
        self.emitStats()
      }
      if let writer = self.writer, writer.status == .failed {
        self.failAfterTeardown(self.mapWriterError(writer.error))
      }
    }
    timer.resume()
    ticker = timer
  }

  private func stopTicker() {
    ticker?.cancel()
    ticker = nil
  }

  private func emitStats() {
    emit([
      "type": "stats",
      "capturedFrames": capturedFrames,
      "encodedFrames": encodedFrames,
      "droppedFrames": droppedFrames,
      "audioDiscontinuities": mixer.discontinuities,
      "avDriftMs": 0.0,
      "encoderName": "VideoToolbox H.264",
      "hardwareEncoding": true,
    ])
  }

  // MARK: - results

  private func metadata(for url: URL) throws -> [String: Any] {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
    let created = (attributes[.creationDate] as? Date) ?? Date()
    return [
      "path": url.path,
      "recordingId": configuration?.recordingId ?? "",
      "sizeBytes": size,
      "durationMs": Int(clock.elapsedSeconds * 1000),
      "createdAtMs": Int(created.timeIntervalSince1970 * 1000),
      "width": Int(canvasSize.width),
      "height": Int(canvasSize.height),
      "frameRate": configuration?.frameRate ?? 30,
      "hasAudio": true,
      "hasCamera": inputs.cameraEnabled,
    ]
  }

  private func mapWriterError(_ error: Error?) -> RecorderError {
    guard let error = error as NSError? else {
      return RecorderError(.finalizationFailed, "The recording could not be written out.")
    }
    if error.domain == AVFoundationErrorDomain,
      error.code == AVError.diskFull.rawValue
    {
      return RecorderError(
        .diskFull, "The disk ran out of space while recording.",
        details: error.localizedDescription)
    }
    return RecorderError(
      .encodingFailed, "The encoder failed while writing the recording.",
      details: error.localizedDescription)
  }

  // MARK: - teardown

  private func reset() {
    mixer.reset()
    clock.reset()
    processingQueue.sync {
      lastVideoPTS = .invalid
      capturedFrames = 0
      encodedFrames = 0
      droppedFrames = 0
    }
    finished = false
  }

  private func tearDown() {
    // Every exit — stop, abort and the fatal-error path — arrives here, so
    // this is the one place the hold is guaranteed to be released. It happens
    // after finalization, because writing a long file out is still part of the
    // work the system must not nap through.
    endActivity()
    stream = nil
    streamConfiguration = nil
    writer = nil
    videoInput = nil
    audioInput = nil
    adaptor = nil
    compositor = nil
  }

  /// Quality-oriented rates for screen content; not a user-facing setting (§11).
  static func videoBitrate(height: Int, frameRate: Int) -> Int {
    let base: Double = height >= 1000 ? 4_000_000 : 1_800_000
    let rateScale = Double(max(frameRate, 1)) / 30.0
    return Int(base * rateScale)
  }
}
