import Foundation

/// The typed error codes shared with Dart.
///
/// These are `RecorderErrorCode` names; the Dart side maps a channel error's
/// code straight onto its enum, so no message strings are ever parsed
/// (`docs/architecture/platform-channel-contract.md`).
public enum RecorderErrorCode: String {
  case permissionDenied
  case sourceUnavailable
  case sourceClosed
  case cameraUnavailable
  case microphoneUnavailable
  case systemAudioUnavailable
  case captureFailed
  case encodingFailed
  case diskFull
  case finalizationFailed
  case invalidState
  case unsupported
  case unknown
}

public struct RecorderError: Error {
  public let code: RecorderErrorCode
  public let message: String
  public let details: String?

  public init(_ code: RecorderErrorCode, _ message: String, details: String? = nil) {
    self.code = code
    self.message = message
    self.details = details
  }
}

/// Platform-side session states, mirrored by `PlatformRecorderState` in Dart.
public enum PlatformRecorderState: String {
  case idle
  case preparing
  case prepared
  case recording
  case paused
  case stopping
  case finalizing
  case finalized
  case failed
}

/// Geometry and mirroring of the camera picture-in-picture.
///
/// Every value arrives from Dart as configuration; nothing here is a
/// compositor constant (`TECHNICAL_SPEC.md` §7, §28).
public struct CameraOverlayConfiguration {
  public var widthRatio: Double = 0.16
  public var aspectRatio: Double = 16.0 / 9.0
  public var followsSourceAspectRatio: Bool = true
  public var cornerRadius: Double = 0
  public var marginRatio: Double = 0.01
  public var corner: String = "bottomRight"
  public var mirrorPreview: Bool = true
  public var mirrorOutput: Bool = false

  public init() {}

  public init(map: [String: Any]) {
    widthRatio = map["widthRatio"] as? Double ?? widthRatio
    aspectRatio = map["aspectRatio"] as? Double ?? aspectRatio
    followsSourceAspectRatio =
      map["followsSourceAspectRatio"] as? Bool ?? followsSourceAspectRatio
    cornerRadius = map["cornerRadius"] as? Double ?? cornerRadius
    marginRatio = map["marginRatio"] as? Double ?? marginRatio
    corner = map["corner"] as? String ?? corner
    mirrorPreview = map["mirrorPreview"] as? Bool ?? mirrorPreview
    mirrorOutput = map["mirrorOutput"] as? Bool ?? mirrorOutput
  }

  /// Whether the tile pins its top or its bottom edge when its height changes.
  public var pinsTopEdge: Bool { corner == "topLeft" || corner == "topRight" }

  /// The tile's width / height for a camera of `sourceAspectRatio`.
  ///
  /// A tile shaped differently from the camera can only be filled by cropping
  /// or stretching. Taking the camera's own shape removes the choice.
  public func effectiveAspectRatio(sourceAspectRatio: Double?) -> Double {
    if followsSourceAspectRatio, let source = sourceAspectRatio, source > 0 {
      return source
    }
    // A non-positive fallback is a malformed configuration, not a shape. It
    // used to clamp to 0.0001 here and to a square in `ResolvePipRect` on
    // Windows, so the same bad input produced a different tile on each
    // platform and nothing on the Dart side could see the difference. Both
    // now fall back to the default 16:9.
    return aspectRatio > 0 ? aspectRatio : 16.0 / 9.0
  }

  /// The picture-in-picture rectangle for a canvas of the given size, in the
  /// canvas' own top-left origin coordinate space.
  public func rect(canvasWidth: Double, canvasHeight: Double, sourceAspectRatio: Double? = nil)
    -> CGRect
  {
    let width = canvasWidth * widthRatio
    let height = width / effectiveAspectRatio(sourceAspectRatio: sourceAspectRatio)
    let margin = canvasWidth * marginRatio
    let left: Double
    switch corner {
    case "topLeft", "bottomLeft": left = margin
    default: left = canvasWidth - margin - width
    }
    let top: Double
    switch corner {
    case "topLeft", "topRight": top = margin
    default: top = canvasHeight - margin - height
    }
    return CGRect(x: left, y: top, width: width, height: height)
  }
}

/// Everything `prepare` needs, decoded once at the channel boundary.
public struct RecordingConfiguration {
  public let sourceId: String
  public let sourceType: String
  public let sourceWidth: Int
  public let sourceHeight: Int
  public let recordingId: String
  public let outputDirectoryPath: String
  public let quality: String
  public let targetHeight: Int
  public let frameRate: Int
  public let cameraEnabled: Bool
  public let microphoneEnabled: Bool
  public let systemAudioEnabled: Bool
  public let showCursor: Bool
  public let cameraOverlay: CameraOverlayConfiguration
  public let aspectRatioPolicy: String

  public init(map: [String: Any]) throws {
    guard let sourceId = map["sourceId"] as? String,
      let recordingId = map["recordingId"] as? String,
      let outputDirectoryPath = map["outputDirectoryPath"] as? String
    else {
      throw RecorderError(.invalidState, "The recording configuration is incomplete.")
    }
    self.sourceId = sourceId
    self.sourceType = map["sourceType"] as? String ?? "display"
    self.sourceWidth = map["sourceWidth"] as? Int ?? 0
    self.sourceHeight = map["sourceHeight"] as? Int ?? 0
    self.recordingId = recordingId
    self.outputDirectoryPath = outputDirectoryPath
    self.quality = map["quality"] as? String ?? "hd720"
    self.targetHeight = map["targetHeight"] as? Int ?? 720
    self.frameRate = map["frameRate"] as? Int ?? 30
    self.cameraEnabled = map["cameraEnabled"] as? Bool ?? false
    self.microphoneEnabled = map["microphoneEnabled"] as? Bool ?? true
    self.systemAudioEnabled = map["systemAudioEnabled"] as? Bool ?? true
    self.showCursor = map["showCursor"] as? Bool ?? true
    self.cameraOverlay = CameraOverlayConfiguration(
      map: map["cameraOverlay"] as? [String: Any] ?? [:])
    self.aspectRatioPolicy =
      (map["composition"] as? [String: Any])?["aspectRatioPolicy"] as? String
      ?? "containWithinPreset"
  }

  /// The encoded canvas, matching `VideoCompositionConfiguration` in Dart.
  ///
  /// Even dimensions because H.264 4:2:0 requires them.
  public func canvasSize() -> CGSize {
    let boxHeight = Double(targetHeight)
    let boxWidth = (boxHeight * 16.0 / 9.0).rounded()
    guard sourceWidth > 0, sourceHeight > 0,
      aspectRatioPolicy == "containWithinPreset"
    else {
      return CGSize(width: evenValue(boxWidth), height: evenValue(boxHeight))
    }
    let scale = min(
      boxWidth / Double(sourceWidth), boxHeight / Double(sourceHeight), 1.0)
    return CGSize(
      width: evenValue((Double(sourceWidth) * scale).rounded()),
      height: evenValue((Double(sourceHeight) * scale).rounded()))
  }

  private func evenValue(_ value: Double) -> Double {
    let clamped = max(2, Int(value))
    return Double(clamped % 2 == 0 ? clamped : clamped - 1)
  }
}
