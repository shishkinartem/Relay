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

  func start() throws {
    guard !isRunning else { return }
    guard
      let device = AVCaptureDevice.default(
        .builtInWideAngleCamera, for: .video, position: .front)
        ?? AVCaptureDevice.default(for: .video)
    else {
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

  private(set) var isRunning = false

  func start() throws {
    guard !isRunning else { return }
    guard let device = AVCaptureDevice.default(for: .audio) else {
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
    isRunning = true
  }

  func stop() {
    guard isRunning else { return }
    isRunning = false
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
  }
}
