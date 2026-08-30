import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import RecorderCore

/// The camera source (§7).
///
/// One logical source with two consumers: the compositor, which draws it into
/// the picture-in-picture, and the preview window's texture. The preview is
/// never captured back off the screen.
final class CameraCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
  private let session = AVCaptureSession()
  private let output = AVCaptureVideoDataOutput()
  private let queue = DispatchQueue(label: "relay.camera.capture")
  private let frameLock = NSLock()
  /// The whole sample buffer is retained, not just its image buffer: the
  /// capture output recycles the backing surface once the delegate returns.
  private var latest: CMSampleBuffer?

  /// Called on the capture queue whenever a frame arrives, so the preview
  /// texture can be marked dirty without polling.
  var onFrame: (() -> Void)?

  private(set) var isRunning = false

  /// The camera's own width / height.
  ///
  /// Read from the active format rather than from a captured frame: the preview
  /// is placed as soon as `start()` returns, which is before the first frame
  /// arrives, and a placeholder shape there would put the preview somewhere the
  /// composited picture-in-picture is not.
  var aspectRatio: Double {
    for input in session.inputs {
      guard let deviceInput = input as? AVCaptureDeviceInput else { continue }
      let dimensions = CMVideoFormatDescriptionGetDimensions(
        deviceInput.device.activeFormat.formatDescription)
      if dimensions.width > 0, dimensions.height > 0 {
        return Double(dimensions.width) / Double(dimensions.height)
      }
    }
    if let buffer = copyLatestFrame() {
      let width = Double(CVPixelBufferGetWidth(buffer))
      let height = Double(CVPixelBufferGetHeight(buffer))
      if height > 0 {
        return width / height
      }
    }
    return 16.0 / 9.0
  }

  /// Opens `device`, which the session resolved from the configuration — nil
  /// where the machine has no camera at all (§33.2).
  ///
  /// The device arrives rather than being looked up here so one place decides
  /// what a null device id means: `InputDeviceEnumerator.defaultDevice`, which
  /// still evaluates exactly the expression this method used to hard-code.
  func start(device: AVCaptureDevice?) throws {
    guard !isRunning else { return }
    guard let device else {
      throw RecorderError(.cameraUnavailable, "No camera is available.")
    }
    guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
      throw RecorderError(
        .cameraUnavailable, "Camera access has not been granted.")
    }

    session.beginConfiguration()
    session.sessionPreset = .high
    for input in session.inputs { session.removeInput(input) }
    for existing in session.outputs { session.removeOutput(existing) }

    do {
      let input = try AVCaptureDeviceInput(device: device)
      guard session.canAddInput(input) else {
        throw RecorderError(.cameraUnavailable, "The camera could not be opened.")
      }
      session.addInput(input)
    } catch let error as RecorderError {
      session.commitConfiguration()
      throw error
    } catch {
      session.commitConfiguration()
      throw RecorderError(
        .cameraUnavailable, "The camera could not be opened.",
        details: error.localizedDescription)
    }

    output.videoSettings = [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ]
    // Dropping late frames is the bounded-queue policy for this producer: a
    // slow consumer must never grow a backlog of camera frames.
    output.alwaysDiscardsLateVideoFrames = true
    output.setSampleBufferDelegate(self, queue: queue)
    guard session.canAddOutput(output) else {
      session.commitConfiguration()
      throw RecorderError(.cameraUnavailable, "The camera output was refused.")
    }
    session.addOutput(output)
    session.commitConfiguration()

    session.startRunning()
    isRunning = true
  }

  func stop() {
    guard isRunning else { return }
    isRunning = false
    session.stopRunning()
    output.setSampleBufferDelegate(nil, queue: nil)
    frameLock.lock()
    latest = nil
    frameLock.unlock()
  }

  /// Detaches the device as well as stopping it.
  ///
  /// A stopped `AVCaptureSession` holds no device open, but it does keep its
  /// `AVCaptureDeviceInput` and output attached, so a session object that
  /// outlives its recording sits on a fully configured camera graph until the
  /// next `prepare` happens to reuse it. Releasing is what makes "the recording
  /// is over" true of the object graph and not only of the file.
  func release() {
    stop()
    session.beginConfiguration()
    for input in session.inputs { session.removeInput(input) }
    for existing in session.outputs { session.removeOutput(existing) }
    session.commitConfiguration()
  }

  /// The most recent frame. The returned buffer stays valid because the
  /// sample buffer that owns it is retained until it is replaced.
  func copyLatestFrame() -> CVPixelBuffer? {
    frameLock.lock()
    let sample = latest
    frameLock.unlock()
    guard let sample else { return nil }
    return CMSampleBufferGetImageBuffer(sample)
  }

  func captureOutput(
    _ output: AVCaptureOutput,
    didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    guard CMSampleBufferGetImageBuffer(sampleBuffer) != nil else { return }
    frameLock.lock()
    latest = sampleBuffer
    frameLock.unlock()
    onFrame?()
  }
}

/// Microphone capture (§8).
///
/// ScreenCaptureKit only gained microphone capture on macOS 15; the same
/// abstraction is satisfied here by AVFoundation, which works on every version
/// this build supports.
final class MicrophoneCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
  private let session = AVCaptureSession()
  private let output = AVCaptureAudioDataOutput()
  private let queue = DispatchQueue(label: "relay.microphone.capture")

  /// Called on the capture queue. Must not block or touch the file system.
  var onSampleBuffer: ((CMSampleBuffer) -> Void)?

  /// Guards the two things the capture queue shares with this object's owner:
  /// `running`, which `InputMeter` reads from its own queue to decide whether a
  /// recording already holds this microphone, and `level`, which the meter
  /// installs and clears while buffers are already arriving.
  private let stateLock = NSLock()
  private var running = false
  private var level: ((AudioLevel) -> Void)?

  /// The meter's tap, called on the capture queue with every buffer's level.
  ///
  /// A level, never the buffer: the meter reads the capture a recording already
  /// owns instead of opening a second handle on the same microphone (§33.7),
  /// and §3 keeps the audio itself native.
  var onLevel: ((AudioLevel) -> Void)? {
    get {
      stateLock.lock()
      defer { stateLock.unlock() }
      return level
    }
    set {
      stateLock.lock()
      level = newValue
      stateLock.unlock()
    }
  }

  var isRunning: Bool {
    stateLock.lock()
    defer { stateLock.unlock() }
    return running
  }

  private func setRunning(_ value: Bool) {
    stateLock.lock()
    running = value
    stateLock.unlock()
  }

  /// Opens `device` — the one the session resolved, or the meter's own default.
  /// See `CameraCapture.start(device:)` for why it is passed in.
  func start(device: AVCaptureDevice?) throws {
    guard !isRunning else { return }
    guard let device else {
      throw RecorderError(.microphoneUnavailable, "No microphone is available.")
    }
    guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
      throw RecorderError(
        .microphoneUnavailable, "Microphone access has not been granted.")
    }

    session.beginConfiguration()
    for input in session.inputs { session.removeInput(input) }
    for existing in session.outputs { session.removeOutput(existing) }
    do {
      let input = try AVCaptureDeviceInput(device: device)
      guard session.canAddInput(input) else {
        session.commitConfiguration()
        throw RecorderError(
          .microphoneUnavailable, "The microphone could not be opened.")
      }
      session.addInput(input)
    } catch let error as RecorderError {
      session.commitConfiguration()
      throw error
    } catch {
      session.commitConfiguration()
      throw RecorderError(
        .microphoneUnavailable, "The microphone could not be opened.",
        details: error.localizedDescription)
    }

    output.audioSettings = [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVSampleRateKey: AudioMixer.sampleRate,
      AVNumberOfChannelsKey: AudioMixer.channelCount,
      AVLinearPCMBitDepthKey: 32,
      AVLinearPCMIsFloatKey: true,
      AVLinearPCMIsBigEndianKey: false,
      AVLinearPCMIsNonInterleaved: false,
    ]
    output.setSampleBufferDelegate(self, queue: queue)
    guard session.canAddOutput(output) else {
      session.commitConfiguration()
      throw RecorderError(
        .microphoneUnavailable, "The microphone output was refused.")
    }
    session.addOutput(output)
    session.commitConfiguration()

    session.startRunning()
    setRunning(true)
  }

  func stop() {
    guard isRunning else { return }
    setRunning(false)
    session.stopRunning()
    output.setSampleBufferDelegate(nil, queue: nil)
  }

  /// Detaches the device as well as stopping it. See `CameraCapture.release()`.
  func release() {
    stop()
    session.beginConfiguration()
    for input in session.inputs { session.removeInput(input) }
    for existing in session.outputs { session.removeOutput(existing) }
    session.commitConfiguration()
  }

  func captureOutput(
    _ output: AVCaptureOutput,
    didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    onSampleBuffer?(sampleBuffer)
    // Measured only while something is metering, so an ordinary recording pays
    // nothing for a meter nobody asked for (§33.2).
    if let onLevel {
      onLevel(MicrophoneCapture.level(of: sampleBuffer))
    }
  }

  /// One buffer's peak and RMS, in linear amplitude.
  ///
  /// Reads the 32-bit float samples `output.audioSettings` above asks for; a
  /// buffer in any other format is reported as silence rather than as noise
  /// read out of a misread layout. The arithmetic itself is in `AudioLevel`,
  /// where `swift test` covers it.
  private static func level(of sampleBuffer: CMSampleBuffer) -> AudioLevel {
    guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
      let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
      asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
      asbd.mBitsPerChannel == 32
    else { return .silent }

    // Sized from the buffer rather than assumed: a non-interleaved list needs
    // one `AudioBuffer` per channel, and a list too small to hold it fails the
    // second call outright.
    var listSize = 0
    guard
      CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
        sampleBuffer, bufferListSizeNeededOut: &listSize, bufferListOut: nil,
        bufferListSize: 0, blockBufferAllocator: nil,
        blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil) == noErr,
      listSize >= MemoryLayout<AudioBufferList>.size
    else { return .silent }

    let memory = UnsafeMutableRawPointer.allocate(
      byteCount: listSize, alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { memory.deallocate() }
    let list = memory.bindMemory(to: AudioBufferList.self, capacity: 1)

    var blockBuffer: CMBlockBuffer?
    guard
      CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
        sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: list,
        bufferListSize: listSize, blockBufferAllocator: nil,
        blockBufferMemoryAllocator: nil,
        flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
        blockBufferOut: &blockBuffer) == noErr
    else { return .silent }

    // The samples live in the block buffer, so it has to outlive the reads;
    // its last use above is an `inout` argument, which is where ARC would
    // otherwise be free to release it.
    return withExtendedLifetime(blockBuffer) {
      var level = AudioLevel.silent
      for buffer in UnsafeMutableAudioBufferListPointer(list) {
        guard let data = buffer.mData else { continue }
        let samples = UnsafeBufferPointer(
          start: data.assumingMemoryBound(to: Float.self),
          count: Int(buffer.mDataByteSize) / MemoryLayout<Float>.size)
        level = level.loudest(AudioLevel.measuring(samples))
      }
      return level
    }
  }
}
